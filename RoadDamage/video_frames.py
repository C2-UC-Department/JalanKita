"""Sample frames from a clip so Peninjauan can review a video instead of one photo.

The road-damage worker analyses **one image per request** and always will — batching is what moved
a real frame's detector `conf` by 7 points (ADR-021). So "review a video" is really "turn a clip
into frames, then run the existing per-image path N times". This module is only the first half.

**Why not just call `../../test-road-damage-detection/scripts/extract_frames.py`.** That script is
615 lines built for corpus construction: blur/near-duplicate rejection tuned over 29 clips, HEIC
decode, GPS interpolation, an idempotent provenance merge, and a hard dependency on the **ffprobe
binary** for every video. ffprobe is Homebrew-installed here and a shipped `.app` cannot assume it
exists. This is the trimmed interactive path: `cv2` only — already pinned in `requirements.txt` at
4.10.0.84 — no new dependency, no external binary.

⚠️ **The filename convention is load-bearing, not cosmetic.** `{stem}_f{index:06d}_t{ms:07d}.jpg`
matches `extract_frames.py` exactly, which is what lets `RoadDamageDataset.frameIndex(fromStem:)`
and `timecode(seconds:stem:)` parse `frameNumber` and `timecode` straight out of the name. Change
the format and those two fields silently fall back to `"—"`.

📍 **`wall_clock_iso` is written from the container's own `mvhd` atom**, parsed here in ~20 lines
rather than shelled out to ffprobe. It matters more than it looks: it is the join key an external
GPS log will be interpolated onto later, and it is the one temporal column that is real for all 958
existing frames. When the atom cannot be read the column is left **empty** rather than filled with
the file's mtime — a modification time is not a recording time, and a plausible wrong timestamp
would join a frame to the wrong place on a map.

🚫 Blur and near-duplicate rejection are **off by default** here, unlike the corpus extractor. For a
reviewer who asked for "every 3 seconds", getting an unpredictable count back because two frames
looked alike is worse than reviewing a dull frame. Both are available as flags.

🔥 **Run this in a CLEAN process. Never inside the analysis worker.** Measured 2026-08-13 on
`IMG_0040.MOV`, same clip, same cv2 4.10.0, same quality 95, same code:

===================================  ==============  ==========================================
where it ran                         JPEG size       vs a standalone run
===================================  ==============  ==========================================
standalone (this module's CLI)       991.882 B       reference — reproduces the corpus md5-for-md5
inside `worker_main.py --serve`      999.961 B       **78.848 channel values differ, max 255**
===================================  ==============  ==========================================

Downstream that moved the detector's own reading of the frame: `conf` 0,7424 → 0,7411,
`deduct_effective` 11,987 → 11,989. Same class of drift `requirements.txt` pins the OpenCV
*version* against, arriving instead through process state.

⚠️ **Four plausible causes were tested and ruled out**, so do not "fix" this by chasing them again:
`cv2.setNumThreads` (10, 1 and 0 all encode byte-identically), `import torch`, `import ultralytics`
(it does drop cv2 to 1 thread — which changes nothing), and video decode itself (bit-identical,
`sum` 895957687 either way). What remains is that the worker has initialised MPS and loaded two
models; on Apple Silicon the AVFoundation decode path is hardware-backed, and a live GPU context is
the one difference left standing.

:func:`_pin_cv2_threads` is kept anyway — it costs nothing and removes one variable from any future
investigation — but it is **not** the fix. The fix is process isolation, and it is why
`worker_main.py` deliberately has no `extract` request type.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import re
import struct
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import cv2
import numpy as np

#: Same columns, same order as `extract_frames.py`'s `CSV_COLUMNS`, so a directory produced here
#: and one produced there are interchangeable — including the four GPS columns, which stay empty
#: with `gps_source=none` until a track exists.
CSV_COLUMNS = [
    "frame_file", "source_video", "source_type", "frame_index", "pts_sec", "wall_clock_iso",
    "lat", "lon", "alt_m", "gps_source", "orientation", "width", "height",
    "blur_var", "phash_hex", "extractor_fps", "run_date",
]

DEFAULT_INTERVAL_SEC = 3.0
JPEG_QUALITY = 95           # matches extract_frames.py:57

#: QuickTime counts seconds from 1904-01-01 UTC; Unix from 1970-01-01.
_QT_EPOCH_OFFSET = 2_082_844_800


#: Single-threaded encode. See the module docstring: OpenCV's JPEG output depends on this, and
#: `import ultralytics` changes it behind your back. 1 rather than the default because it is the
#: one value that does not depend on the machine's core count.
CV2_THREADS = 1


def _pin_cv2_threads() -> None:
    """Make encoding independent of whatever else this process happens to have imported."""
    try:
        cv2.setNumThreads(CV2_THREADS)
    except Exception:  # noqa: BLE001 — a build without threading support is fine, just slower
        pass


def frame_filename(stem: str, idx: int, ms: int) -> str:
    """Sortable, space-free, provenance-in-the-name. Byte-compatible with `extract_frames.py`."""
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", stem)
    return f"{safe}_f{idx:06d}_t{ms:07d}.jpg"


def read_creation_time(path: Path) -> str | None:
    """Recording time from the MP4/MOV `mvhd` atom, as an ISO-8601 UTC string, or None.

    A deliberate ~20 lines instead of an `ffprobe` subprocess: this has to work inside a frozen
    `.app` on a machine with no Homebrew. Walks only top-level atoms to find `moov`, then scans it
    for `mvhd` — enough for every iPhone-recorded clip in this corpus.

    ⚠️ Returns **UTC**, whereas the existing `frames_provenance.csv` carries local time with a
    `+07:00` offset (Apple writes both; only the UTC one lives in `mvhd`). They denote the same
    instant, which is all an interpolated GPS join needs. Returns None rather than guessing when
    the atom is absent or the value is zero.
    """
    try:
        with path.open("rb") as fh:
            end = path.stat().st_size
            pos = 0
            while pos < end - 8:
                fh.seek(pos)
                header = fh.read(8)
                if len(header) < 8:
                    return None
                size, kind = struct.unpack(">I4s", header)
                if size < 8:
                    return None
                if kind == b"moov":
                    blob = fh.read(min(size - 8, 1 << 20))
                    at = blob.find(b"mvhd")
                    if at < 0:
                        return None
                    version = blob[at + 4]
                    if version == 1:
                        secs = struct.unpack(">Q", blob[at + 8:at + 16])[0]
                    else:
                        secs = struct.unpack(">I", blob[at + 8:at + 12])[0]
                    if secs <= _QT_EPOCH_OFFSET:
                        return None
                    dt = datetime(1904, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=secs)
                    return dt.isoformat().replace("+00:00", "Z")
                pos += size
    except (OSError, struct.error, IndexError):
        return None
    return None


def probe(path: Path) -> dict:
    """fps / frame count / duration / size, from cv2 alone. Raises if the clip will not open."""
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        cap.release()
        raise ValueError(f"tidak bisa membuka video: {path}")
    try:
        fps = float(cap.get(cv2.CAP_PROP_FPS)) or 0.0
        count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    finally:
        cap.release()
    if fps <= 0:
        raise ValueError(f"fps tidak terbaca dari {path.name}")
    return {"fps": fps, "frame_count": count, "width": width, "height": height,
            "duration_sec": (count / fps) if count else 0.0}


def blur_var(gray: np.ndarray) -> float:
    """Laplacian variance — low means soft. Same statistic the corpus extractor filters on."""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def dhash(gray: np.ndarray) -> int:
    """64-bit difference hash for near-duplicate detection (a stopped car repeats frames)."""
    small = cv2.resize(gray, (9, 8), interpolation=cv2.INTER_AREA)
    bits = small[:, 1:] > small[:, :-1]
    out = 0
    for bit in bits.flatten():
        out = (out << 1) | int(bit)
    return out


def extract(video: Path, out_dir: Path, *, interval_sec: float = DEFAULT_INTERVAL_SEC,
            max_frames: int = 0, blur_thresh: float = 0.0, hash_thresh: int = 0,
            gps_csv: Path | None = None, gps_max_gap: float = 5.0,
            created_utc_override: str | None = None,
            on_progress=None) -> dict:
    """Sample `video` every `interval_sec` seconds into `out_dir`. Returns a manifest dict.

    `max_frames` caps the count by widening the stride, never by truncating the tail — a truncated
    clip would silently review only its beginning, which is the failure mode that looks like a
    clean road.

    `blur_thresh` and `hash_thresh` default to 0 (**disabled**). Enabling them makes the returned
    count smaller than `duration / interval`, which is fine as long as the caller reports it — the
    manifest carries `rejected_blur` and `rejected_dup` for exactly that.

    `gps_csv`, when given, is a `time,lat,lon` track (same format `LocationTracker.swift` writes)
    joined onto each frame's `wall_clock_iso` by nearest-neighbor within `gps_max_gap` seconds —
    see `_nearest_gps`. A frame with no readable `wall_clock_iso`, or no fix within the gap, keeps
    today's empty `lat`/`lon`/`gps_source="none"` rather than a guessed value.

    `created_utc_override`, when given, replaces `read_creation_time(video)` outright rather than
    supplementing it. Exists for exactly one caller: `RoadDamageService` on a manual upload that
    went through "Putar kiri/kanan" (`SessionVideoAssetBuilder.rotateVideo`) before processing.
    That rotation re-muxes the file through `AVAssetExportSession`, which does NOT carry the
    original `mvhd` creation time forward — the output gets stamped with the moment of export
    instead (confirmed by export-then-reread: the timestamp becomes "now", not the source's). Read
    THIS file's atom at that point and every `wall_clock_iso` — and therefore every GPS-joined
    coordinate — silently lands on the wrong day. The override is captured Swift-side via
    AVFoundation at upload time, before any rotation can happen, and threaded down through
    `worker_main.py --created-utc-override` to land here instead.
    """
    _pin_cv2_threads()
    meta = probe(video)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = video.stem
    created = created_utc_override or read_creation_time(video)
    gps_track = _load_gps_track(gps_csv) if gps_csv else []

    step = max(1, int(round(meta["fps"] * interval_sec)))
    total = meta["frame_count"] or int(meta["fps"] * meta["duration_sec"])
    wanted = list(range(0, max(total, 1), step))
    if max_frames and len(wanted) > max_frames:
        stride = len(wanted) / max_frames
        wanted = sorted({wanted[int(i * stride)] for i in range(max_frames)})
    wanted_set = set(wanted)

    rows: list[dict] = []
    rejected_blur = rejected_dup = 0
    recent: list[int] = []

    cap = cv2.VideoCapture(str(video))
    try:
        # Auto-rotate to display-upright. Portrait iPhone clips carry a rotation matrix, and
        # without this the frames arrive sideways — the detector still fires, on a rotated road.
        try:
            cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
        except Exception:  # noqa: BLE001 — older OpenCV simply lacks the property
            pass

        last = max(wanted_set) if wanted_set else -1
        i = 0
        while i <= last:
            ok, frame = cap.read()
            if not ok:
                break
            if i in wanted_set:
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                keep = True
                bv = blur_var(gray) if blur_thresh else 0.0
                if blur_thresh and bv < blur_thresh:
                    keep, rejected_blur = False, rejected_blur + 1
                ph = dhash(gray)
                if keep and hash_thresh:
                    if any(bin(ph ^ p).count("1") <= hash_thresh for p in recent):
                        keep, rejected_dup = False, rejected_dup + 1
                    else:
                        recent = ([*recent, ph])[-8:]

                if keep:
                    pts = i / meta["fps"]
                    name = frame_filename(stem, i, int(round(pts * 1000)))
                    cv2.imwrite(str(out_dir / name), frame,
                                [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY])
                    h, w = frame.shape[:2]
                    wall_clock_iso = _shift(created, pts)
                    fix = _nearest_gps(gps_track, wall_clock_iso, gps_max_gap)
                    rows.append({
                        "frame_file": name, "source_video": video.name, "source_type": "video",
                        "frame_index": i, "pts_sec": round(pts, 3),
                        "wall_clock_iso": wall_clock_iso,
                        "lat": fix[0] if fix else "", "lon": fix[1] if fix else "",
                        "alt_m": "", "gps_source": "nearest" if fix else "none",
                        "orientation": "portrait" if h >= w else "landscape",
                        "width": w, "height": h,
                        "blur_var": round(bv, 1) if blur_thresh else "",
                        "phash_hex": f"{ph:016x}",
                        "extractor_fps": round(1.0 / interval_sec, 4) if interval_sec else "",
                        "run_date": datetime.now().date().isoformat(),
                    })
                    if on_progress:
                        on_progress(len(rows), len(wanted))
            i += 1
    finally:
        cap.release()

    provenance = out_dir / "frames_provenance.csv"
    with provenance.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    return {
        "video": str(video), "out_dir": str(out_dir), "provenance": str(provenance),
        "interval_sec": interval_sec, "fps": round(meta["fps"], 4),
        "duration_sec": round(meta["duration_sec"], 3),
        "frames": [str(out_dir / r["frame_file"]) for r in rows],
        "sampled": len(wanted), "kept": len(rows),
        "rejected_blur": rejected_blur, "rejected_dup": rejected_dup,
        "created_utc": created,
        "warnings": None if created else
        "Waktu rekam tidak terbaca dari berkas; kolom wall_clock_iso dikosongkan.",
    }


def _shift(created_iso: str | None, seconds: float) -> str:
    """Wall-clock for one frame = clip creation time + its presentation timestamp."""
    if not created_iso:
        return ""
    base = datetime.fromisoformat(created_iso.replace("Z", "+00:00"))
    return (base + timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


def _load_gps_track(path: Path) -> list[tuple[float, float, float]]:
    """Parses a `time,lat,lon` CSV (same ISO-8601-Z format `LocationTracker.swift` writes) into
    `(epoch_sec, lat, lon)` rows sorted by time. Malformed rows are skipped rather than raising —
    one bad GPS fix must not sink the whole extraction."""
    rows: list[tuple[float, float, float]] = []
    with path.open(newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                ts = datetime.fromisoformat(row["time"].replace("Z", "+00:00"))
                rows.append((ts.timestamp(), float(row["lat"]), float(row["lon"])))
            except (KeyError, ValueError):
                continue
    rows.sort(key=lambda r: r[0])
    return rows


def _nearest_gps(track: list[tuple[float, float, float]], wall_clock_iso: str,
                  max_gap: float) -> tuple[float, float] | None:
    """Nearest-neighbor GPS fix for one frame's timestamp, or None if the closest fix is farther
    than `max_gap` seconds away (or the track/timestamp is empty). Demo-grade on purpose — linear
    interpolation between the two bracketing fixes would be more accurate but isn't needed for a
    ~1 Hz demo track."""
    if not track or not wall_clock_iso:
        return None
    target = datetime.fromisoformat(wall_clock_iso.replace("Z", "+00:00")).timestamp()
    times = [r[0] for r in track]
    i = bisect.bisect_left(times, target)
    candidates = [c for c in (i - 1, i) if 0 <= c < len(track)]
    if not candidates:
        return None
    best = min(candidates, key=lambda c: abs(track[c][0] - target))
    if abs(track[best][0] - target) > max_gap:
        return None
    return track[best][1], track[best][2]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("--out", required=True, help="directory for the extracted JPEGs")
    ap.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SEC,
                    help=f"seconds between sampled frames (default {DEFAULT_INTERVAL_SEC})")
    ap.add_argument("--max-frames", type=int, default=0, help="cap by widening the stride")
    ap.add_argument("--blur-thresh", type=float, default=0.0, help="0 disables (default)")
    ap.add_argument("--hash-thresh", type=int, default=0, help="0 disables (default)")
    ap.add_argument("--gps-csv", help="time,lat,lon track to join onto each frame (optional)")
    ap.add_argument("--gps-max-gap", type=float, default=5.0,
                    help="max seconds between a frame and its nearest GPS fix (default 5.0)")
    ap.add_argument("--created-utc-override",
                    help="replace the file's own mvhd creation time (ISO-8601 UTC) — see extract()'s "
                         "doc comment on why a rotated file's own atom can no longer be trusted")
    args = ap.parse_args()

    manifest = extract(Path(args.video).expanduser(), Path(args.out).expanduser(),
                       interval_sec=args.interval, max_frames=args.max_frames,
                       blur_thresh=args.blur_thresh, hash_thresh=args.hash_thresh,
                       gps_csv=Path(args.gps_csv).expanduser() if args.gps_csv else None,
                       gps_max_gap=args.gps_max_gap,
                       created_utc_override=args.created_utc_override,
                       on_progress=lambda done, total:
                       print(f"  {done}/{total}", file=sys.stderr))
    manifest_out = dict(manifest)
    manifest_out["frames"] = f"[{len(manifest['frames'])} paths]"
    print(json.dumps(manifest_out, indent=1))


if __name__ == "__main__":
    main()
