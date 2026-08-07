"""
Renders the depth-rate signal as a watchable video. This is the artifact the probe never produced:
the probe printed a table of numbers, and a table is not something you can check against your own
eyes. Here every tracked car carries its measured depth-rate ratio on screen, next to a colour-coded
depth map, so a claim like "car#101 reads 0.93 because it is standing still" can be falsified by
watching the clip.

WHAT THE RATIO IS

    ratio = (car's depth slope over its whole track, m/frame)
            / (median depth change of LK-tracked static background over the same frames)

    ratio ~= 1  -> recedes exactly like the static world  -> STOPPED / PARKED
    ratio ~= 0  -> distance not changing                  -> moving forward at ego speed (convoy)
    ratio  > 1  -> closing faster than the static world   -> ONCOMING

The denominator is the whole trick: the static background supplies ego motion in the same units, so
no IMU, no ARKit, no calibration is needed. Still 100% video-only.

WHAT IS ON SCREEN IS NOT CAUSAL

The ratio drawn on a car is its FINAL whole-track value, computed from every frame the track lives
for, then painted back onto all of those frames. It is not what a real-time system would have known
at that instant. That is deliberate -- the point of this render is to let you audit the measurement
against the footage, not to simulate deployment. A causal version would need a rolling window and
would read differently early in each track.

STATUS: EXPERIMENTAL. This signal is NOT wired into the v12 DISTURBANCE verdict, and the banner
burned into the video says so. See DEPTH_SIGNAL.md for exactly what has and has not been shown.

Usage:
    python render_depth_video.py                              # IMG_0063, whole clip
    python render_depth_video.py --input ../videos/source/IMG_0065.MOV --output out.mp4
    python render_depth_video.py --max-frames 200             # quick look
"""

import argparse
import os
import sys
import tempfile
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
V12_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, os.path.join(V12_DIR, "lib"))

import cv2
import numpy as np
import torch
from scipy.stats import theilslopes

from ultralytics import YOLO
from demo_scan_v6 import BACKGROUND_EXCLUDE_CLASSES
from probe_depth_rate import (
    CAR_MODEL, DEPTH_MODEL, DEPTH_LONG_SIDE, LK_PARAMS, BG_MAX_CORNERS, BG_QUALITY, BG_MIN_DISTANCE,
    MIN_CAR_MASK_PX, load_depth_pipeline, depth_map, sample_depth,
)
from probe_v2_slope import MIN_FRAMES_PER_TRACK

# --- lighter depth backend: MiDaS small, EXPERIMENT (see --depth-backend) -------------------
# Benchmarked at 49ms/frame vs Depth-Anything-V2-Metric-Outdoor-Small's 123ms/frame on this
# project's own footage -- a real 2.5x, not a marginal one (swapping to the plain relative
# Depth-Anything-V2-Small-hf, same ViT-S backbone, measured NO speed difference: 121.6 vs
# 123.3ms -- the backbone is what costs time, and MiDaS small uses a genuinely smaller one,
# 21.3M params, EfficientNet-Lite based).
#
# MiDaS's raw output is INVERSE relative depth (disparity-like: bigger number = CLOSER),
# confirmed empirically on this project's own footage (near-field median 511.9 vs far-field
# median 0.0 on IMG_0063 frame 0) -- NOT simply sign-flipped depth. disparity ~= 1/depth is a
# NONLINEAR relation, so the ratio signal's "wrong absolute scale cancels in the division"
# property (see DEPTH_SIGNAL.md) only holds if the values fed to the Theil-Sen slope /
# ego-rate maths are actually depth-shaped first. midas_depth_map() below inverts
# (1 / (disparity + eps)) before returning, specifically so every downstream function
# (aggregate(), is_ego_bodywork(), the ratio itself) can stay completely unaware which
# backend supplied its numbers.
MIDAS_INVERT_EPS = 1e-3


def load_midas_small(device):
    import builtins
    builtins.input = lambda *a, **k: "y"  # auto-trust MiDaS's own nested torch.hub.load calls
    midas = torch.hub.load("intel-isl/MiDaS", "MiDaS_small", trust_repo=True).eval()
    if device not in ("cpu",):
        midas = midas.to(device)
    transform = torch.hub.load("intel-isl/MiDaS", "transforms", trust_repo=True).small_transform
    return {"model": midas, "transform": transform, "device": device}


def midas_depth_map(dpipe, frame_bgr):
    """Same contract as probe_depth_rate.depth_map(): returns (depth_2d_array, scale) where
    scale maps full-res pixel coords -> this array's coords. 'depth' here is 1/disparity, an
    arbitrary-scale DEPTH-SHAPED (not disparity-shaped) quantity -- see module comment above."""
    h, w = frame_bgr.shape[:2]
    scale = DEPTH_LONG_SIDE / max(h, w)
    small = cv2.resize(frame_bgr, (int(round(w * scale)), int(round(h * scale))),
                       interpolation=cv2.INTER_AREA)
    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
    inp = dpipe["transform"](rgb)
    if dpipe["device"] not in ("cpu",):
        inp = inp.to(dpipe["device"])
    with torch.no_grad():
        disparity = dpipe["model"](inp)[0].detach().float().cpu().numpy()
    depth_like = 1.0 / (disparity + MIDAS_INVERT_EPS)
    if depth_like.shape[:2] != small.shape[:2]:
        depth_like = cv2.resize(depth_like, (small.shape[1], small.shape[0]),
                                interpolation=cv2.INTER_LINEAR)
    return depth_like.astype(np.float32), scale

# --- what gets MEASURED vs what gets MASKED ------------------------------------------------
# These are two different questions and the probe conflated them, which is why people and bicycles
# were showing up with depth ratios on them.
#
#   BACKGROUND_EXCLUDE_CLASSES = [person, bicycle, car, motorcycle, bus, truck]
#     v6 defines this as "everything that MOVES, mask it out of the static-background fit". It is
#     still used for exactly that below -- the ego-rate denominator must not be contaminated by a
#     pedestrian's depth. Detection still runs over all of these classes for that reason.
#
#   TARGET_VEHICLE_CLASSES
#     what actually gets a depth ratio drawn on it. A parked-car detector should not be reporting
#     motion verdicts for pedestrians.
#
# Motorcycles (COCO 3) are excluded from measurement even though they park illegally constantly in
# Indonesia: they are small, frequently occluded, and their segmentation masks are too thin for a
# stable median depth (MIN_CAR_MASK_PX rejects most of them anyway). Adding them is a deliberate
# decision with its own validation, not a one-line change.
TARGET_VEHICLE_CLASSES = {2, 5, 7}   # car, bus, truck

# --- classification bands -------------------------------------------------------------------
# These are READING AIDS for the video, not validated thresholds. The probe measured exactly two
# vehicles against ground truth (0.93 stopped, 2.06 oncoming); the band edges below are drawn
# around those two points and around the physical prediction, and nothing more. Do not quote them
# as a tuned classifier.
BAND_AWAY_MAX = -0.15        # below this: depth INCREASING -> pulling away faster than ego
BAND_CONVOY_MAX = 0.35       # below this: distance barely changing -> moving with the ego
BAND_STOPPED_LO = 0.65       # inside [LO, HI]: recedes like the static world -> stopped/parked
BAND_STOPPED_HI = 1.40
# above BAND_STOPPED_HI: closing faster than the static world -> oncoming

# The ratio is a division, and congestion footage is full of near-zero denominators. Anything
# measured while the ego was crawling is marked UNSTABLE rather than classified -- car#510 read
# 15.47 against an ego rate of -0.079 m/frame, which is arithmetic, not a physical finding.
UNSTABLE_EGO_RATE = 0.05     # m/frame; probe used 0.02, which the probe itself found too loose

# --- depth-matched ego reference (fixes the IMG_0065 systematic bias) ------------------------
# THE BUG: the ego rate used to be one global number per frame -- the median depth change of EVERY
# LK-tracked background point, regardless of how far away it was. A target vehicle 60 m up the road
# was being compared against a denominator dominated by near-field kerb and road points a few
# metres away. Depth perspective compresses apparent motion at range, so a far background point's
# depth barely changes frame to frame even while the car is genuinely receding -- understating the
# denominator and inflating every ratio computed against it. This is exactly the "depth-dependent
# bias" hypothesis diag_depth_trace.py was written to test; the Theil-Sen slope fix disposed of a
# DIFFERENT bug (frame-to-frame noise) and was wrongly assumed to have disposed of this one too.
#
# THE FIX: for each frame a track lives in, only pool background points whose OWN depth is close to
# the car's depth AT THAT FRAME, then take the ego rate from that depth-matched pool instead of the
# whole frame. The comparison becomes like-for-like: "does this car recede like the static world
# AT ITS OWN DISTANCE", not "...like the static world on average, wherever most of it happens to
# sit". See depth_matched_ego_rate().
DEPTH_MATCH_BAND_FRAC = 0.35     # start: background points within +/-35% of the car's depth
DEPTH_MATCH_WIDEN_STEP = 0.25    # widen by this much if too few points fall in the band
DEPTH_MATCH_MAX_BAND_FRAC = 1.50 # give up widening here and fall back to the old (unmatched) pool
DEPTH_MATCH_MIN_POINTS = 15      # minimum pooled background samples before trusting the median

# --- ego-vehicle bodywork rejection (see is_ego_bodywork) ------------------------------------
# Thresholds read off the measured artifacts rather than tuned. On IMG_0057, 10 of 25 tracks sat at
# a constant 3.1-4.6 m; the nearest genuine vehicle measured on any clip was 21.8 m, so the depth
# cut has a wide empty gap to sit in.
#
# ⚠️ THIS FILTER IS STILL PARTIAL. It catches everything that is bottom-anchored, but not IMG_0063's
# car#3, which holds a constant ~6 m for 280 frames while reading anchored=0.00 -- its box bottom
# never reaches EGO_BOTTOM_FRAC, so it is bodywork that does not touch the frame border (a mirror,
# or a dashboard reflection). Loosening the anchor test to catch it would start rejecting genuine
# close vehicles, so it is left in and documented instead.
#
# The right fix is not a better per-track heuristic. A dashcam is bolted in place, so its own
# bodywork occupies the SAME PIXELS in every frame of every clip from that mount. A static ROI mask
# -- hand-drawn once, or derived automatically as "pixels inside some vehicle mask in >95% of
# frames" -- removes the whole class of artifact in one pass and cannot be fooled by a genuine
# convoy vehicle the way a constant-depth test can. See DEPTH_SIGNAL.md.
EGO_MAX_DEPTH = 12.0             # model metres. Bodywork sits at 3-8; real vehicles start ~20.

# --- MiDaS-small backend recalibration (see midas_depth_map()) ---------------------------------
# UNSTABLE_EGO_RATE and EGO_MAX_DEPTH above are tuned to Depth-Anything-V2's roughly-metric scale.
# MiDaS's inverted-disparity output lives on a wildly different, non-metric scale -- measured on
# IMG_0063 (n=6 tracks, 1 bodywork case): z ranges ~0.002-0.004 for the one caught bodywork track
# vs >=0.0089 for every genuine vehicle (a real gap, just ~500x smaller in absolute terms); the one
# genuinely-unstable track (near-zero denominator, nonsensical ratio -7.85) had ego_rate=2.6e-6,
# every other track's ego_rate was >=1.7e-5. One clip, one calibration pass -- not tuned the way
# the metric-backend constants above are (multiple clips, explicit gaps stated).
UNSTABLE_EGO_RATE_MIDAS = 1e-5
EGO_MAX_DEPTH_MIDAS = 0.006
EGO_MAX_EDGE_JITTER_FRAC = 0.005 # std of the box's BOTTOM edge / frame height. Measured bodywork
                                 # sits at 0.0000-0.0010, so this has a 5x margin.
EGO_BOTTOM_FRAC = 0.93           # box bottom must reach this far down the frame
EGO_MIN_ANCHORED_FRAC = 0.80     # ...in at least this fraction of the track's frames

# --- static ROI mask (catches what the geometric test above misses) --------------------------
# A dashcam is bolted in place, so its own bodywork occupies the SAME PIXELS in every frame of
# every clip from that mount -- unlike the bottom-anchored/rigid test above, this needs no
# assumption about WHERE on the vehicle that bodywork is. Built automatically: accumulate, over
# the whole clip, how often each pixel was covered by ANY vehicle-class mask, then threshold. A
# pixel covered on >95% of frames is either bodywork or a vehicle parked for virtually the entire
# clip -- the latter is a real false-positive risk on a short or slow clip and is stated as such in
# DEPTH_SIGNAL.md, not hidden.
#
# This is what catches IMG_0063's car#3: it holds a constant ~6 m for 280 of the clip's 544 frames
# (51%) without ever touching the frame's bottom edge, so it fails the bottom-anchored test above.
# Its pixels are covered on almost every frame it's visible for, which the occupancy test catches
# directly instead of inferring it from box geometry.
ROI_OCCUPANCY_THRESHOLD = 0.95   # fraction of ALL processed frames a pixel must be vehicle-covered
ROI_MIN_OVERLAP_FRAC = 0.60      # a track's own box must average this much overlap with that ROI

COLOR_EGO = (180, 60, 200)       # magenta -- the ego vehicle's own bodywork, excluded

PANEL_HEIGHT = 880           # each panel is scaled to this height before they are placed side by side
HEADER_HEIGHT = 96
BANNER_HEIGHT = 40

COLOR_STOPPED = (80, 220, 80)      # BGR green
COLOR_ONCOMING = (60, 60, 235)     # red
COLOR_CONVOY = (235, 170, 40)      # blue
COLOR_AWAY = (200, 110, 20)        # darker blue -- pulling away faster than the ego vehicle
COLOR_BETWEEN = (60, 200, 235)     # amber -- same direction, slower than ego
COLOR_UNKNOWN = (150, 150, 150)    # grey -- not enough frames, or unstable denominator


def classify(ratio, unstable, ego_body=False):
    """Ratio -> (label, BGR colour). Kept deliberately blunt; see the band comment above."""
    if ego_body:
        return "EGO BODYWORK (excluded)", COLOR_EGO
    if ratio is None:
        return "no reading", COLOR_UNKNOWN
    if unstable:
        return f"r={ratio:+.2f} UNSTABLE", COLOR_UNKNOWN
    # A NEGATIVE ratio is its own physical case and the original bands lumped it in with the
    # convoy case, which is wrong. Negative means the car's depth INCREASES while the static world
    # closes in -- it is pulling away faster than the ego vehicle. Measured on a real vehicle:
    # IMG_0056 car#2, the tanker truck ahead in the same lane, 21.8 m -> 37.9 m, r = -0.49.
    if ratio < BAND_AWAY_MAX:
        return f"r={ratio:+.2f} MOVING AWAY", COLOR_AWAY
    if ratio < BAND_CONVOY_MAX:
        return f"r={ratio:+.2f} MOVING w/ ego", COLOR_CONVOY
    if ratio < BAND_STOPPED_LO:
        return f"r={ratio:+.2f} same dir, slower", COLOR_BETWEEN
    if ratio <= BAND_STOPPED_HI:
        return f"r={ratio:+.2f} STOPPED-like", COLOR_STOPPED
    return f"r={ratio:+.2f} ONCOMING", COLOR_ONCOMING


def measure(video, device, limit, depth_panel_path, max_depth=0.0,
            load_fn=load_depth_pipeline, map_fn=depth_map):
    """
    Pass 1. Runs detection + tracking + depth once, writes the depth panel to its own temp video,
    and returns everything pass 2 needs to draw. Tracking is run ONCE on purpose: ByteTrack over
    this project's stack is not bit-reproducible between runs (documented in v11's README), so
    re-tracking in pass 2 could hand the same car a different id and silently mislabel the render.

    load_fn/map_fn: pluggable depth backend, defaulting to the usual Depth-Anything-V2 pair. See
    load_midas_small()/midas_depth_map() below for the lighter alternative and --depth-backend.
    """
    dpipe = load_fn(device)
    car_model = YOLO(CAR_MODEL, task="segment")

    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"could not open {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    limit = limit or total

    track_depth = defaultdict(list)     # tid -> [(frame_idx, median depth m)]
    track_boxes = defaultdict(list)     # tid -> [(x1, y1, x2, y2)] for the ego-bodywork tests
    roi_occupancy = None                 # (H, W) float32, += 1 per frame a pixel is vehicle-covered
    ego_dz = {}                         # frame_idx -> GLOBAL median ego depth change (display only)
    ego_samples = {}                    # frame_idx -> (za: background depths at t, dz: their delta)
                                         # -- the depth-matched denominator is built from this, not
                                         # from ego_dz, which stays around only for the on-screen
                                         # "raw" readout so its noise remains visible.
    frame_boxes = defaultdict(list)     # frame_idx -> [(tid, x1, y1, x2, y2, depth_m or None)]

    writer = None
    frame_h = frame_w = 0
    prev_gray = prev_depth = prev_scale = None
    prev_any_mover = None
    fidx = 0

    while fidx < limit:
        ok, frame = cap.read()
        if not ok:
            break

        res = car_model.track(frame, classes=BACKGROUND_EXCLUDE_CLASSES,
                              tracker="bytetrack.yaml", persist=True, verbose=False)[0]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        depth, dscale = map_fn(dpipe, frame)
        frame_h, frame_w = frame.shape[:2]
        if roi_occupancy is None:
            roi_occupancy = np.zeros((frame_h, frame_w), dtype=np.float32)

        if writer is None:
            writer = cv2.VideoWriter(depth_panel_path, cv2.VideoWriter_fourcc(*"mp4v"),
                                     fps, (depth.shape[1], depth.shape[0]))

        any_mover = np.zeros(frame.shape[:2], dtype=bool)
        if res.boxes is not None and res.boxes.id is not None and res.masks is not None:
            ids = res.boxes.id.int().cpu().numpy()
            xyxy = res.boxes.xyxy.cpu().numpy()
            cls = res.boxes.cls.int().cpu().numpy()
            md = res.masks.data.cpu().numpy()
            for i, tid in enumerate(ids):
                m = md[i]
                if m.shape[:2] != frame.shape[:2]:
                    m = cv2.resize(m, (frame.shape[1], frame.shape[0]),
                                   interpolation=cv2.INTER_NEAREST)
                mb = m > 0.5
                # EVERY detected mover masks the background, pedestrians included -- that is what
                # BACKGROUND_EXCLUDE_CLASSES is for, and the ego-rate denominator depends on it.
                any_mover |= mb
                # ...but only vehicles get measured and drawn.
                if int(cls[i]) not in TARGET_VEHICLE_CLASSES:
                    continue
                zmed = None
                if mb.sum() >= MIN_CAR_MASK_PX:
                    ds = cv2.resize(mb.astype(np.uint8), (depth.shape[1], depth.shape[0]),
                                    interpolation=cv2.INTER_NEAREST) > 0
                    if ds.sum() >= 20:
                        zmed = float(np.median(depth[ds]))
                        track_depth[int(tid)].append((fidx, zmed))
                    # Accumulated regardless of the range gate below -- occupancy needs every
                    # vehicle-class mask in the clip to build an accurate static ROI, gated or not.
                    roi_occupancy[mb] += 1.0
                # Range gate: a parked-car detector has no business ruling on a vehicle 70 m up the
                # road that occupies 30 px. Note this gates DRAWING only -- track_depth above has
                # already recorded this frame. That is deliberate: the ratio is a slope, and it is
                # far better estimated over the vehicle's whole approach (78 m -> 29 m) than over
                # the handful of frames it spends inside the gate. So a boxed vehicle carries a
                # ratio measured from more data than the gate itself admits.
                if max_depth and (zmed is None or zmed > max_depth):
                    continue
                x1, y1, x2, y2 = xyxy[i]
                track_boxes[int(tid)].append((int(x1), int(y1), int(x2), int(y2)))
                frame_boxes[fidx].append((int(tid), int(x1), int(y1), int(x2), int(y2), zmed))

        # Ego reference: depth change of the SAME physical background points across the pair.
        # Not "median depth of this frame's features" -- that quantity swings between 22 m and 54 m
        # frame to frame (diag_depth_trace.py) and is not a measurement of anything.
        if prev_gray is not None:
            bgm = (~prev_any_mover).astype(np.uint8) * 255
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
                        za_v, dz_v = za[v], (zb[v] - za[v])
                        ego_dz[fidx] = float(np.median(dz_v))
                        ego_samples[fidx] = (za_v, dz_v)

        writer.write(colorize_depth(depth))

        prev_gray, prev_depth, prev_scale, prev_any_mover = gray, depth, dscale, any_mover
        fidx += 1
        if fidx % 50 == 0:
            print(f"  pass 1  {fidx}/{limit}", file=sys.stderr)

    cap.release()
    if writer is not None:
        writer.release()
    static_roi = ((roi_occupancy / max(fidx, 1)) >= ROI_OCCUPANCY_THRESHOLD
                  if roi_occupancy is not None else None)
    return (track_depth, ego_dz, ego_samples, frame_boxes, track_boxes, static_roi,
            fidx, fps, frame_h, frame_w)


def colorize_depth(depth):
    """Metric depth -> TURBO colormap. Near = red end, far = blue end, clipped at 80 m so that a
    handful of sky pixels reading 200 m don't flatten the whole street into one colour."""
    d = np.clip(depth, 0.0, 80.0)
    norm = (255.0 * (1.0 - d / 80.0)).astype(np.uint8)
    return cv2.applyColorMap(norm, cv2.COLORMAP_TURBO)


def roi_overlap_fraction(boxes, static_roi):
    """Average, over a track's own boxes, of what fraction of each box's area falls inside the
    accumulated static-ROI mask (see ROI_OCCUPANCY_THRESHOLD). Cheap: no video decode, just array
    slicing over boxes already collected in pass 1."""
    if static_roi is None or not boxes:
        return 0.0
    h, w = static_roi.shape
    fracs = []
    for x1, y1, x2, y2 in boxes:
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(w, x2), min(h, y2)
        if x2 <= x1 or y2 <= y1:
            continue
        fracs.append(float(static_roi[y1:y2, x1:x2].mean()))
    return float(np.mean(fracs)) if fracs else 0.0


def is_ego_bodywork(pts, boxes, frame_h, frame_w, static_roi=None):
    """
    Is this track the ego vehicle's own bonnet / dashboard / wing mirror rather than a real vehicle?

    Motivated by measurement, not by guessing: on IMG_0057, 10 of 25 measured tracks sat at a
    constant 3-4 m for the whole clip. They are the car the camera is bolted to. Left in, they are
    not merely noise -- they read ratio ~= 0, which this method interprets as "moving at exactly
    ego speed", and they would become permanent phantom stationary vehicles the moment the signal
    reaches a verdict. The range gate makes this WORSE, not better: gating on distance keeps the
    near-field bodywork and discards the real vehicles further up the road.

    TWO independent tests, combined with OR -- each catches what the other misses:

      A) GEOMETRIC RIGIDITY. A first attempt used "depth barely changes" and failed: IMG_0063's
         bonnet has a depth spread of 0.334 of its median (noise on a near-field surface), against
         a 0.30 threshold, so it slipped through -- and flat depth can't distinguish bodywork from
         a genuine convoy vehicle anyway, since both hold their distance. What actually works:
         bodywork is BOLTED TO THE CAMERA, so its box does not move in the image, ever.
           1. NEAR      -- median depth below EGO_MAX_DEPTH.
           2. RIGID     -- the box's BOTTOM edge barely moves across the whole track (the top edge
                           is the bonnet/road boundary, redrawn every frame -- tested and rejected,
                           see EGO_MAX_EDGE_JITTER_FRAC's comment).
           3. ANCHORED  -- the box sits against the bottom edge of the frame in most frames.

      B) STATIC ROI OVERLAP. Catches what (A) misses: `car#3` in IMG_0063 holds a constant ~6 m for
         280 frames without ever touching the frame's bottom edge (a mirror, or a dashboard
         reflection) -- it fails ANCHORED, so (A) alone lets it through. (B) doesn't care about box
         geometry at all: it asks whether this track's box sits inside pixels that were vehicle-
         covered on >95% of every frame in the whole clip, which only bodywork can be.

    A stopped car close ahead can satisfy NEAR and even ANCHORED, but its box grows steadily as the
    ego closes on it, so it fails RIGID; and it cannot occupy the same pixels for 95% of a clip
    unless it is visible for virtually the entire clip, which (B) states as a real caveat.
    """
    if not boxes:
        return False, {}
    z = np.array([p[1] for p in pts], dtype=float)
    zmed = float(np.median(z))
    y1 = np.array([b[1] for b in boxes], dtype=float)
    y2 = np.array([b[3] for b in boxes], dtype=float)
    roi_frac = roi_overlap_fraction(boxes, static_roi)
    m = {
        "zmed": zmed,
        "jit1": float(np.std(y1)) / frame_h,
        "jit2": float(np.std(y2)) / frame_h,
        "anch": float(np.mean(y2 >= frame_h * EGO_BOTTOM_FRAC)),
        "roi": roi_frac,
    }
    rigid_anchored = (zmed <= EGO_MAX_DEPTH
                      and m["jit2"] < EGO_MAX_EDGE_JITTER_FRAC
                      and m["anch"] >= EGO_MIN_ANCHORED_FRAC)
    roi_hit = zmed <= EGO_MAX_DEPTH and roi_frac >= ROI_MIN_OVERLAP_FRAC
    return (rigid_anchored or roi_hit), m


def depth_matched_ego_rate(pts, ego_samples):
    """
    TESTED AND REJECTED -- kept for the record, not called by aggregate() below. See the writeup
    in DEPTH_SIGNAL.md ("A tested fix that made things worse").

    The idea: instead of one ego rate per frame pooled from EVERY background point, pool only the
    background points whose OWN depth is close to the car's depth in that frame, on the theory that
    a car at 60 m should be compared against the part of the static world that is also around 60 m.

    Measured result: on IMG_0063, the one clip with ground truth, this COLLAPSED the separation the
    unmatched version already had -- car#94 (STOPPED) moved 0.67 -> 1.03, car#68 (ONCOMING) moved
    1.57 -> 1.28, cutting the separation factor from 2.3x to 1.24x. It also did not fix IMG_0065:
    a 500-frame subset still read 8 of 12 tracks ONCOMING, including a `PARKED`-classified vehicle
    at the same ~1.7 it read before. Two negative results, not one -- shipped nowhere.

    Left implemented rather than deleted because the failure itself is informative: whatever is
    actually wrong with IMG_0065 is not "the reference points are too close to the camera". A
    depth-matched reference should, if that hypothesis were right, have made the ground-truth clip
    at least as good. It made it worse instead.
    """
    band = DEPTH_MATCH_BAND_FRAC
    matched_pool = None
    while True:
        chunks = []
        for fidx, zcar in pts:
            samp = ego_samples.get(fidx)
            if samp is None or zcar <= 0:
                continue
            za, dz = samp
            lo, hi = zcar * (1 - band), zcar * (1 + band)
            sel = (za >= lo) & (za <= hi)
            if sel.any():
                chunks.append(dz[sel])
        pooled = np.concatenate(chunks) if chunks else np.array([])
        if pooled.size >= DEPTH_MATCH_MIN_POINTS:
            matched_pool = pooled
            break
        if band >= DEPTH_MATCH_MAX_BAND_FRAC:
            break
        band += DEPTH_MATCH_WIDEN_STEP

    if matched_pool is not None:
        return float(np.median(matched_pool)), int(matched_pool.size), band, True

    all_chunks = [ego_samples[fidx][1] for fidx, _ in pts if fidx in ego_samples]
    if not all_chunks:
        return None, 0, band, False
    pooled = np.concatenate(all_chunks)
    return float(np.median(pooled)), int(pooled.size), band, False


def aggregate(track_depth, ego_dz, track_boxes=None, frame_h=0, frame_w=0, static_roi=None):
    """Theil-Sen slope per track / ego rate over the same window -> ratio. Same maths the passing
    probe used; the per-frame-ratio version (probe 1) failed and is kept in probe_depth_rate.py.

    Uses the ORIGINAL global-median ego rate, not depth_matched_ego_rate() above -- that was tried
    and made the one ground-truthed clip worse. See that function's docstring."""
    out = {}
    track_boxes = track_boxes or {}
    for tid, pts in track_depth.items():
        if len(pts) < MIN_FRAMES_PER_TRACK:
            continue
        f = np.array([p[0] for p in pts], dtype=float)
        z = np.array([p[1] for p in pts], dtype=float)
        car_slope, _, _, _ = theilslopes(z, f)

        window = [ego_dz[i] for i in range(int(f.min()), int(f.max()) + 1) if i in ego_dz]
        if len(window) < 10:
            continue
        ego_rate = float(np.median(window))
        if abs(ego_rate) < 1e-6:
            continue
        out[tid] = {
            "ratio": car_slope / ego_rate,
            "car_slope": car_slope,
            "ego_rate": ego_rate,
            "n": len(pts),
            "z0": z[0],
            "z1": z[-1],
            "unstable": abs(ego_rate) < UNSTABLE_EGO_RATE,
        }
        if frame_h:
            eb, m = is_ego_bodywork(pts, track_boxes.get(tid, []), frame_h, frame_w, static_roi)
            out[tid]["ego_body"], out[tid]["ego_metrics"] = eb, m
        else:
            out[tid]["ego_body"], out[tid]["ego_metrics"] = False, {}
    return out


def fit_panel(img, height):
    h, w = img.shape[:2]
    return cv2.resize(img, (int(round(w * height / h)), height), interpolation=cv2.INTER_AREA)


def draw_boxes(frame, boxes, stats, dscale=1.0):
    for tid, x1, y1, x2, y2, zmed in boxes:
        st = stats.get(tid)
        label, color = classify(st["ratio"] if st else None,
                                st["unstable"] if st else False,
                                st["ego_body"] if st else False)
        thick = 1 if (st is None or st["unstable"] or st["ego_body"]) else 3
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, thick)

        txt = f"car#{tid}  {label}"
        if zmed is not None:
            txt += f"  {zmed / dscale:.0f}m"
        (tw, th), _ = cv2.getTextSize(txt, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
        ty = max(y1 - 6, th + 6)
        cv2.rectangle(frame, (x1, ty - th - 6), (x1 + tw + 8, ty + 4), (0, 0, 0), -1)
        cv2.putText(frame, txt, (x1 + 4, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2,
                    cv2.LINE_AA)
    return frame


def compose(rgb_panel, depth_panel, fidx, fps, ego_rate, n_tracks, gate_txt=""):
    left = fit_panel(rgb_panel, PANEL_HEIGHT)
    right = fit_panel(depth_panel, PANEL_HEIGHT)
    body = np.hstack([left, right])
    w = body.shape[1]

    header = np.zeros((HEADER_HEIGHT, w, 3), dtype=np.uint8)
    t = fidx / fps if fps else 0.0
    # Deliberately labelled "raw": this is the single-frame-pair ego rate and it is noisy enough to
    # flip sign. The ratios drawn on the cars do NOT use it directly -- they use its median over
    # each track's whole window. Showing the raw value keeps the noise visible instead of hiding it.
    ego_txt = ("ego rate (raw/frame): n/a" if ego_rate is None
               else f"ego rate (raw/frame): {ego_rate:+.3f} m")
    line = f"frame {fidx}   t={t:5.1f}s   {ego_txt}   vehicles measured: {n_tracks}{gate_txt}"
    hs = 0.62
    while hs > 0.35 and cv2.getTextSize(line, cv2.FONT_HERSHEY_SIMPLEX, hs, 1)[0][0] > w - 24:
        hs -= 0.02
    cv2.putText(header, line, (12, 32), cv2.FONT_HERSHEY_SIMPLEX, hs, (240, 240, 240), 1,
                cv2.LINE_AA)

    legend = [("r~1 STOPPED-like", COLOR_STOPPED), ("r>1.4 ONCOMING", COLOR_ONCOMING),
              ("r~0 moving w/ ego", COLOR_CONVOY), ("r<0 moving away", COLOR_AWAY),
              ("between", COLOR_BETWEEN), ("unstable", COLOR_UNKNOWN),
              ("ego bodywork", COLOR_EGO)]
    x = 12
    for text, color in legend:
        cv2.rectangle(header, (x, 52), (x + 18, 70), color, -1)
        cv2.putText(header, text, (x + 24, 67), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (225, 225, 225), 1,
                    cv2.LINE_AA)
        x += 34 + cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)[0][0]

    banner = np.full((BANNER_HEIGHT, w, 3), (28, 28, 120), dtype=np.uint8)
    # Deliberately does NOT quote a sample size. An earlier version said "probed on 2 vehicles,
    # 1 video", which went stale the moment a third vehicle was measured -- and it was already
    # burned into rendered frames by then. The caveat points at the document instead, which is the
    # thing that gets updated.
    text = ("EXPERIMENTAL -- NOT part of the v12 verdict. Ratios are whole-track, non-causal. "
            "Read depth/DEPTH_SIGNAL.md before quoting any number here.")
    # Shrink to fit rather than let the caveat run off the edge -- a truncated caveat is worse than
    # a small one, and panel width changes with the source video's aspect ratio.
    scale = 0.52
    while scale > 0.3 and cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, 1)[0][0] > w - 24:
        scale -= 0.02
    cv2.putText(banner, text, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, scale, (235, 235, 235), 1,
                cv2.LINE_AA)

    return np.vstack([header, body, banner])


def main():
    ap = argparse.ArgumentParser(description="Render the depth-rate signal as a side-by-side video.")
    ap.add_argument("--input", default=os.path.join(V12_DIR, "videos", "source", "IMG_0063.MOV"))
    ap.add_argument("--output", default=os.path.join(V12_DIR, "videos", "depth",
                                                     "depth_rate_IMG_0063.mp4"))
    ap.add_argument("--device", default="mps")
    ap.add_argument("--max-frames", type=int, default=0, help="0 = whole clip")
    ap.add_argument("--max-depth", type=float, default=0.0,
                    help="range gate: ignore vehicles further than this many metres (0 = no limit). "
                         "Interpreted AFTER --depth-scale, i.e. in real metres if the scale is set.")
    ap.add_argument("--depth-scale", type=float, default=1.0,
                    help="model_depth / scale = real_depth. 1.0 = trust the model's raw output "
                         "(it is wrong -- see below). Try 3.0. Details in DEPTH_SIGNAL.md.")
    ap.add_argument("--depth-backend", choices=["depth-anything", "midas-small"],
                    default="depth-anything",
                    help="EXPERIMENT: midas-small is ~2.5x faster (49ms vs 123ms/frame, measured "
                         "on this project's own footage) but has NO metric scale at all (not even "
                         "the current model's wrong-by-~3x estimate) and a much lower native "
                         "resolution -- --max-depth/--depth-scale are meaningless with it. Only "
                         "the RATIO signal is expected to still work (see midas_depth_map()).")
    args = ap.parse_args()

    load_fn, map_fn = ((load_midas_small, midas_depth_map) if args.depth_backend == "midas-small"
                       else (load_depth_pipeline, depth_map))
    if args.depth_backend == "midas-small":
        global UNSTABLE_EGO_RATE, EGO_MAX_DEPTH
        UNSTABLE_EGO_RATE = UNSTABLE_EGO_RATE_MIDAS
        EGO_MAX_DEPTH = EGO_MAX_DEPTH_MIDAS
        print(f"  depth-backend=midas-small: recalibrated UNSTABLE_EGO_RATE={UNSTABLE_EGO_RATE:g}, "
              f"EGO_MAX_DEPTH={EGO_MAX_DEPTH:g} (see module comment)", file=sys.stderr)
        if args.max_depth:
            print("  !! --max-depth is meaningless with --depth-backend midas-small (no metric "
                  "scale at all) -- ignoring the range gate, drawing every measured vehicle.",
                  file=sys.stderr)
            args.max_depth = 0.0

    # The model's absolute scale is WRONG, and --max-depth is the one place that matters, because
    # "within 10 metres" is a physical claim rather than a ratio. Two independent rough checks both
    # say the model reads about 3x too far:
    #   (a) its ego rate implies ~21 km/h on footage that is visibly crawling;
    #   (b) the ego vehicle's own bonnet, physically ~2 m from the lens, reads a constant ~6.1 m.
    # Two rough agreeing estimates are a hint, not a calibration. Do not treat 3.0 as measured.
    max_depth_model = args.max_depth * args.depth_scale
    if args.max_depth:
        print(f"\n  range gate: {args.max_depth:g} m real  x  scale {args.depth_scale:g}"
              f"  ->  {max_depth_model:g} model metres", file=sys.stderr)
        if args.depth_scale == 1.0:
            print("  !! --depth-scale is 1.0, so this gate trusts the model's raw metres.\n"
                  "     The model reads roughly 3x too far (two rough checks, NOT a calibration).\n"
                  "     For ~10 real metres you probably want:  --max-depth 10 --depth-scale 3.0\n",
                  file=sys.stderr)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    tmp_depth = os.path.join(tempfile.gettempdir(),
                             f"_depth_panel_{os.getpid()}.mp4")

    gate_txt = f"   range gate: <={args.max_depth:g}m" if args.max_depth else ""
    print(f"depth model: {DEPTH_MODEL if args.depth_backend == 'depth-anything' else 'MiDaS_small (inverted 1/disparity)'}",
          file=sys.stderr)
    print(f"input:       {args.input}", file=sys.stderr)
    (track_depth, ego_dz, ego_samples, frame_boxes, track_boxes, static_roi,
     n_frames, fps, frame_h, frame_w) = measure(
        args.input, args.device, args.max_frames, tmp_depth, max_depth_model,
        load_fn=load_fn, map_fn=map_fn)
    del ego_samples  # only depth_matched_ego_rate() (tested, rejected) uses this -- see aggregate()

    stats = aggregate(track_depth, ego_dz, track_boxes, frame_h, frame_w, static_roi)
    n_ego = sum(1 for v in stats.values() if v["ego_body"])
    n_vehicles = len(stats) - n_ego
    roi_px = int(static_roi.sum()) if static_roi is not None else 0
    print(f"\nmeasured {len(stats)} tracks with >= {MIN_FRAMES_PER_TRACK} depth samples "
          f"({n_vehicles} vehicles, {n_ego} rejected as ego bodywork; "
          f"static ROI covers {roi_px} px)\n", file=sys.stderr)
    print(f"{'track':>8} {'n':>5} {'car m/f':>9} {'ego m/f':>9} {'RATIO':>8}  {'Z start':>8} "
          f"{'Z end':>8}  reading")
    print("-" * 90)
    for tid, s in sorted(stats.items(), key=lambda kv: -kv[1]["n"]):
        label, _ = classify(s["ratio"], s["unstable"], s["ego_body"])
        m = s.get("ego_metrics") or {}
        # Diagnostics for anything near enough to be a bodywork candidate, so the thresholds can be
        # re-picked from data instead of guessed. jit = std of the box edge / frame height.
        dbg = (f"   [jitTop={m['jit1']:.4f} jitBot={m['jit2']:.4f} anchored={m['anch']:.2f} "
               f"roi={m['roi']:.2f}]"
               if m and m.get("zmed", 1e9) <= EGO_MAX_DEPTH else "")
        print(f"car#{tid:<5d}{s['n']:5d} {s['car_slope']:9.3f} {s['ego_rate']:9.3f} "
              f"{s['ratio']:8.2f}  {s['z0']:8.1f} {s['z1']:8.1f}  {label}{dbg}")

    # --- pass 2: redraw the source frames with the final per-track readings ---
    cap = cv2.VideoCapture(args.input)
    dcap = cv2.VideoCapture(tmp_depth)
    writer = None
    fidx = 0
    while fidx < n_frames:
        ok, frame = cap.read()
        okd, dpanel = dcap.read()
        if not ok or not okd:
            break
        frame = draw_boxes(frame, frame_boxes.get(fidx, []), stats, args.depth_scale)
        canvas = compose(frame, dpanel, fidx, fps, ego_dz.get(fidx), n_vehicles, gate_txt)
        if writer is None:
            writer = cv2.VideoWriter(args.output, cv2.VideoWriter_fourcc(*"mp4v"), fps,
                                     (canvas.shape[1], canvas.shape[0]))
        writer.write(canvas)
        fidx += 1
        if fidx % 50 == 0:
            print(f"  pass 2  {fidx}/{n_frames}", file=sys.stderr)
    cap.release()
    dcap.release()
    if writer is not None:
        writer.release()
    if os.path.exists(tmp_depth):
        os.remove(tmp_depth)

    print(f"\nwrote {args.output}  ({fidx} frames)", file=sys.stderr)


if __name__ == "__main__":
    main()
