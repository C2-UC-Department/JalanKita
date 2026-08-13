#!/usr/bin/env python3
"""NDJSON worker for the road-damage (Peninjauan) vertical — Protocol A.

One JSON object per stdin line in, one per stdout line out. **stdout carries
responses and nothing else**; model-loading chatter, Ultralytics' banner, and
structured `{"type": ...}` progress events all go to stderr. That split is the
whole protocol: `RoadDamageWorkerProcess` decodes stdout strictly and would treat
a stray `print()` as a malformed response. Ultralytics prints on import and on
first predict, so the load is wrapped in `redirect_stdout(sys.stderr)`.

Deliberately the SAME protocol as `PythonWorker/`'s `serve_worker` (ADR-001), not
`CarDetection`'s one-shot file contract (ADR-009). Peninjauan is a photo -> findings
flow like Tinjauan Parkir: a warm process amortises the multi-second model load
across every frame the reviewer opens, and there is no long-running job that needs
a file handoff. See ADR-016 for why this couldn't simply join `PythonWorker`.

Request  (type "analyze", the default when "type" is omitted):
    {"id": str, "image_path": str, "conf"?: float, "imgsz"?: int}
🚫 Video is NOT a request type here. `video_frames.py` runs as its own one-shot process and hands
back a list of frames; the app then sends one `analyze` per frame. Extracting inside this process
measurably changes the pixels — see the comment in `serve_worker`.
Response:
    {"id": str, "ok": bool, "image_width"?: int, "image_height"?: int,
     "condition"?: int, "grade"?: str, "start_score"?: int,
     "boxes"?: [{"box_index": int, "cls": str, "cx": float, "cy": float,
                 "w": float, "h": float, "conf": float, "area_pct": float,
                 "in_wheelpath": bool, "deduct_raw": float,
                 "deduct_effective": float,
                 "extent_pct"?: float, "extent_source"?: str}],
     "warnings"?: str, "error"?: str}

Stderr events: {"type": "ready"} once loaded, then
    {"type": "progress", "id": str, "stage": str, "state": str}
    {"type": "error", "error": str}
    {"type": "warn", "stage": str, "error": str}

⚠️ Schema truth is this docstring paired with `RoadDamageModels.swift`. Per
CLAUDE.md's hard rule the two change together, in one commit — never one side.

**`area_pct` vs `extent_pct`, and why both ship.** `area_pct` is the box's own footprint,
`w * h` — what severity is computed from. `extent_pct` is how much of that rectangle a U-Net
actually calls damage (`unet_extent.py`), as a fraction of the whole frame so the two are directly
comparable. A box over-states a thin diagonal crack by construction, and `extent_pct` is the honest
figure; boxes drawn around hand-brushed ground truth reach only 24,48 % pixel precision, which caps
what `area_pct` can ever mean.

🚫 **`extent_pct` is display-only for now and deliberately does NOT feed severity.** ADR-016
requires Stage 0 (pre-computed CSVs) and Stage 1 (this worker) to grade a frame identically, and
Stage 0 has no extent column. Making it authoritative means changing `severity.py` upstream,
recalibrating `severity.yaml`'s size term, and regenerating both Stage 0 CSVs — together, in one
change. Until then `condition`, `deduct_raw` and `deduct_effective` here are bit-identical to a run
with no U-Net at all. Both fields are absent when the frame has no boxes or the extent model could
not be trusted for that image, so Swift decodes them as optional.

Defaults match how `outputs/quantify/per_box.csv` was produced (conf 0.20,
imgsz 1280), so a frame analysed live here lands on the same boxes, and therefore
the same condition score, as the same frame read from the Stage 0 dataset. Change
one and Stage 0 and Stage 1 start disagreeing about the same road.

Usage::

    python3 worker_main.py --serve
    echo '{"id":"t","image_path":"/path/frame.jpg"}' | python3 worker_main.py --serve
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import severity  # noqa: E402

# 🚫 `unet_extent` is imported lazily, inside the two functions that need it, never here.
# It imports torch at module scope (`@torch.no_grad()` needs it), and `--selftest` must stay a
# cheap gate: `build_worker.sh` runs it before a ~20-minute PyInstaller build precisely so a bad
# config fails in a second. Measured: a top-level import took --selftest from 0,3 s to 1,65 s.


def bundle_root() -> Path:
    """Where this worker's own data files (`models/`, `severity.yaml`) actually live.

    Unfrozen this is just ``ROOT`` — the directory holding this file. Under
    PyInstaller it is not: the onedir build unpacks bundled modules and ``datas``
    into ``sys._MEIPASS`` (``_internal/`` beside the executable), so
    ``Path(__file__).parent`` points into the archive layout rather than at a
    source tree that isn't shipped at all. Both of this worker's data lookups have
    to go through here or a frozen build fails at startup with a missing
    checkpoint — which, given ``resolve_checkpoint`` is deliberately fatal, is at
    least a loud failure rather than the silent random-weights one it exists to
    prevent (CLAUDE.md fact 9).

    This mirrors the reason ``PythonWorker/worker_main.py`` resolves ``--ckpt`` and
    ``--out`` explicitly instead of trusting ``config.ROOT``.
    """
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", ROOT))
    return ROOT


def severity_config_path() -> Path:
    """``severity.yaml`` beside the vendored ``severity.py``, frozen or not.

    Passed explicitly to ``SeverityConfig.from_yaml`` rather than relying on its
    ``DEFAULT_CONFIG`` default, which is ``Path(__file__).parent / "severity.yaml"``
    — correct in a checkout and unreliable once PyInstaller relocates the module.
    Fixing it there instead would mean editing the VENDORED copy of severity.py,
    which CLAUDE.md forbids: that file is kept arithmetically identical to
    ``../test-road-damage-detection/src/severity.py``, and a local edit guarantees
    the drift the re-vendoring rule exists to prevent.
    """
    return bundle_root() / "severity.yaml"


#: What this worker can do, as a string the app compares against its own expectation.
#:
#: 🔥 This exists because a stale frozen build silently shadowed three days of work. The launch
#: ladder puts the bundled PyInstaller binary FIRST — correct for a shipped app — so a `dist/` built
#: on 2026-08-10 kept serving after `unet_extent.py` and `video_frames.py` landed. Stage 1 quietly
#: stopped emitting `extent_pct`, and because that field is optional by design, Swift decoded it as
#: nil and the UI just... showed one number instead of two. Nothing failed. Video was the first
#: feature that could not degrade silently, and only because argparse rejects an unknown flag.
#:
#: ⚠️ Bump this whenever the worker gains or loses a capability the app depends on, and the app's
#: `RoadDamageService.expectedWorkerContract` with it. A mismatch makes the app skip the frozen
#: worker and say so, instead of running last week's inference and looking fine.
WORKER_CONTRACT = "2026-08-13.extent+video"

# Matches prelabel_report.json — the run that produced the Stage 0 CSVs.
DEFAULT_CONF = 0.20
DEFAULT_IMGSZ = 1280


def _emit(event: dict) -> None:
    """Structured event on stderr. stdout is reserved for responses."""
    print(json.dumps(event), file=sys.stderr, flush=True)


def pick_device() -> str:
    """CUDA -> MPS -> CPU, with an app-settable override.

    `JALANKITA_ROAD_DAMAGE_FORCE_CPU=1` mirrors `PYTHONWORKER_FORCE_CPU` in
    `PythonWorker/src/common.py`: the app sets it so a GPU backend crash in one
    vertical can't take the console down (ADR-012 documents the reproducible MPS
    SIGABRT that forced this for the disturbance worker). A CLI run without the
    variable still gets MPS, so app-vs-terminal timings are not comparable.
    """
    if os.environ.get("JALANKITA_ROAD_DAMAGE_FORCE_CPU") == "1":
        print("[device] cpu (forced by JALANKITA_ROAD_DAMAGE_FORCE_CPU)", file=sys.stderr)
        return "cpu"
    import torch

    if torch.cuda.is_available():
        return "0"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def resolve_checkpoint(explicit: str | None = None) -> Path:
    """Locate `server_trained.pt`, or raise. NEVER falls back to random weights.

    Ultralytics happily constructs a model from a config with untrained weights,
    which is how a missing checkpoint turns into confident nonsense instead of an
    error — the exact failure `PythonWorker` hit with `ofrsnet_best.pt` (CLAUDE.md
    fact 9). So a missing file is fatal here, loudly, at startup.
    """
    candidates = [
        Path(explicit) if explicit else None,
        Path(os.environ["JALANKITA_ROAD_DAMAGE_CKPT"])
        if os.environ.get("JALANKITA_ROAD_DAMAGE_CKPT") else None,
        # `bundle_root()`, not ROOT: under PyInstaller the bundled copy lives in
        # `_internal/models/`, not beside this source file.
        bundle_root() / "models" / "server_trained.pt",
        # Dev convenience: the sibling checkout this model is trained in. Never
        # present in a frozen build, and harmless there.
        ROOT.parent.parent / "test-road-damage-detection" / "models" / "server_trained.pt",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate
    searched = "\n  ".join(str(c) for c in candidates if c)
    raise FileNotFoundError(
        "Checkpoint deteksi kerusakan jalan tidak ditemukan. Lokasi yang dicari:\n  "
        + searched
        + "\nSetel JALANKITA_ROAD_DAMAGE_CKPT atau salin server_trained.pt ke models/."
    )


def resolve_unet_checkpoint(explicit: str | None = None) -> Path:
    """Locate `unet_resnet34.pt`, or raise. Same contract as :func:`resolve_checkpoint`.

    The extent model is held to the identical rule as the detector: a missing file is fatal at
    startup, never a silent fallback. `smp.Unet` constructs perfectly happily from random weights,
    so a quiet fallback here would report confident extent numbers for a network that has never
    seen a road — the `ofrsnet_best.pt` failure (CLAUDE.md fact 9) in a new costume.
    """
    candidates = [
        Path(explicit) if explicit else None,
        Path(os.environ["JALANKITA_ROAD_SEG_CKPT"])
        if os.environ.get("JALANKITA_ROAD_SEG_CKPT") else None,
        bundle_root() / "models" / "unet_resnet34.pt",
        # Dev convenience: the sibling checkout this model is trained in.
        ROOT.parent.parent / "road_seg" / "runs" / "unet_resnet34" / "best.pt",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate
    searched = "\n  ".join(str(c) for c in candidates if c)
    raise FileNotFoundError(
        "Checkpoint segmentasi (U-Net) tidak ditemukan. Lokasi yang dicari:\n  "
        + searched
        + "\nSetel JALANKITA_ROAD_SEG_CKPT atau salin unet_resnet34.pt ke models/."
    )


def build_remap(model_names: dict) -> dict[int, int]:
    """Map the model's own class ids onto the merged 3-class taxonomy.

    Raises rather than guessing: a silent mislabel here would put a pothole's
    46-point deduction behind a crack's 8, and the score would look plausible.
    """
    names = {int(k): str(v).lower() for k, v in model_names.items()}
    merged = {v: k for k, v in severity.CLASS_ID_TO_NAME.items()}
    legacy = {"d00": "crack", "d10": "crack", "d20": "alligator", "d40": "pothole"}

    remap: dict[int, int] = {}
    for model_id, name in names.items():
        target = name if name in merged else legacy.get(name)
        if target is None:
            raise ValueError(
                f"class {model_id!r}={name!r} maps to neither the merged taxonomy "
                f"{list(merged)} nor the legacy RDD set {list(legacy)}"
            )
        remap[model_id] = merged[target]
    return remap


def load_model(ckpt: Path):
    """Load YOLO with all of its stdout chatter pushed to stderr."""
    from ultralytics import YOLO

    with contextlib.redirect_stdout(sys.stderr):
        model = YOLO(str(ckpt))
    return model


def measure_extent(unet, device: str, image_path: Path,
                   width: int, height: int) -> "np.ndarray | None":
    """U-Net label map for one frame, or None if it cannot be trusted for this image.

    Runs **once per frame**, not once per box — the segmenter looks at the whole image and the
    boxes only slice the result. ⚠️ One image per call, never a batch: ADR-021 measured that
    batching moves a detector box's `conf` by 7 points, and there is no reason to assume a U-Net
    is better behaved about it.

    Returns None rather than a wrong answer when the decoded frame does not match the dimensions
    the rest of the payload is built from. That happens when EXIF orientation is applied by one
    decoder and not another; the boxes are in normalised coordinates, so a transposed frame would
    silently measure the wrong rectangle and still produce a plausible percentage.
    """
    import cv2

    import unet_extent

    bgr = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
    if bgr is None:
        _emit({"type": "warn", "stage": "extent", "error": f"tidak bisa dibaca: {image_path}"})
        return None
    if bgr.shape[:2] != (height, width):
        _emit({"type": "warn", "stage": "extent",
               "error": f"dimensi tidak cocok {bgr.shape[:2]} != {(height, width)}"})
        return None
    return unet_extent.predict_label(unet, cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB), device)


def analyze(model, remap: dict[int, int], cfg: severity.SeverityConfig,
            image_path: Path, device: str, conf: float, imgsz: int,
            unet=None) -> dict:
    """Run the detector on one frame and grade it. Returns the response payload."""
    from PIL import Image

    with Image.open(image_path) as im:
        width, height = im.size

    with contextlib.redirect_stdout(sys.stderr):
        results = model.predict([str(image_path)], conf=conf, imgsz=imgsz,
                                device=device, verbose=False)

    dets: list[severity.Detection] = []
    result = results[0]
    if result.boxes is not None:
        for cls, xywhn, box_conf in zip(result.boxes.cls.tolist(),
                                        result.boxes.xywhn.tolist(),
                                        result.boxes.conf.tolist()):
            merged_id = remap.get(int(cls))
            if merged_id is None:
                continue
            cx, cy, w, h = xywhn
            dets.append(severity.Detection(severity.CLASS_ID_TO_NAME[merged_id],
                                           cx, cy, w, h, box_conf))

    graded = severity.grade_segment(dets, cfg)
    effective = severity.effective_deductions(dets, cfg)

    # 🔥 The extent model runs only when there is a box to measure, and its output feeds ONLY the
    # two `extent_*` fields below. `severity.Detection` above is built from the detector alone and
    # `d.area_frac` is still `w * h`, so `condition`, `deduct_raw` and `deduct_effective` are
    # bit-identical to a run without a U-Net. That is deliberate and it is Fase 1's whole contract:
    # ADR-016 requires Stage 0 (pre-computed CSVs) and Stage 1 (this worker) to grade a frame
    # identically, and Stage 0 has no extent column yet. Making extent authoritative is a later,
    # separate change that moves both stages together.
    label = None
    if dets and unet is not None:
        import unet_extent

        _emit({"type": "progress", "stage": "extent", "state": "start"})
        label = measure_extent(unet, device, image_path, width, height)
        _emit({"type": "progress", "stage": "extent", "state": "done"})

    boxes = []
    for i, (d, eff) in enumerate(zip(dets, effective)):
        box = {
            "box_index": i,
            "cls": d.cls,
            "cx": round(d.cx, 6),
            "cy": round(d.cy, 6),
            "w": round(d.w, 6),
            "h": round(d.h, 6),
            "conf": round(d.conf, 4),
            "area_pct": round(100.0 * d.area_frac, 4),
            "in_wheelpath": bool(d.in_wheelpath(cfg)),
            "deduct_raw": round(severity.score_detection(d, cfg), 3),
            "deduct_effective": round(eff, 3),
        }
        if label is not None:
            box["extent_pct"] = round(
                100.0 * unet_extent.extent_frac(label, d.cx, d.cy, d.w, d.h), 4)
            box["extent_source"] = "unet"
        boxes.append(box)

    # Ship the caveat with the number, per this repo's wire convention. The
    # detector's 0.53 mAP is a Japan+India figure and has never been measured
    # against Indonesian box labels; it under-fires here rather than over-fires.
    warnings = ("Model RDD2022 belum divalidasi pada data Indonesia — jumlah temuan "
                "adalah batas bawah, bukan kebenaran.")

    return {
        "image_width": width,
        "image_height": height,
        "condition": graded.condition,
        "grade": graded.grade,
        "start_score": 100,
        "boxes": boxes,
        "warnings": warnings,
    }


def serve_worker(ckpt: str | None, conf: float, imgsz: int,
                 unet_ckpt: str | None = None) -> None:
    """Read one JSON request per stdin line; write one JSON response per stdout line."""
    checkpoint = resolve_checkpoint(ckpt)
    unet_checkpoint = resolve_unet_checkpoint(unet_ckpt)
    device = pick_device()
    print(f"[device] {device}", file=sys.stderr)
    print(f"[ok] checkpoint {checkpoint}", file=sys.stderr)
    print(f"[ok] unet       {unet_checkpoint}", file=sys.stderr)

    cfg = severity.SeverityConfig.from_yaml(severity_config_path())
    model = load_model(checkpoint)
    remap = build_remap(model.names)
    print(f"[ok] remap {remap} -> {severity.CLASS_ID_TO_NAME}", file=sys.stderr)

    # Loaded once and held for the process lifetime, like the detector. A per-request load would
    # add ~0,3 s of pure overhead to a ~1,7 s request and buy nothing.
    import unet_extent

    unet = unet_extent.load_model(unet_checkpoint, device)
    print(f"[ok] extent model ready on {device}", file=sys.stderr)

    _emit({"type": "ready"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            _emit({"type": "error", "error": f"invalid JSON request: {e}"})
            continue

        req_id = req.get("id", "")
        req_type = req.get("type", "analyze")

        # 🚫 There is deliberately no "extract" request type. Frame extraction runs as its own
        # one-shot process (`video_frames.py`, launched by the app), NOT here, and the reason is
        # measured rather than stylistic: extracting `IMG_0040.MOV` inside this worker produced
        # JPEGs differing from a standalone run on **1,267 % of channel values** (991.882 vs
        # 999.961 bytes), which moved the detector's own `conf` from 0,7424 to 0,7411. Ruled out
        # by experiment: cv2 thread count, importing torch, importing ultralytics, and video
        # decode itself are all byte-identical either way — what is left is this process having
        # initialised MPS and loaded two models. A clean process is the only way to make
        # extraction reproducible, and it also stops a long clip blocking the warm analyse loop.
        if req_type != "analyze":
            print(json.dumps({"id": req_id, "ok": False,
                              "error": f"unknown request type {req_type!r}"}), flush=True)
            continue

        try:
            image_path = Path(req["image_path"])
            if not image_path.is_file():
                raise FileNotFoundError(f"gambar tidak ditemukan: {image_path}")

            _emit({"type": "progress", "id": req_id, "stage": "detect", "state": "active"})
            payload = analyze(model, remap, cfg, image_path, device,
                              float(req.get("conf", conf)), int(req.get("imgsz", imgsz)),
                              unet=unet)
            _emit({"type": "progress", "id": req_id, "stage": "detect", "state": "done"})
            _emit({"type": "progress", "id": req_id, "stage": "severity", "state": "done"})

            response = {"id": req_id, "ok": True, **payload}
        except Exception as e:  # noqa: BLE001 — one bad frame must not kill the worker
            _emit({"type": "error", "error": str(e)})
            response = {"id": req_id, "ok": False, "error": str(e)}

        print(json.dumps(response), flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serve", action="store_true", help="run the NDJSON worker loop")
    ap.add_argument("--ckpt", help="detector checkpoint (else env, then models/)")
    ap.add_argument("--unet-ckpt", help="extent checkpoint (else env, then models/)")
    ap.add_argument("--conf", type=float, default=DEFAULT_CONF, help="confidence threshold")
    ap.add_argument("--imgsz", type=int, default=DEFAULT_IMGSZ, help="inference size")
    ap.add_argument("--selftest", action="store_true",
                    help="checkpoint + config + taxonomy check, no model load")
    ap.add_argument("--extract-video", metavar="CLIP",
                    help="sample a clip into frames and exit; loads no model")
    ap.add_argument("--out", help="output directory for --extract-video")
    ap.add_argument("--interval", type=float, default=3.0,
                    help="seconds between sampled frames (--extract-video)")
    ap.add_argument("--max-frames", type=int, default=0,
                    help="cap frame count by widening the stride (--extract-video)")
    # Both filters exist in video_frames and both default to off. Exposed here
    # because raising --interval is the blunt way to cut cost: it drops frames
    # everywhere, including the stretches where the vehicle is moving and every
    # frame is new road. --hash-thresh instead drops only the frames that are
    # near-identical to one already kept, which is exactly the waste a survey
    # vehicle generates while stopped at a light -- full price for the same
    # asphalt, several times over.
    ap.add_argument("--hash-thresh", type=int, default=0,
                    help="dHash Hamming distance below which a frame counts as a "
                         "near-duplicate of a recently kept one and is skipped; "
                         "0 disables (--extract-video)")
    ap.add_argument("--blur-thresh", type=float, default=0.0,
                    help="Laplacian variance below which a frame is rejected as "
                         "too blurry; 0 disables (--extract-video)")
    args = ap.parse_args()

    if args.extract_video:
        # 🔥 A SEPARATE INVOCATION, not a request to a running worker, and the difference is
        # measurable rather than architectural taste: extracting inside a process that has
        # initialised MPS and loaded two models produced JPEGs differing on 1,267 % of channel
        # values, which moved the detector's own `conf` by 0,0013. This path reaches
        # `video_frames.extract` having imported neither torch nor ultralytics, so a frozen build
        # and a dev checkout both get the same pixels. See `video_frames.py`'s docstring for the
        # four causes that were tested and ruled out first.
        import video_frames

        if not args.out:
            ap.error("--extract-video requires --out")
        manifest = video_frames.extract(
            Path(args.extract_video), Path(args.out),
            interval_sec=args.interval, max_frames=args.max_frames,
            blur_thresh=args.blur_thresh, hash_thresh=args.hash_thresh,
            on_progress=lambda done, total: _emit(
                {"type": "progress", "stage": "extract", "state": "active",
                 "done": done, "total": total}),
        )
        print(json.dumps(manifest), flush=True)
        return

    if args.selftest:
        ckpt = resolve_checkpoint(args.ckpt)
        # 🚫 Presence and size only — never a load. `build_worker.sh` runs --selftest as a cheap
        # gate before a ~20-minute PyInstaller run, and importing torch here would cost most of
        # what the gate exists to save.
        unet_ckpt = resolve_unet_checkpoint(args.unet_ckpt)
        cfg = severity.SeverityConfig.from_yaml(severity_config_path())
        print(f"[ok] contract    {WORKER_CONTRACT}")
        print(f"[ok] checkpoint  {ckpt} ({ckpt.stat().st_size / 1e6:.1f} MB)")
        print(f"[ok] unet        {unet_ckpt} ({unet_ckpt.stat().st_size / 1e6:.1f} MB)")
        print(f"[ok] taxonomy    {severity.CLASS_ID_TO_NAME}")
        print(f"[ok] bands       IGNORE>={cfg.ignore_min:g} MONITOR>={cfg.monitor_min:g}")
        print(f"[ok] wheelpath   x{cfg.wheelpath_mult:g}  decay {cfg.density_decay:g}")
        # The anchor cases from the upstream repo's own demo, so a bad re-vendor
        # of severity.yaml is caught here rather than on screen.
        big = [severity.Detection("pothole", 0.5, 0.75, 0.34, 0.33)]
        hair = [severity.Detection("crack", 0.12, 0.30, 0.03, 0.01)]
        assert severity.grade_segment(big, cfg).grade == "URGENT", "large near pothole must be URGENT"
        assert severity.grade_segment(hair, cfg).grade == "IGNORE", "hairline crack must be IGNORE"
        print("[ok] anchors     large near pothole -> URGENT, hairline crack -> IGNORE")
        return

    if not args.serve:
        ap.error("nothing to do — pass --serve (or --selftest)")

    serve_worker(args.ckpt, args.conf, args.imgsz, args.unet_ckpt)


if __name__ == "__main__":
    main()
