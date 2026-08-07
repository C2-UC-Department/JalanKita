"""
Probe: can monocular metric depth separate "stopped" from "creeping in traffic"?

This is the one measurement v5-v9 could never make. From v9/FOCUS_stopped_or_moving.md, on
IMG_0063 with owner-provided ground truth from watching the footage:

    car#75   MOVING  (creeping in congestion, oncoming)  -> pipeline reads 31% stationary
    car#101  STOPPED (the only genuinely stopped vehicle) -> pipeline reads 33% stationary

Two vehicles with opposite ground truth, two percentage points apart. Every signal in v5-v9
measures velocity RELATIVE TO THE CAMERA, and in creeping congestion the camera creeps too, so a
vehicle moving with the traffic stream is indistinguishable from a parked one. Fanani, Ochs &
Mester (ECCV-W 2018) state the same result: an epipolar-conformant vehicle "appears exactly as a
static point, but in a different (pseudo)distance."

THE IDEA BEING TESTED
Depth from a single image is an APPEARANCE-based estimate -- it does not use motion at all, so it
is not fooled by an object that happens to move with the camera. Comparing how a car's depth
changes against how the STATIC WORLD's depth changes gives a scale-free ratio:

    ratio = (car's depth change per frame) / (median depth change of tracked static background)

      ratio ~= 1  -> the car recedes exactly like the static world does -> STOPPED / PARKED
      ratio ~= 0  -> its distance is not changing -> moving forward at ego speed (convoy)
      ratio  > 1  -> closing faster than the static world -> ONCOMING
      0 < r < 1   -> same direction, slower than ego

The denominator is what makes this work without knowing ego speed: the static background supplies
ego motion in the same units, for free. No IMU, no ARKit, no calibration -- still video-only.

SUCCESS CRITERION, fixed BEFORE running so it cannot be moved afterwards:
  car#101 (STOPPED) and car#75 (MOVING) must land on OPPOSITE sides of a single threshold, with a
  clear margin -- not the 2-point overlap the current pipeline produces.

Depth model: Depth Anything V2 Metric Outdoor (Small). Metric, not relative, on purpose: the
relative model is affine-invariant with per-frame unknown scale AND shift, which would make depth
values incomparable between frames -- exactly the quantity this probe needs.
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
import torch
from PIL import Image
from ultralytics import YOLO

from demo_scan_v6 import BACKGROUND_EXCLUDE_CLASSES

DEPTH_MODEL = "depth-anything/Depth-Anything-V2-Metric-Outdoor-Small-hf"
CAR_MODEL = os.path.join(V12_DIR, "yolov8n-seg.pt")

# Depth is run on a downscaled frame: the network's own internal resolution is fixed anyway, and
# full 1080x1920 per frame is wasted time for a probe.
DEPTH_LONG_SIDE = 640

# Frames where the ego vehicle is barely moving make the denominator ~0 and the ratio explode.
# Congestion footage has a lot of these, so they are dropped rather than allowed to dominate the
# median. In metres per frame.
MIN_EGO_RATE = 0.02

# Background feature tracking (same family of settings the v5 epipolar signal uses).
BG_MAX_CORNERS = 400
BG_QUALITY = 0.01
BG_MIN_DISTANCE = 8
LK_PARAMS = dict(winSize=(21, 21), maxLevel=3,
                 criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 0.01))

MIN_CAR_MASK_PX = 200      # below this the median depth inside the mask is too noisy to use
MIN_FRAMES_PER_TRACK = 15  # a track needs enough paired readings for its median ratio to mean much


def load_depth_pipeline(device):
    from transformers import pipeline
    return pipeline("depth-estimation", model=DEPTH_MODEL, device=device)


def depth_map(dpipe, frame_bgr):
    """Raw METRIC depth (metres) at the downscaled frame's resolution."""
    h, w = frame_bgr.shape[:2]
    scale = DEPTH_LONG_SIDE / max(h, w)
    small = cv2.resize(frame_bgr, (int(round(w * scale)), int(round(h * scale))),
                       interpolation=cv2.INTER_AREA)
    rgb = Image.fromarray(cv2.cvtColor(small, cv2.COLOR_BGR2RGB))
    out = dpipe(rgb)
    d = out["predicted_depth"]
    if hasattr(d, "detach"):
        d = d.detach().float().cpu().numpy()
    d = np.asarray(d, dtype=np.float32)
    if d.ndim == 3:
        d = d[0]
    # The pipeline may return depth at the model's own resolution; force it to the small frame.
    if d.shape[:2] != small.shape[:2]:
        d = cv2.resize(d, (small.shape[1], small.shape[0]), interpolation=cv2.INTER_LINEAR)
    return d, scale


def sample_depth(depth, pts_xy, scale):
    """Bilinear-ish sample (nearest is fine at this resolution) of depth at full-res points."""
    h, w = depth.shape[:2]
    xs = np.clip((pts_xy[:, 0] * scale).astype(np.int32), 0, w - 1)
    ys = np.clip((pts_xy[:, 1] * scale).astype(np.int32), 0, h - 1)
    return depth[ys, xs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=os.path.join(V12_DIR, "videos", "source", "IMG_0063.MOV"))
    ap.add_argument("--device", default="mps")
    ap.add_argument("--max-frames", type=int, default=0, help="0 = whole clip")
    ap.add_argument("--targets", default="75,101", help="track ids to report in detail")
    args = ap.parse_args()

    targets = {int(t) for t in args.targets.split(",") if t.strip()}

    print(f"loading models (depth={DEPTH_MODEL})...", file=sys.stderr)
    dpipe = load_depth_pipeline(args.device)
    car_model = YOLO(CAR_MODEL, task="segment")

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        sys.exit(f"could not open {args.input}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    limit = args.max_frames if args.max_frames > 0 else total

    prev_gray = None
    prev_depth = None
    prev_scale = None
    prev_masks = {}          # track_id -> boolean mask (full res)
    ratios = defaultdict(list)
    track_frames = defaultdict(list)
    ego_rates = []
    dropped_low_ego = 0

    frame_idx = 0
    while frame_idx < limit:
        ok, frame = cap.read()
        if not ok:
            break

        result = car_model.track(
            frame, classes=BACKGROUND_EXCLUDE_CLASSES, tracker="bytetrack.yaml",
            persist=True, verbose=False
        )[0]

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        depth, dscale = depth_map(dpipe, frame)

        # --- per-car masks this frame ---
        masks = {}
        if result.boxes is not None and result.boxes.id is not None and result.masks is not None:
            ids = result.boxes.id.int().cpu().numpy()
            mdata = result.masks.data.cpu().numpy()
            for i, tid in enumerate(ids):
                m = mdata[i]
                if m.shape[:2] != frame.shape[:2]:
                    m = cv2.resize(m, (frame.shape[1], frame.shape[0]),
                                   interpolation=cv2.INTER_NEAREST)
                mb = m > 0.5
                if mb.sum() >= MIN_CAR_MASK_PX:
                    masks[int(tid)] = mb
                    track_frames[int(tid)].append(frame_idx)

        if prev_gray is not None:
            # --- ego motion reference: median depth change of tracked STATIC background points ---
            any_car = np.zeros(frame.shape[:2], dtype=bool)
            for mb in prev_masks.values():
                any_car |= mb
            bg_mask = (~any_car).astype(np.uint8) * 255

            ego_rate = None
            p0 = cv2.goodFeaturesToTrack(prev_gray, maxCorners=BG_MAX_CORNERS,
                                         qualityLevel=BG_QUALITY, minDistance=BG_MIN_DISTANCE,
                                         mask=bg_mask)
            if p0 is not None and len(p0) >= 20:
                p1, st, _err = cv2.calcOpticalFlowPyrLK(prev_gray, gray, p0, None, **LK_PARAMS)
                st = st.reshape(-1).astype(bool)
                a = p0.reshape(-1, 2)[st]
                b = p1.reshape(-1, 2)[st]
                if len(a) >= 20:
                    za = sample_depth(prev_depth, a, prev_scale)
                    zb = sample_depth(depth, b, dscale)
                    valid = np.isfinite(za) & np.isfinite(zb) & (za > 0) & (zb > 0)
                    if valid.sum() >= 20:
                        ego_rate = float(np.median(zb[valid] - za[valid]))

            if ego_rate is not None and abs(ego_rate) >= MIN_EGO_RATE:
                ego_rates.append(ego_rate)
                # --- per-car depth change, using the tracker for object correspondence ---
                for tid, mb_now in masks.items():
                    mb_prev = prev_masks.get(tid)
                    if mb_prev is None:
                        continue
                    z_prev = prev_depth[cv2.resize(mb_prev.astype(np.uint8),
                                                   (prev_depth.shape[1], prev_depth.shape[0]),
                                                   interpolation=cv2.INTER_NEAREST) > 0]
                    z_now = depth[cv2.resize(mb_now.astype(np.uint8),
                                             (depth.shape[1], depth.shape[0]),
                                             interpolation=cv2.INTER_NEAREST) > 0]
                    if z_prev.size < 20 or z_now.size < 20:
                        continue
                    dz_car = float(np.median(z_now)) - float(np.median(z_prev))
                    ratios[tid].append(dz_car / ego_rate)
            elif ego_rate is not None:
                dropped_low_ego += 1

        prev_gray, prev_depth, prev_scale, prev_masks = gray, depth, dscale, masks
        frame_idx += 1
        if frame_idx % 50 == 0:
            print(f"  {frame_idx}/{limit}", file=sys.stderr)

    cap.release()

    print(f"\nego-motion reference: {len(ego_rates)} usable frame pairs, "
          f"{dropped_low_ego} dropped for |ego rate| < {MIN_EGO_RATE} m/frame")
    if ego_rates:
        er = np.array(ego_rates)
        print(f"  median ego depth rate {np.median(er):+.3f} m/frame "
              f"(~{abs(np.median(er))*fps*3.6:.1f} km/h if depth is well scaled)")

    rows = []
    for tid, r in ratios.items():
        if len(r) < MIN_FRAMES_PER_TRACK:
            continue
        arr = np.array(r)
        rows.append((tid, len(arr), float(np.median(arr)),
                     float(np.percentile(arr, 25)), float(np.percentile(arr, 75)),
                     track_frames[tid][0] / fps, track_frames[tid][-1] / fps))
    rows.sort(key=lambda x: -x[1])

    print(f"\n{'track':>7} {'n':>5} {'median':>8} {'p25':>8} {'p75':>8}   span(s)")
    print("-" * 60)
    for tid, n, med, p25, p75, t0, t1 in rows:
        star = "  <<< TARGET" if tid in targets else ""
        print(f"car#{tid:<4d} {n:5d} {med:8.2f} {p25:8.2f} {p75:8.2f}   {t0:5.1f}-{t1:5.1f}{star}")

    print("\ninterpretation:  ~1 = recedes like the static world (STOPPED/PARKED)")
    print("                 ~0 = distance not changing (moving at ego speed)")
    print("                 >1 = closing faster than static world (ONCOMING)")

    print("\n=== TARGETS (ground truth from v9/FOCUS_stopped_or_moving.md) ===")
    gt = {101: "STOPPED", 75: "MOVING (creeping, oncoming)"}
    for tid in sorted(targets):
        match = [r for r in rows if r[0] == tid]
        if not match:
            print(f"  car#{tid}: NOT MEASURED (too few paired frames or track id differs this run)")
            continue
        _, n, med, p25, p75, t0, t1 = match[0]
        print(f"  car#{tid}: ratio median {med:+.2f}  (p25 {p25:+.2f}, p75 {p75:+.2f}, n={n})"
              f"   ground truth: {gt.get(tid, '?')}")


if __name__ == "__main__":
    main()
