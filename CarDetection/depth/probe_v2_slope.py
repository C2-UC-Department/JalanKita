"""
Probe 1b: same idea, corrected aggregation.

Probe 1 computed a ratio for every frame pair and took the median of those ratios. That was the
mistake. A car's depth changes by only ~0.17 m between consecutive frames, which is small against
per-frame depth noise, so each individual ratio is wild -- and the median of many wild ratios is
not the ratio of the underlying trend. car#101 came out at 0.30 when its own depth trace was in
fact falling smoothly and monotonically from 77.9 m to 29.1 m.

The fix: estimate each track's depth SLOPE over its whole life (Theil-Sen, robust to outliers),
and divide by the ego reference rate measured over that same frame window. Signal is extracted
from the trend, where it lives, instead of from frame-to-frame differences, where the noise lives.

Ego reference comes from LK-tracked background points (the same physical point sampled at t and
t+1), never from "median depth of whatever features this frame happened to produce" -- the
diagnostic showed that quantity swings between 22 m and 54 m and is not a physical measurement.

Success criterion is unchanged from probe 1, and was fixed before any of this ran:
  car#101 (STOPPED) and car#75 (MOVING) must land on opposite sides of a threshold with margin.
Expected if the method works: car#101 ~= 1.0, car#75 > 1.0.
"""

import argparse
import os
import sys
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
V12_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))
sys.path.insert(0, os.path.join(V12_DIR, "lib"))

import cv2
import numpy as np
from ultralytics import YOLO
from scipy.stats import theilslopes

from demo_scan_v6 import BACKGROUND_EXCLUDE_CLASSES
from probe_depth_rate import (
    CAR_MODEL, DEPTH_MODEL, LK_PARAMS, BG_MAX_CORNERS, BG_QUALITY, BG_MIN_DISTANCE,
    MIN_CAR_MASK_PX, load_depth_pipeline, depth_map, sample_depth,
)

MIN_FRAMES_PER_TRACK = 25   # a slope needs a decent baseline to mean anything
TRACE_PATH = os.path.join(SCRIPT_DIR, "trace_IMG_0063.npz")


def collect(video, device, limit=0):
    dpipe = load_depth_pipeline(device)
    car_model = YOLO(CAR_MODEL, task="segment")
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"could not open {video}")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    limit = limit or total

    track_depth = defaultdict(list)   # tid -> (frame_idx, median depth)
    ego_dz = {}                       # frame_idx -> ego depth change from frame-1 to frame
    prev_gray = prev_depth = prev_scale = None
    prev_any_car = None
    fidx = 0

    while fidx < limit:
        ok, frame = cap.read()
        if not ok:
            break
        res = car_model.track(frame, classes=BACKGROUND_EXCLUDE_CLASSES,
                              tracker="bytetrack.yaml", persist=True, verbose=False)[0]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        depth, dscale = depth_map(dpipe, frame)

        any_car = np.zeros(frame.shape[:2], dtype=bool)
        if res.boxes is not None and res.boxes.id is not None and res.masks is not None:
            ids = res.boxes.id.int().cpu().numpy()
            md = res.masks.data.cpu().numpy()
            for i, tid in enumerate(ids):
                m = md[i]
                if m.shape[:2] != frame.shape[:2]:
                    m = cv2.resize(m, (frame.shape[1], frame.shape[0]),
                                   interpolation=cv2.INTER_NEAREST)
                mb = m > 0.5
                any_car |= mb
                if mb.sum() >= MIN_CAR_MASK_PX:
                    ds = cv2.resize(mb.astype(np.uint8), (depth.shape[1], depth.shape[0]),
                                    interpolation=cv2.INTER_NEAREST) > 0
                    if ds.sum() >= 20:
                        track_depth[int(tid)].append((fidx, float(np.median(depth[ds]))))

        # Ego reference: depth change of the SAME tracked background points across the pair.
        if prev_gray is not None:
            bgm = (~prev_any_car).astype(np.uint8) * 255
            p0 = cv2.goodFeaturesToTrack(prev_gray, maxCorners=BG_MAX_CORNERS,
                                         qualityLevel=BG_QUALITY, minDistance=BG_MIN_DISTANCE,
                                         mask=bgm)
            if p0 is not None and len(p0) >= 20:
                p1, st, _ = cv2.calcOpticalFlowPyrLK(prev_gray, gray, p0, None, **LK_PARAMS)
                st = st.reshape(-1).astype(bool)
                a, b = p0.reshape(-1, 2)[st], p1.reshape(-1, 2)[st]
                if len(a) >= 20:
                    za = sample_depth(prev_depth, a, prev_scale)
                    zb = sample_depth(depth, b, dscale)
                    v = np.isfinite(za) & np.isfinite(zb) & (za > 0) & (zb > 0)
                    if v.sum() >= 20:
                        ego_dz[fidx] = float(np.median(zb[v] - za[v]))

        prev_gray, prev_depth, prev_scale, prev_any_car = gray, depth, dscale, any_car
        fidx += 1
        if fidx % 50 == 0:
            print(f"  {fidx}/{limit}", file=sys.stderr)
    cap.release()
    return track_depth, ego_dz, fidx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=os.path.join(V12_DIR, "videos", "source", "IMG_0063.MOV"))
    ap.add_argument("--device", default="mps")
    ap.add_argument("--max-frames", type=int, default=0)
    ap.add_argument("--reuse-trace", action="store_true",
                    help="skip inference and re-aggregate the cached trace")
    args = ap.parse_args()

    if args.reuse_trace and os.path.exists(TRACE_PATH):
        z = np.load(TRACE_PATH, allow_pickle=True)
        track_depth = z["track_depth"].item()
        ego_dz = z["ego_dz"].item()
        print(f"reusing cached trace ({len(track_depth)} tracks)", file=sys.stderr)
    else:
        track_depth, ego_dz, _ = collect(args.input, args.device, args.max_frames)
        np.savez(TRACE_PATH, track_depth=track_depth, ego_dz=ego_dz)
        print(f"trace saved -> {TRACE_PATH}", file=sys.stderr)

    rows = []
    for tid, pts in track_depth.items():
        if len(pts) < MIN_FRAMES_PER_TRACK:
            continue
        f = np.array([p[0] for p in pts], dtype=float)
        z = np.array([p[1] for p in pts], dtype=float)
        # Theil-Sen: median of pairwise slopes, robust to the occasional bad depth frame.
        car_slope, _, _, _ = theilslopes(z, f)

        # Ego rate over the SAME window, so a track that only exists while the ego is stopped
        # isn't divided by a rate measured while it was moving.
        window = [ego_dz[i] for i in range(int(f.min()), int(f.max()) + 1) if i in ego_dz]
        if len(window) < 10:
            continue
        ego_rate = float(np.median(window))
        if abs(ego_rate) < 0.02:
            continue
        rows.append((tid, len(pts), car_slope, ego_rate, car_slope / ego_rate,
                     z[0], z[-1], f.min(), f.max()))

    rows.sort(key=lambda r: -r[1])
    print(f"\n{'track':>8} {'n':>5} {'car m/f':>9} {'ego m/f':>9} {'RATIO':>8}  {'Z start':>8} {'Z end':>8}")
    print("-" * 72)
    for tid, n, cs, er, ratio, z0, z1, _, _ in rows:
        tag = "  <<<" if tid in (75, 101) else ""
        print(f"car#{tid:<5d}{n:5d} {cs:9.3f} {er:9.3f} {ratio:8.2f}  {z0:8.1f} {z1:8.1f}{tag}")

    print("\n  ratio ~1 = recedes like the static world (STOPPED/PARKED)")
    print("  ratio ~0 = distance not changing (moving at ego speed)")
    print("  ratio >1 = closing faster than static world (ONCOMING)")

    gt = {101: "STOPPED", 75: "MOVING (creeping, oncoming)"}
    print("\n=== TARGETS ===")
    got = {}
    for tid in (101, 75):
        m = [r for r in rows if r[0] == tid]
        if not m:
            print(f"  car#{tid}: NOT MEASURED")
            continue
        got[tid] = m[0][4]
        print(f"  car#{tid}: ratio {m[0][4]:+.2f}   ground truth: {gt[tid]}")
    if 101 in got and 75 in got:
        sep = got[75] / got[101] if got[101] else float("nan")
        print(f"\n  separation factor car#75 / car#101 = {sep:.2f}x")
        print(f"  (baseline: the current v11 pipeline reads 31% vs 33% stationary -- no separation)")


if __name__ == "__main__":
    main()
