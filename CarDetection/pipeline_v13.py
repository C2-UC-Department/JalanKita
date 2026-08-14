"""
v13 pipeline: v12's full verdict (epi+FoE -> STOP_CLASS, v10 sign zones -> DISTURBANCE) PLUS the
depth-rate signal wired in as a tiebreaker, per docs/DEPTH_INTEGRATION_OPTIONS.md's Option B --
the recommendation already written up before this version existed.

WHAT'S NEW VS v12 (demo_scan_v12.py, kept here as _base_demo_scan_v12.py for reference):
  - Depth is measured every frame (same track ONCE architecture as depth/render_combined.py --
    one car_model.track() call feeds both the epi/FoE state machine AND the depth ratio, so there
    is no cross-run track-id matching problem).
  - Depth backend defaults to MiDaS_small (--depth-backend, see depth/render_depth_video.py):
    ~2.5x faster than Depth-Anything-V2 (49ms vs 123ms/frame, measured on this project's own
    footage), calibrated thresholds verified on IMG_0063 to correctly read the ground-truth
    STOPPED car as STOPPED-like and the ground-truth MOVING car as not-stopped. Verified ONCE, on
    one clip -- less thoroughly than the metric backend's multi-clip history. --depth-backend
    depth-anything switches back.
  - STOP_CLASS's UNRESOLVED bucket (v8's honest "could not decide") now gets ONE more chance:
    if the depth ratio lands in the STOPPED-like band, UNRESOLVED becomes "PARKED (depth)"; if it
    clearly reads moving, UNRESOLVED becomes "MOVING (depth)". Anything else (no reading, ego
    bodywork, unstable) stays UNRESOLVED. This can only fire where the pipeline already gave up --
    IMG_0056 car#1's PARKED verdict is untouched by construction.
  - Sign/zone/DISTURBANCE logic is completely unchanged from v12.

WHAT DIDN'T CHANGE: everything else. Same epi/v5, same FoE/v6, same STOP_CLASS resumption/
neighbor-sync logic, same v10 sign zones, same cross-track dedup, same confidence-floor exclusion.
"""

import argparse
import os
import sys
from collections import defaultdict, deque

# Onedir PyInstaller builds place bundled `datas` under sys._MEIPASS (the
# `_internal/` folder next to the executable), not next to a frozen module's
# own `__file__` -- without this, DEFAULT_MODEL/DEFAULT_CUSTOM_MODEL below
# would point inside the read-only .app bundle at a path that doesn't exist,
# the same class of bug worker_main.py's BASE_DIR fixes for the disturbance
# worker. Unfrozen, this is unchanged (this script's own directory), and the
# sys.path inserts below are harmless once frozen -- PyInstaller's own
# importer already resolves lib/depth's modules by name at that point.
SCRIPT_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "depth"))

import cv2
import numpy as np
import torch
from ultralytics import YOLO

import demo_scan_v5 as v5
from foe_signal import estimate_foe_and_static_flow, car_flow_points, car_foe_probability
import foe_signal as _foe_mod  # for the --frame-stride FOE_RANSAC_INLIER_THRESHOLD_PX rescale, see main()
from road_completion import encroachment_ratio_v7
from demo_scan_v6 import (
    classify_from_history, combine_states,
    FOE_SMOOTHING_WINDOW, FOE_ENTER_STATIONARY, FOE_EXIT_STATIONARY, FOE_MIN_HISTORY_FOR_CONFIDENCE,
    CONFIDENCE_GATE_K, CONFIDENCE_GATE_FLOOR, FOE_JITTER_WINDOW,
    BACKGROUND_EXCLUDE_CLASSES,
    FOE_MAX_JUMP_FRACTION_OF_DIAGONAL, FOE_JUMP_REJECT_ESCAPE_VALVE,
    STATIONARY_DEBOUNCE_SECONDS, DISPUTE_SECONDS,
)
from demo_scan_v8 import neighbor_stop_ratio, NEIGHBOR_ROW_BAND_PX, NEIGHBOR_RATIO_TRAFFIC_THRESHOLD, \
    RESUMPTION_DEBOUNCE_SECONDS, MIN_EXTRA_STATIONARY_SECONDS_FOR_PARKED
from coverage_zone import mask_max_width_span, point_in_zone, sign_coverage_zone
from sign_tracker import SIGN_MIN_VOTES_TO_TRUST, SIGN_TRACK_MAX_MISSED, SignTracker

from probe_depth_rate import (
    LK_PARAMS, BG_MAX_CORNERS, BG_QUALITY, BG_MIN_DISTANCE,
    MIN_CAR_MASK_PX, load_depth_pipeline, depth_map, sample_depth,
)
from render_depth_video import (
    aggregate, classify as depth_classify, TARGET_VEHICLE_CLASSES, ROI_OCCUPANCY_THRESHOLD,
    load_midas_small, midas_depth_map,
)
import render_depth_video as _rdv  # for the MiDaS threshold reassignment, see main()

CUSTOM_CLASS_NAMES = ["crosswalk", "sign_P", "sign_S"]
CUSTOM_COLORS = {"crosswalk": (255, 200, 0), "sign_P": (0, 165, 255), "sign_S": (0, 0, 255)}
CUSTOM_CONF_THRESHOLD = 0.2
ZONE_FILL_ALPHA = 0.30
ZONE_COLORS = {"sign_P": (0, 140, 255), "sign_S": (60, 60, 255)}
DISTURBANCE_COLOR = (0, 0, 255)

DEFAULT_CUSTOM_MODEL = os.path.join(SCRIPT_DIR, "models", "signs_crosswalk_v10_hardneg_r3_best.pt")
DEFAULT_MODEL = os.path.join(SCRIPT_DIR, "yolov8n-seg.pt")

CROSS_TRACK_IOU_THRESHOLD = 0.5
CROSS_TRACK_DEDUP_FRAME_FRAC = 0.5

# --- Option B: depth tiebreaker on UNRESOLVED, from docs/DEPTH_INTEGRATION_OPTIONS.md -----------
# BAND_STOPPED_LO/HI mirror render_depth_video.py's own bands (kept independent, not imported, so
# a future retune of one doesn't silently retune the other without a deliberate decision).
DEPTH_BAND_STOPPED_LO = 0.65
DEPTH_BAND_STOPPED_HI = 1.40
DEPTH_BAND_CONVOY_MAX = 0.35

DETERMINISM_SEED = 42


def apply_determinism_settings():
    cv2.setNumThreads(1)
    cv2.setRNGSeed(DETERMINISM_SEED)
    torch.manual_seed(DETERMINISM_SEED)
    torch.set_num_threads(1)
    os.environ["PYTHONHASHSEED"] = str(DETERMINISM_SEED)


# --- --frame-stride scaling helpers -----------------------------------------------------------
# All the epi/FoE/sign-tracker/depth constants below were tuned assuming one native video frame of
# elapsed time between consecutive processed samples. With --frame-stride > 1, only every Nth
# native frame is actually run through the heavy models (see main()'s loop), so real elapsed time
# and real pixel motion between consecutive PROCESSED samples both grow by ~stride. These are
# first-pass estimates, not derivations -- validated against this project's own ground-truth clips
# (see docs), not assumed correct by construction. At stride=1 every one of these is a no-op.
def _scale_px(base, stride):
    """Family C: px/spatial thresholds -- real inter-sample motion grows ~linearly with stride."""
    return base * stride


def _scale_window(base, stride):
    """Family D: frame-count windows meant to span a fixed real-world duration."""
    return max(1, round(base / stride))


def _scale_ema_alpha(alpha, stride):
    """GROUND_POINT_EMA_ALPHA is a decay rate, not a frame count -- naive division is dimensionally
    wrong. Compound the per-native-frame decay so the real-time smoothing envelope is preserved."""
    return 1.0 - (1.0 - alpha) ** stride


def box_iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    inter = iw * ih
    if inter == 0:
        return 0.0
    area_a = max(0, ax2 - ax1) * max(0, ay2 - ay1)
    area_b = max(0, bx2 - bx1) * max(0, by2 - by1)
    return inter / (area_a + area_b - inter)


def draw_zone_polygon(frame, zone, color):
    if zone is None or len(zone["polygon"]) < 3:
        return
    pts = np.array(zone["polygon"], dtype=np.int32).reshape((-1, 1, 2))
    overlay = frame.copy()
    cv2.fillPoly(overlay, [pts], color)
    cv2.addWeighted(overlay, ZONE_FILL_ALPHA, frame, 1 - ZONE_FILL_ALPHA, 0, dst=frame)
    cv2.polylines(frame, [pts], isClosed=True, color=color, thickness=2)


def draw_legend(frame):
    lines = [
        "car: YOLOv8n-seg+ByteTrack+v5 epipolar+v6 FoE -> v7 severity/lane -> v8 STOP_CLASS (PARKED/TRAFFIC_STOPPED/UNRESOLVED)",
        "sign_P/sign_S: v10 round-3 retrained model, agnostic-NMS + IoU track + majority vote; shaded corridor = HEURISTIC zone, not a measurement",
        "DISTURBANCE = STOP_CLASS PARKED (incl. depth tiebreak) AND ground point ever inside a sign's zone.",
        "v13 NEW: depth-rate ratio tiebreaks STOP_CLASS=UNRESOLVED only -- see docs/CHANGELOG_V12_TO_V13.md",
        "EXPERIMENTAL: v8's stop classifier, v10's zone, and the depth tiebreaker are each their own unvalidated heuristic.",
    ]
    y = frame.shape[0] - 15 - (len(lines) - 1) * 16
    for line in lines:
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (255, 255, 255), 1, cv2.LINE_AA)
        y += 16


def main():
    parser = argparse.ArgumentParser(description="v13: v12's DISTURBANCE verdict + depth tiebreaker on UNRESOLVED.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--custom-model", default=DEFAULT_CUSTOM_MODEL)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--jpeg-quality", type=int, default=90)
    parser.add_argument("--deterministic", action="store_true",
                         help="Force reproducible output: single-threaded CPU + fixed seeds "
                              "(overrides --device to cpu). Much slower.")
    parser.add_argument("--depth-backend", choices=["midas-small", "depth-anything"],
                         default="midas-small",
                         help="midas-small (default): ~2.5x faster, calibrated on one clip. "
                              "depth-anything: the original, more-validated backend, slower.")
    parser.add_argument("--screenshot-dir", default=None,
                         help="Where demo_screenshots.py writes its output (default: "
                              "demo/screenshots/<video>/ inside this repo). JalanKita Mac passes "
                              "its own session working directory here.")
    parser.add_argument("--frame-stride", type=int, default=1,
                         help="Process only every Nth native video frame (default 1: every frame, "
                              "identical to pre-existing behavior). CLI-only research flag -- "
                              "JalanKita Mac never passes this. N=1 is a structural no-op for every "
                              "constant this flag touches; N>1 is unvalidated against ByteTrack's "
                              "and the sign tracker's own IoU/Kalman association, which cannot be "
                              "fixed by rescaling constants -- see docs/ for the validation clips.")
    args = parser.parse_args()
    if args.frame_stride < 1:
        parser.error("--frame-stride must be >= 1")

    if args.deterministic:
        apply_determinism_settings()
        if args.device != "cpu":
            print(f"--deterministic forces device=cpu (was --device {args.device})", file=sys.stderr)
        args.device = "cpu"

    if args.depth_backend == "midas-small":
        load_fn, map_fn = load_midas_small, midas_depth_map
        _rdv.UNSTABLE_EGO_RATE = _rdv.UNSTABLE_EGO_RATE_MIDAS
        _rdv.EGO_MAX_DEPTH = _rdv.EGO_MAX_DEPTH_MIDAS
    else:
        load_fn, map_fn = load_depth_pipeline, depth_map

    # --frame-stride depth rescale, after the MiDaS-backend swap above so it applies to whichever
    # backend's base value just won (no-op at stride=1).
    _rdv.MIN_FRAMES_PER_TRACK = _scale_window(_rdv.MIN_FRAMES_PER_TRACK, args.frame_stride)
    _rdv.UNSTABLE_EGO_RATE = _scale_px(_rdv.UNSTABLE_EGO_RATE, args.frame_stride)

    car_model = YOLO(args.model)
    custom_model = YOLO(args.custom_model)
    road_segmenter = v5.RoadSegmenter(torch.device(args.device))
    # max_missed scaled here (before fps/width/height are known below) since SignTracker only
    # needs the stride itself, already parsed -- see the _scale_window family below for the rest.
    sign_tracker = SignTracker(max_missed=_scale_window(SIGN_TRACK_MAX_MISSED, args.frame_stride))
    dpipe = load_fn(args.device if args.depth_backend == "depth-anything" else "cpu")

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        sys.exit(f"Could not open {args.input}")
    # Auto-rotate to display-upright. Portrait iPhone clips carry a rotation matrix, and
    # without this the frames arrive sideways -- the detector still fires, on a rotated road.
    # Mirrors RoadDamage/video_frames.py's identical fix for the same source footage.
    try:
        cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    except Exception:  # noqa: BLE001 -- older OpenCV simply lacks the property
        pass
    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    total_frames_expected = max(1, -(-total_frames // args.frame_stride))  # ceil div, for progress display only

    # --deterministic forces device=cpu above; --frame-stride only ever passed by hand from the
    # CLI (see the flag's own help text) -- effective_fps is what should feed every SECONDS-based
    # frame-count threshold below, since fewer frames are now processed per real second of video.
    effective_fps = fps / args.frame_stride
    flag_after_frames = max(1, int(round(v5.FLAG_AFTER_SECONDS * effective_fps)))
    stationary_debounce_frames = max(1, int(round(STATIONARY_DEBOUNCE_SECONDS * effective_fps)))
    resumption_debounce_frames = max(1, int(round(RESUMPTION_DEBOUNCE_SECONDS * effective_fps)))
    dispute_frames = max(1, int(round(DISPUTE_SECONDS * effective_fps)))

    # --- family C/D constant rescaling for --frame-stride (no-op at stride=1) ---
    # Module-qualified constants (v5.X, _rdv.X) are live attribute lookups everywhere they're used
    # in lib/demo_scan_v5.py and depth/render_depth_video.py, so reassigning them here propagates
    # automatically -- same idiom already used for the MiDaS threshold swap below. Bare-name
    # imports (FOE_*, imported at the top of this file) are one-time value copies and must be
    # reassigned as local names instead; reassigning demo_scan_v6.FOE_* would do nothing.
    v5.RESIDUAL_ENTER_STATIONARY_PX = _scale_px(v5.RESIDUAL_ENTER_STATIONARY_PX, args.frame_stride)
    v5.RESIDUAL_EXIT_STATIONARY_PX = _scale_px(v5.RESIDUAL_EXIT_STATIONARY_PX, args.frame_stride)
    v5.FUNDAMENTAL_RANSAC_THRESHOLD_PX = _scale_px(v5.FUNDAMENTAL_RANSAC_THRESHOLD_PX, args.frame_stride)
    v5.RESIDUAL_SMOOTHING_WINDOW = _scale_window(v5.RESIDUAL_SMOOTHING_WINDOW, args.frame_stride)
    v5.MIN_HISTORY_FOR_CONFIDENCE = _scale_window(v5.MIN_HISTORY_FOR_CONFIDENCE, args.frame_stride)
    v5.GROUND_POINT_EMA_ALPHA = _scale_ema_alpha(v5.GROUND_POINT_EMA_ALPHA, args.frame_stride)

    _foe_mod.FOE_RANSAC_INLIER_THRESHOLD_PX = _scale_px(_foe_mod.FOE_RANSAC_INLIER_THRESHOLD_PX, args.frame_stride)

    global FOE_ENTER_STATIONARY, FOE_EXIT_STATIONARY, FOE_MAX_JUMP_FRACTION_OF_DIAGONAL
    global FOE_SMOOTHING_WINDOW, FOE_MIN_HISTORY_FOR_CONFIDENCE, FOE_JITTER_WINDOW
    FOE_ENTER_STATIONARY = _scale_px(FOE_ENTER_STATIONARY, args.frame_stride)
    FOE_EXIT_STATIONARY = _scale_px(FOE_EXIT_STATIONARY, args.frame_stride)
    FOE_MAX_JUMP_FRACTION_OF_DIAGONAL = _scale_px(FOE_MAX_JUMP_FRACTION_OF_DIAGONAL, args.frame_stride)
    FOE_SMOOTHING_WINDOW = _scale_window(FOE_SMOOTHING_WINDOW, args.frame_stride)
    FOE_MIN_HISTORY_FOR_CONFIDENCE = _scale_window(FOE_MIN_HISTORY_FOR_CONFIDENCE, args.frame_stride)
    FOE_JITTER_WINDOW = _scale_window(FOE_JITTER_WINDOW, args.frame_stride)

    foe_max_jump_px = FOE_MAX_JUMP_FRACTION_OF_DIAGONAL * float(np.hypot(width, height))

    prev_gray = None
    ground_point_history = {}
    epi_history = defaultdict(lambda: deque(maxlen=v5.RESIDUAL_SMOOTHING_WINDOW))
    foe_history = defaultdict(lambda: deque(maxlen=FOE_SMOOTHING_WINDOW))
    epi_state = defaultdict(lambda: "uncertain")
    foe_state = defaultdict(lambda: "uncertain")
    combined_committed = defaultdict(lambda: "uncertain")
    stationary_candidate_streak = defaultdict(int)
    disagreement_streak = defaultdict(int)
    stationary_streak = defaultdict(int)

    ever_flagged = defaultdict(bool)
    post_flag_moving_streak = defaultdict(int)
    resumed_after_flagged = defaultdict(bool)
    neighbor_ratio_samples = defaultdict(list)

    frames_in_any_zone = defaultdict(int)
    ever_flagged_in_zone = defaultdict(bool)

    ever_confident = defaultdict(bool)
    pair_cooccurrence = defaultdict(int)
    track_conf_sum = defaultdict(float)
    track_conf_n = defaultdict(int)

    track_stats = defaultdict(lambda: {
        "frames_seen": 0, "frames_stationary": 0, "frames_uncertain": 0, "frames_disputed": 0,
        "epi_frames_stationary": 0, "foe_frames_stationary": 0,
        "stationary_candidacies_aborted": 0, "max_disagreement_streak": 0,
        "first_frame": None, "last_frame": None,
    })
    severity_samples = defaultdict(list)
    no_road_data_count = 0
    fundamental_failures = 0
    foe_estimation_failures = 0
    frames_with_flow = 0
    epi_reading_failures = 0
    foe_reading_failures = 0
    last_accepted_foe_point = None
    foe_jump_reject_streak = 0
    foe_jump_rejections = 0
    prev_raw_foe_point = None
    foe_jitter_history = deque(maxlen=FOE_JITTER_WINDOW)
    foe_gate_admissions = 0
    foe_gate_rejections = 0

    zone_metric_frames = 0
    zone_illustrative_frames = 0
    zone_none_frames = 0

    # --- depth state (see depth/render_combined.py for the pattern this is copied from) ---
    track_depth = defaultdict(list)
    track_boxes = defaultdict(list)
    roi_occupancy = np.zeros((height, width), dtype=np.float32)
    ego_dz = {}
    prev_depth = prev_scale = prev_any_mover = None

    frame_cache = {}
    # Truly pristine per-frame snapshot -- taken below right after gray/depth are derived and
    # BEFORE draw_road_overlay (or anything else) mutates `frame`. frame_cache, by contrast, is
    # cached at the very end of the loop and therefore carries every pipeline overlay (road tint,
    # corridor, sign zones, legend, timestamp). demo_screenshots.py's "_clean.jpg" used to be
    # sourced from frame_cache too -- same 15% green road-tint contamination this file's own
    # gray/depth ordering fix (see NOTE below) already worked around for internal optical
    # flow/depth, just never carried through to what OFRSNet actually gets handed.
    pristine_frame_cache = {}
    car_draw_by_frame = defaultdict(list)
    # NEW: every (frame_idx, box) a track was seen at, for the demo screenshot generator -- lets it
    # pick the MIDDLE frame of a track's observed span (farthest-to-nearest) once first_frame/
    # last_frame are both known, rather than only ever having the first frame's box on hand.
    track_frame_boxes = defaultdict(list)

    # frame_idx stays "the Nth PROCESSED frame" (unchanged meaning from before --frame-stride
    # existed) -- this is what keeps the `contiguous = prev_gp_entry[0] == frame_idx - 1` check
    # further below working with zero changes, since consecutive PROCESSED frames are still
    # index-adjacent in this space. native_idx is the true native video frame counter, used only
    # to decide which frames to skip; native_frame_number[frame_idx] records the native index a
    # given processed frame actually came from, for every seconds/timestamp DISPLAY calculation
    # below (those must reflect true elapsed time, not processed-frame count).
    frame_idx = 0
    native_idx = 0
    native_frame_number = []
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if args.frame_stride > 1 and (native_idx % args.frame_stride) != 0:
            native_idx += 1
            continue

        native_frame_number.append(native_idx)
        native_idx += 1

        placed_label_rects = []

        car_result = car_model.track(
            frame, classes=BACKGROUND_EXCLUDE_CLASSES, tracker="bytetrack.yaml", persist=True, verbose=False
        )[0]
        custom_result = custom_model.predict(frame, conf=CUSTOM_CONF_THRESHOLD, agnostic_nms=True, verbose=False)[0]
        road_mask = road_segmenter.drivable_mask(frame)

        # NOTE: gray/depth MUST be derived before draw_road_overlay mutates `frame` below.
        # draw_road_overlay() blends a 15% green tint over every drivable-area pixel via
        # cv2.addWeighted(..., dst=frame) -- IN PLACE. It used to run first, so both optical
        # flow (gray) and the depth model were reading a tinted frame instead of the clean
        # camera image, right across the road surface where the LK background points and car
        # ground-contact points live. Found by comparing pipeline_v13.py's in-pipeline depth
        # reading for IMG_0063's ground-truth STOPPED car (r=-0.06, wrong) against the same car
        # in the standalone depth probe (r=+1.04, correct) -- the standalone probe never calls
        # draw_road_overlay, so it never had this contamination. v12's original pipeline has the
        # same ordering (draw_road_overlay before cv2.cvtColor), so epi/FoE have carried the same
        # tinted-frame optical flow since before this file existed -- not touched here, flagged
        # to the user separately since fixing it would change historical results project-wide.
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        depth, dscale = map_fn(dpipe, frame)

        ok, enc = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, args.jpeg_quality])
        if ok:
            pristine_frame_cache[frame_idx] = enc.tobytes()

        v5.draw_road_overlay(frame, road_mask)

        # --- v10 sign detection + tracking (agnostic NMS + IoU track + majority vote) ---
        sign_dets = []
        if custom_result.boxes is not None:
            for box, conf, cls_id in zip(
                custom_result.boxes.xyxy.cpu().numpy().astype(int),
                custom_result.boxes.conf.cpu().numpy(),
                custom_result.boxes.cls.cpu().numpy().astype(int),
            ):
                sign_dets.append((tuple(int(v) for v in box), CUSTOM_CLASS_NAMES[cls_id], float(conf)))
        active_sign_tracks = sign_tracker.update(frame_idx, sign_dets)

        boxes = car_result.boxes
        masks = car_result.masks
        clipped_boxes, mask_polygons, ids, confs, cls_ids = [], [], [], [], []
        other_moving_mask_bools = []
        if boxes is not None and len(boxes) > 0:
            xyxy = boxes.xyxy.cpu().numpy().astype(int)
            cls_all = boxes.cls.cpu().numpy().astype(int)
            ids_all = boxes.id.cpu().numpy().astype(int) if boxes.id is not None else [None] * len(xyxy)
            conf_all = boxes.conf.cpu().numpy()
            polygons_all = list(masks.xy) if masks is not None else [None] * len(xyxy)
            for (x1, y1, x2, y2), cls_id, tid, poly, conf in zip(xyxy, cls_all, ids_all, polygons_all, conf_all):
                if cls_id != v5.COCO_CAR_CLASS_ID:
                    other_moving_mask_bools.append(v5.rasterize_mask_polygon(poly, gray.shape))
                    # NEW: buses/trucks still get a depth reading (TARGET_VEHICLE_CLASSES), even
                    # though STOP_CLASS never applies to them (matches render_combined.py's scope).
                    if int(cls_id) in TARGET_VEHICLE_CLASSES:
                        mb = v5.rasterize_mask_polygon(poly, gray.shape)
                        if mb.sum() >= MIN_CAR_MASK_PX:
                            ds = cv2.resize(mb.astype(np.uint8), (depth.shape[1], depth.shape[0]),
                                            interpolation=cv2.INTER_NEAREST) > 0
                            # ByteTrack can leave a detection untracked in a given frame
                            # (boxes.id is None for it -> tid is None here, see ids_all
                            # above) -- nothing to key track_depth/track_boxes by then,
                            # but roi_occupancy is a per-pixel scene heatmap, not
                            # track-keyed, so it still accumulates regardless.
                            if tid is not None:
                                if ds.sum() >= 20:
                                    track_depth[int(tid)].append((frame_idx, float(np.median(depth[ds]))))
                                track_boxes[int(tid)].append((int(x1), int(y1), int(x2), int(y2)))
                            roi_occupancy[mb] += 1.0
                    continue
                box_w, box_h = x2 - x1, y2 - y1
                if box_h <= 0 or (box_w / box_h) > v5.MAX_CAR_ASPECT_RATIO:
                    continue
                clipped_boxes.append((max(0, x1), max(0, y1), min(width, x2), min(height, y2)))
                ids.append(tid)
                mask_polygons.append(poly)
                confs.append(float(conf))
                cls_ids.append(int(cls_id))

        car_mask_bools = [v5.rasterize_mask_polygon(p, gray.shape) for p in mask_polygons]
        all_cars_mask = np.zeros(gray.shape, dtype=bool)
        for cb in car_mask_bools:
            all_cars_mask |= cb
        all_moving_objects_mask = all_cars_mask.copy()
        for ob in other_moving_mask_bools:
            all_moving_objects_mask |= ob

        # --- depth sampling for COCO "car" tracks (the ones STOP_CLASS applies to) ---
        for (x1, y1, x2, y2), track_id, mask_bool in zip(clipped_boxes, ids, car_mask_bools):
            if track_id is None or mask_bool.sum() < MIN_CAR_MASK_PX:
                continue
            ds = cv2.resize(mask_bool.astype(np.uint8), (depth.shape[1], depth.shape[0]),
                            interpolation=cv2.INTER_NEAREST) > 0
            if ds.sum() >= 20:
                track_depth[int(track_id)].append((frame_idx, float(np.median(depth[ds]))))
            track_boxes[int(track_id)].append((int(x1), int(y1), int(x2), int(y2)))
            roi_occupancy[mask_bool] += 1.0

        # --- depth ego-rate reference: LK on background points (same pattern as render_combined.py) ---
        if prev_gray is not None:
            bgm = (~prev_any_mover).astype(np.uint8) * 255
            p0 = cv2.goodFeaturesToTrack(prev_gray, maxCorners=BG_MAX_CORNERS,
                                         qualityLevel=BG_QUALITY, minDistance=BG_MIN_DISTANCE, mask=bgm)
            if p0 is not None and len(p0) >= 20:
                p1, st, _ = cv2.calcOpticalFlowPyrLK(prev_gray, gray, p0, None, **LK_PARAMS)
                st = st.reshape(-1).astype(bool)
                a, b = p0.reshape(-1, 2)[st], p1.reshape(-1, 2)[st]
                if len(a) >= 20:
                    za = sample_depth(prev_depth, a, prev_scale)
                    zb = sample_depth(depth, b, dscale)
                    v = np.isfinite(za) & np.isfinite(zb) & (za > 0) & (zb > 0)
                    if v.sum() >= 20:
                        ego_dz[frame_idx] = float(np.median(zb[v] - za[v]))

        F, foe_result = None, None
        sigma_foe = None
        if prev_gray is not None:
            frames_with_flow += 1
            F = v5.estimate_fundamental_matrix(prev_gray, gray, all_cars_mask)
            if F is None:
                fundamental_failures += 1
            foe_result = estimate_foe_and_static_flow(prev_gray, gray, all_moving_objects_mask)
            if foe_result is not None:
                candidate_foe_point, _, _ = foe_result
                if prev_raw_foe_point is not None:
                    foe_jitter_history.append(float(np.hypot(*(np.array(candidate_foe_point) - prev_raw_foe_point))))
                prev_raw_foe_point = candidate_foe_point

                if last_accepted_foe_point is not None:
                    jump_px = float(np.hypot(*(np.array(candidate_foe_point) - last_accepted_foe_point)))
                    if jump_px > foe_max_jump_px and foe_jump_reject_streak < FOE_JUMP_REJECT_ESCAPE_VALVE:
                        foe_jump_reject_streak += 1
                        foe_jump_rejections += 1
                        foe_result = None
                    else:
                        foe_jump_reject_streak = 0
                        last_accepted_foe_point = candidate_foe_point
                else:
                    last_accepted_foe_point = candidate_foe_point
            if foe_result is None:
                foe_estimation_failures += 1

            sigma_foe = float(np.median(foe_jitter_history)) if len(foe_jitter_history) >= FOE_JITTER_WINDOW else None

        for i in range(len(clipped_boxes)):
            for j in range(i + 1, len(clipped_boxes)):
                tid_i, tid_j = ids[i], ids[j]
                if tid_i is None or tid_j is None or tid_i == tid_j:
                    continue
                if box_iou(clipped_boxes[i], clipped_boxes[j]) >= CROSS_TRACK_IOU_THRESHOLD:
                    pair_cooccurrence[frozenset((tid_i, tid_j))] += 1

        # ---- PASS 1 (per-car motion state, unchanged from v12) ----
        frame_records = []
        for (x1, y1, x2, y2), track_id, polygon, mask_bool, conf in zip(clipped_boxes, ids, mask_polygons, car_mask_bools, confs):
            if track_id is None:
                continue

            stats = track_stats[track_id]
            stats["frames_seen"] += 1
            if stats["first_frame"] is None:
                stats["first_frame"] = frame_idx
            stats["last_frame"] = frame_idx
            track_frame_boxes[track_id].append((frame_idx, (int(x1), int(y1), int(x2), int(y2))))
            track_conf_sum[track_id] += conf
            track_conf_n[track_id] += 1

            raw_ground_point = v5.mask_ground_point(mask_bool)
            if raw_ground_point is None:
                raw_ground_point = ((x1 + x2) / 2.0, float(y2))
            prev_gp_entry = ground_point_history.get(track_id)
            contiguous = prev_gp_entry is not None and prev_gp_entry[0] == frame_idx - 1
            ema_ground_point = v5.update_ema_point(prev_gp_entry[1] if contiguous else None, raw_ground_point, v5.GROUND_POINT_EMA_ALPHA)
            ground_point_history[track_id] = (frame_idx, ema_ground_point)

            car_mask_u8 = (mask_bool.astype(np.uint8)) * 255

            if F is not None and contiguous:
                residual = v5.car_epipolar_residual(F, prev_gray, gray, car_mask_u8)
                if residual is not None:
                    epi_history[track_id].append(residual)
                else:
                    epi_reading_failures += 1

            if foe_result is not None and contiguous:
                foe_point, static_mag, k_local = foe_result
                pts_flows = car_flow_points(prev_gray, gray, car_mask_u8)
                if pts_flows is not None:
                    pts, flows = pts_flows
                    p_foe = car_foe_probability(foe_point, static_mag, pts, flows, k_local=k_local)
                    if p_foe is not None:
                        median_dist_to_foe = float(np.median(np.linalg.norm(pts - np.array(foe_point), axis=1)))
                        confidence = None
                        if sigma_foe is not None and sigma_foe > 1e-6:
                            confidence = (median_dist_to_foe ** 2) / (median_dist_to_foe ** 2 + (CONFIDENCE_GATE_K * sigma_foe) ** 2)
                        if confidence is None or confidence >= CONFIDENCE_GATE_FLOOR:
                            foe_history[track_id].append(p_foe)
                            foe_gate_admissions += 1
                        else:
                            foe_gate_rejections += 1
                    else:
                        foe_reading_failures += 1

            epi_state[track_id] = classify_from_history(
                epi_history[track_id], epi_state[track_id],
                v5.RESIDUAL_ENTER_STATIONARY_PX, v5.RESIDUAL_EXIT_STATIONARY_PX, v5.MIN_HISTORY_FOR_CONFIDENCE,
            )
            foe_state[track_id] = classify_from_history(
                foe_history[track_id], foe_state[track_id],
                FOE_ENTER_STATIONARY, FOE_EXIT_STATIONARY, FOE_MIN_HISTORY_FOR_CONFIDENCE,
            )
            if epi_state[track_id] != "uncertain" or foe_state[track_id] != "uncertain":
                ever_confident[track_id] = True
            if epi_state[track_id] == "stationary" and foe_state[track_id] == "moving":
                disagreement_streak[track_id] += 1
            else:
                disagreement_streak[track_id] = 0
            stats["max_disagreement_streak"] = max(stats["max_disagreement_streak"], disagreement_streak[track_id])

            raw_combined = combine_states(epi_state[track_id], foe_state[track_id])
            prev_candidate_streak = stationary_candidate_streak[track_id]
            if disagreement_streak[track_id] >= dispute_frames:
                combined_committed[track_id] = "disputed"
                stationary_candidate_streak[track_id] = 0
            elif raw_combined == "moving":
                combined_committed[track_id] = "moving"
                stationary_candidate_streak[track_id] = 0
            elif raw_combined == "stationary":
                stationary_candidate_streak[track_id] += 1
                if stationary_candidate_streak[track_id] >= stationary_debounce_frames:
                    combined_committed[track_id] = "stationary"
            else:
                stationary_candidate_streak[track_id] = 0
            if raw_combined != "stationary" and 0 < prev_candidate_streak < stationary_debounce_frames:
                stats["stationary_candidacies_aborted"] += 1
            combined = combined_committed[track_id]

            if combined == "stationary":
                stationary_streak[track_id] += 1
                stats["frames_stationary"] += 1
            else:
                stationary_streak[track_id] = 0
                if combined == "uncertain":
                    stats["frames_uncertain"] += 1
                elif combined == "disputed":
                    stats["frames_disputed"] += 1
            if epi_state[track_id] == "stationary":
                stats["epi_frames_stationary"] += 1
            if foe_state[track_id] == "stationary":
                stats["foe_frames_stationary"] += 1

            flagged = stationary_streak[track_id] >= flag_after_frames
            if flagged:
                ever_flagged[track_id] = True

            if ever_flagged[track_id]:
                if combined == "moving":
                    post_flag_moving_streak[track_id] += 1
                    if post_flag_moving_streak[track_id] >= resumption_debounce_frames:
                        resumed_after_flagged[track_id] = True
                else:
                    post_flag_moving_streak[track_id] = 0

            ground_row = ema_ground_point[1]
            lane_position = v5.car_lane_position((x1, y1, x2, y2), mask_bool, road_mask)
            frame_records.append({
                "track_id": track_id, "box": (x1, y1, x2, y2), "polygon": polygon, "mask_bool": mask_bool,
                "ema_ground_point": ema_ground_point, "ground_row": ground_row, "lane_position": lane_position,
                "combined": combined, "flagged": flagged, "epi_state": epi_state[track_id], "foe_state": foe_state[track_id],
            })

        cars_for_scale = []
        for rec in frame_records:
            span = mask_max_width_span(rec["mask_bool"])
            if span is not None:
                cars_for_scale.append((span[0], span[1], rec["ground_row"]))

        zones = []
        for track in active_sign_tracks:
            if track.total_votes < SIGN_MIN_VOTES_TO_TRUST:
                x1, y1, x2, y2 = track.box
                cv2.rectangle(frame, (x1, y1), (x2, y2), (180, 180, 180), 1)
                continue
            color = CUSTOM_COLORS.get(track.resolved_class, (200, 200, 200))
            x1, y1, x2, y2 = track.box
            label = f"{track.resolved_class} [track#{track.id}, {track.total_votes}v]"
            if track.resolved_class in ("sign_P", "sign_S"):
                zone = sign_coverage_zone(track.box, road_mask, cars_for_scale, frame.shape)
                if zone is None:
                    zone_none_frames += 1
                else:
                    if zone["metric"]:
                        zone_metric_frames += 1
                    else:
                        zone_illustrative_frames += 1
                    zone_color = ZONE_COLORS.get(track.resolved_class, (200, 200, 200))
                    draw_zone_polygon(frame, zone, zone_color)
                    zones.append((track, zone))
                    reach_label = f"{zone['zone_length_m']:.0f}m (est.)" if zone["metric"] else "illustrative only"
                    label += f" zone~{reach_label}"
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            v5.place_label(frame, placed_label_rects, x1, max(12, y1 - 6), label, color)

        for rec in frame_records:
            track_id = rec["track_id"]
            x1, y1, x2, y2 = rec["box"]
            polygon, mask_bool = rec["polygon"], rec["mask_bool"]
            combined, flagged = rec["combined"], rec["flagged"]

            n_ratio = None
            if flagged:
                n_ratio = neighbor_stop_ratio(rec["ground_row"], track_id, frame_records)
                if n_ratio is not None:
                    neighbor_ratio_samples[track_id].append(n_ratio)

            gx, gy = rec["ema_ground_point"]
            in_zone_now = any(point_in_zone(gx, gy, zone) for _, zone in zones)
            if in_zone_now:
                frames_in_any_zone[track_id] += 1
                if flagged:
                    ever_flagged_in_zone[track_id] = True

            if flagged:
                color, status = (0, 0, 255), "STATIONARY (flagged)"
            elif combined == "stationary":
                color, status = (0, 140, 255), "stationary"
            elif combined == "disputed":
                color, status = (255, 0, 255), "DISPUTED (epi/foe disagree)"
            elif combined == "uncertain":
                color, status = (0, 255, 255), "uncertain"
            else:
                color, status = (0, 200, 0), "moving"

            draw_color = DISTURBANCE_COLOR if (flagged and in_zone_now) else color

            agree = rec["epi_state"] == rec["foe_state"]
            sub_color = color if agree else (0, 0, 255)
            short_status = {"STATIONARY (flagged)": "FLAGGED", "DISPUTED (epi/foe disagree)": "DISPUTED"}.get(status, status)
            label = f"#{track_id} {short_status}"

            if combined == "stationary":
                severity, _corrected_sides = encroachment_ratio_v7((x1, y1, x2, y2), mask_bool, road_mask)
                if severity is not None:
                    severity_samples[track_id].append(severity)
                    label += f" {severity*100:.0f}%blk"
                else:
                    no_road_data_count += 1
                    label += " no-road"
                lane_position = rec["lane_position"]
                if lane_position == "in_lane":
                    label += " lane"
                elif lane_position == "at_edge":
                    label += " curb"

            if flagged:
                if resumed_after_flagged[track_id] or (n_ratio is not None and n_ratio >= NEIGHBOR_RATIO_TRAFFIC_THRESHOLD):
                    label += " TRAFFIC"
                else:
                    label += " PARKED?"
                if n_ratio is not None:
                    label += f" nbr{n_ratio*100:.0f}%"
                if in_zone_now:
                    label += " IN-ZONE"

            detail = None
            if not agree:
                detail = f"epi:{rec['epi_state']} foe:{rec['foe_state']}"

            car_draw_by_frame[frame_idx].append({
                "track_id": track_id, "box": (x1, y1, x2, y2), "polygon": polygon,
                "draw_color": draw_color, "label": label, "detail": detail, "sub_color": sub_color,
                "ground_point": (int(gx), int(gy)),
            })

        timestamp_s = native_frame_number[frame_idx] / fps
        cv2.putText(frame, f"t={timestamp_s:5.1f}s  frame {frame_idx}/{total_frames_expected}", (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(frame, f"t={timestamp_s:5.1f}s  frame {frame_idx}/{total_frames_expected}", (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1, cv2.LINE_AA)
        draw_legend(frame)

        ok, enc = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, args.jpeg_quality])
        if ok:
            frame_cache[frame_idx] = enc.tobytes()

        prev_gray, prev_depth, prev_scale, prev_any_mover = gray, depth, dscale, all_moving_objects_mask
        frame_idx += 1
        if frame_idx % 50 == 0 or frame_idx == total_frames_expected:
            print(f"  processed {frame_idx}/{total_frames_expected} frames", file=sys.stderr)

    cap.release()
    sign_tracker.finalize_all()

    duplicate_of = {}
    for pair, n_overlap in pair_cooccurrence.items():
        tid_a, tid_b = tuple(pair)
        n_a, n_b = track_stats[tid_a]["frames_seen"], track_stats[tid_b]["frames_seen"]
        shorter, longer = (tid_a, tid_b) if n_a <= n_b else (tid_b, tid_a)
        if n_overlap / track_stats[shorter]["frames_seen"] >= CROSS_TRACK_DEDUP_FRAME_FRAC:
            duplicate_of[shorter] = longer
    excluded_ids = {tid for tid in track_stats if not ever_confident[tid]} | set(duplicate_of.keys())

    if duplicate_of:
        print(f"\nCross-track IoU dedup: {len(duplicate_of)} track(s) merged as duplicate IDs:", file=sys.stderr)
        for shorter, longer in duplicate_of.items():
            print(f"  car#{shorter} -> merged into car#{longer}", file=sys.stderr)
    print(f"\n{len(excluded_ids)} track(s) excluded from rendering ("
          f"{sum(1 for tid in track_stats if not ever_confident[tid])} never confident, "
          f"{len(duplicate_of)} duplicate IDs, may overlap)", file=sys.stderr)

    # ---- depth aggregate, same function render_depth_video.py/render_combined.py use ----
    static_roi = (roi_occupancy / max(frame_idx, 1)) >= ROI_OCCUPANCY_THRESHOLD
    depth_stats = aggregate(track_depth, ego_dz, track_boxes, height, width, static_roi)
    print(f"\ndepth backend: {args.depth_backend}  ({len(depth_stats)} track(s) measured, "
          f"static ROI covers {int(static_roi.sum())} px)", file=sys.stderr)

    # effective_fps (not native fps): at stride>1 there are fewer output frames than the source
    # had, so writing at native fps would play the annotated video back in 1/stride the real
    # duration -- effective_fps keeps its wall-clock length matched to the source clip instead.
    writer = cv2.VideoWriter(args.output, cv2.VideoWriter_fourcc(*"mp4v"), effective_fps, (width, height))
    for f_idx in range(frame_idx):
        raw = frame_cache.get(f_idx)
        if raw is None:
            continue
        img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        placed_label_rects = []
        for d in car_draw_by_frame.get(f_idx, []):
            if d["track_id"] in excluded_ids:
                continue
            x1, y1, x2, y2 = d["box"]
            polygon = d["polygon"]
            if polygon is not None and len(polygon) > 0:
                cv2.polylines(img, [polygon.astype(np.int32)], isClosed=True, color=d["draw_color"], thickness=2)
            else:
                cv2.rectangle(img, (x1, y1), (x2, y2), d["draw_color"], 2)
            cv2.circle(img, d["ground_point"], 4, d["draw_color"], -1)
            v5.place_label(img, placed_label_rects, x1, max(12, y1 - 6), d["label"], d["draw_color"], font_scale=0.48, thickness=2)
            if d["detail"]:
                v5.place_label(img, placed_label_rects, x1, max(12, y1 - 6) + 16, d["detail"], d["sub_color"], font_scale=0.4, thickness=1)
        writer.write(img)
    writer.release()
    print(f"\nWrote annotated video to {args.output}")

    print(f"\n{len(sign_tracker.finalized)} sign/crosswalk track(s):")
    for t in sorted(sign_tracker.finalized, key=lambda t: t.first_frame):
        span_s = f"{native_frame_number[t.first_frame]/fps:.1f}s-{native_frame_number[t.last_frame]/fps:.1f}s"
        trusted = "CONFIRMED" if t.total_votes >= SIGN_MIN_VOTES_TO_TRUST else "low-confidence/noise"
        print(f"  track#{t.id}: {span_s} ({t.last_frame-t.first_frame+1} frames seen), "
              f"votes={dict(t.votes)}, resolved={t.resolved_class} [{trusted}]")
    print(f"\nCoverage-zone geometry: {zone_metric_frames} sign-frames used a nearby car for metric "
          f"scale, {zone_illustrative_frames} fell back to illustrative-only (no reference car), "
          f"{zone_none_frames} had no usable road data near the sign at all")

    n_shown = len(track_stats) - len(excluded_ids)
    print(f"\n{len(track_stats)} distinct car track(s) detected ({n_shown} shown after exclusions):")
    n_disturbances = 0
    demo_candidates = []  # NEW: (track_id, stop_class, in_zone, depth_txt) for the screenshot generator
    candidate_frame_box = {}  # track_id -> box at the chosen (middle) frame, for write_screenshots
    for track_id, stats in sorted(track_stats.items()):
        if track_id in excluded_ids:
            continue
        first_s = native_frame_number[stats["first_frame"]] / fps
        last_s = native_frame_number[stats["last_frame"]] / fps
        n = stats["frames_seen"]
        pct_stationary = 100 * stats["frames_stationary"] / n if n else 0
        sev = severity_samples.get(track_id)
        sev_str = f", mean severity {np.mean(sev)*100:.0f}% blocked (n={len(sev)})" if sev else ""

        stop_class_str = ""
        stop_class = None
        depth_txt = "no reading"
        if ever_flagged[track_id]:
            n_samples = neighbor_ratio_samples.get(track_id)
            mean_n_ratio = np.mean(n_samples) if n_samples else None
            min_stationary_frames_for_parked = flag_after_frames + int(round(MIN_EXTRA_STATIONARY_SECONDS_FOR_PARKED * effective_fps))
            observed_long_enough = stats["frames_stationary"] >= min_stationary_frames_for_parked

            ds = depth_stats.get(track_id)
            if ds is not None and not ds["ego_body"]:
                depth_txt, _ = depth_classify(ds["ratio"], ds["unstable"])

            if resumed_after_flagged[track_id]:
                stop_class = "TRAFFIC_STOPPED (resumed)"
            elif mean_n_ratio is not None and mean_n_ratio >= NEIGHBOR_RATIO_TRAFFIC_THRESHOLD:
                stop_class = f"TRAFFIC_STOPPED (neighbor sync {mean_n_ratio*100:.0f}%)"
            elif observed_long_enough:
                stop_class = "PARKED"
            elif ds is not None and not ds["ego_body"] and not ds["unstable"]:
                # ---- Option B tiebreaker: ONLY reachable when everything above gave up ----
                r = ds["ratio"]
                if DEPTH_BAND_STOPPED_LO <= r <= DEPTH_BAND_STOPPED_HI:
                    stop_class = "PARKED (depth tiebreak)"
                elif r < DEPTH_BAND_CONVOY_MAX or r > DEPTH_BAND_STOPPED_HI:
                    stop_class = "MOVING (depth tiebreak)"
                else:
                    stop_class = "UNRESOLVED"
            else:
                stop_class = "UNRESOLVED"
            nratio_str = f", mean neighbor-stop-ratio {mean_n_ratio*100:.0f}% (n={len(n_samples)})" if n_samples else ", no neighbor data"
            stop_class_str = f", STOP_CLASS={stop_class}{nratio_str}, depth={depth_txt}"

        zone_n = frames_in_any_zone.get(track_id, 0)
        zone_str = f", in a sign zone {zone_n}/{n} frames ({100*zone_n/n:.0f}%)" if zone_n else ""

        disturbance_str = ""
        is_parked = bool(stop_class) and stop_class.startswith("PARKED")
        if is_parked and ever_flagged_in_zone[track_id]:
            n_disturbances += 1
            disturbance_str = " *** DISTURBANCE: parked inside a no-parking sign's zone ***"
        if is_parked:
            # MIDDLE of the track's observed span (farthest-to-nearest), not the farthest frame --
            # the project owner's revised choice. `track_frame_boxes` isn't guaranteed contiguous
            # (a track can flicker in and out), so this picks whichever recorded frame lands
            # closest to the midpoint rather than assuming that exact frame_idx was seen.
            target_frame = (stats["first_frame"] + stats["last_frame"]) // 2
            mid_frame_idx, mid_box = min(
                track_frame_boxes[track_id], key=lambda fb: abs(fb[0] - target_frame)
            )
            candidate_frame_box[track_id] = mid_box
            # mid_frame_idx itself stays processed-space (it indexes frame_cache/pristine_frame_cache,
            # both keyed by processed frame_idx) -- only the seconds value needs the true native time.
            demo_candidates.append((track_id, stop_class, ever_flagged_in_zone[track_id], depth_txt,
                                    mid_frame_idx, native_frame_number[mid_frame_idx] / fps))

        print(
            f"  car#{track_id}: seen {n} frames ({first_s:.1f}s - {last_s:.1f}s), "
            f"{pct_stationary:.0f}% stationary{sev_str}{stop_class_str}{zone_str}{disturbance_str}"
        )

    print(f"\n{n_disturbances} DISTURBANCE(s): car(s) classified PARKED (not traffic-stopped, not "
          f"unresolved) with ground-contact point inside a sign's coverage zone while flagged stationary.")

    print(f"\nBackground fundamental matrix: failed on {fundamental_failures}/{frames_with_flow} frames")
    print(f"Background FoE estimation: failed on {foe_estimation_failures}/{frames_with_flow} frames")
    print(f"Phase 3A: {no_road_data_count} stationary-car frames had no drivable-area pixels at the car's ground row")

    # ---- NEW: demo screenshots -- one per PARKED car, at the MIDDLE frame of its observed span
    #      (farthest-to-nearest), full frame with box + final label, so the still image is
    #      self-explanatory on its own ----
    if demo_candidates:
        from demo_screenshots import write_screenshots
        write_screenshots(args.input, args.output, frame_cache, pristine_frame_cache, candidate_frame_box,
                          demo_candidates, out_dir=args.screenshot_dir)


if __name__ == "__main__":
    main()
