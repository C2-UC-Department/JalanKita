"""
v5 demo scanner. Replaces v2/v3's single-homography ego-motion model with an EPIPOLAR
(fundamental-matrix) model, evaluated as a whole-mask CONSENSUS across many of a car's own
tracked points instead of a single ground-contact point. Full rationale, the research behind
it, and the empirical tests that motivated it: `../METHODS_TRIED.md` (methods #8-10, the
road-masked-homography and metric/IPM attempts that motivated moving off homography entirely)
and `SESSION_LOG_V5.md` for this version's own build/verification record.

Three models run per frame, side by side:
- `car`: YOLOv8n-seg (unchanged from v3), COCO-pretrained, ByteTrack for tracking. The mask is
  used for THREE things now, not one: (1) the ego-motion background-feature exclusion mask,
  (2) the car's own tracked-point set for the epipolar consensus check, (3) the ground-contact
  point and width for Phase 3A -- see below for each.
- `crosswalk`/`sign_P`/`sign_S`: the v1 fine-tuned YOLOv8n (test mAP50=0.928), unchanged.
- `road`: YOLOP drivable-area branch, unchanged from v2/v3.

WHY MOVE OFF HOMOGRAPHY (see METHODS_TRIED.md #8-10 for the full empirical trail): v2/v3's
ego-motion model assumed the tracked background features all lie on one flat plane (a
homography is only EXACT for points on the plane that induced it). Three attempts to fix the
resulting near-field false-positive problem by choosing a BETTER plane -- road-mask-restricted
globally, then restricted to a local window right around the car -- produced virtually
IDENTICAL failure curves each time. That ruled out "which plane" as the actual lever. A fourth
attempt converted the residual to real-world meters (inverse perspective mapping) to remove
the near/far pixel-density imbalance directly -- it worked in the near field but made the far
field WORSE (undefined for a car#288-equivalent car's first ~2 seconds of tracking), because
the back-projection is mathematically hyperbolic near the horizon: ordinary pixel noise there
produces unbounded swings in the estimated real-world position, regardless of how accurate the
horizon estimate is.

THE ACTUAL CHANGE IN v5, two parts:

1. FUNDAMENTAL MATRIX INSTEAD OF HOMOGRAPHY. `estimate_fundamental_matrix()` fits
   `cv2.findFundamentalMat(..., cv2.FM_RANSAC)` from the same masked-background sparse
   features v2/v3 already used for `findHomography`. The fundamental matrix constrains any
   STATIC 3D point, at ANY depth, to lie on its predicted epipolar line in the next frame --
   it makes no planarity assumption at all. This is the direct fix for the actual, confirmed
   root cause in METHODS_TRIED.md #8/#9 (the plane choice was never the problem, and this
   removes the plane assumption entirely rather than trying to choose a better one).

2. WHOLE-MASK CONSENSUS INSTEAD OF A SINGLE POINT. Rather than tracking one ground-contact
   point and computing one residual, `car_epipolar_residual()` runs `goodFeaturesToTrack`
   *inside* the car's own segmentation mask (using the mask, not the box, so a car near a curb
   doesn't pick up genuinely-static road/sidewalk points sitting inside its box), tracks all of
   them with the same Lucas-Kanade pipeline, and computes each tracked point's perpendicular
   distance to its predicted epipolar line. The car's residual for that frame is the MEDIAN of
   those distances (across dozens to a hundred-plus points, not one). This directly targets the
   other structural problem every prior method had: a single point's measurement noise (mask-
   boundary jitter, LK tracking imprecision) was being amplified, not averaged out. Points with
   the highest 30% LK tracking error are dropped before the median is taken -- car body surfaces
   (reflections, specular highlights) track less reliably under Lucas-Kanade's brightness-
   constancy assumption than textured road/building surfaces do, and this was directly observed
   in testing (raw per-frame values still spike even after this filtering; the signal that
   holds up is the smoothed trend, not any single frame).

VERIFIED BEFORE BUILDING THIS FILE, not assumed: tested directly against a known near-field
false-positive car and a known far-field oncoming car (see METHODS_TRIED.md and
SESSION_LOG_V5.md for exact numbers). The parked car's smoothed residual stayed mostly under
~1.6px even close up; the oncoming car's climbed to a sustained 2-8px once genuinely closing
distance. That's real trend separation -- better than the single-homography residual, the
scale-normalized version, the direction/expansion signals, or the metric/IPM conversion ever
achieved -- but it is NOT clean frame-to-frame; the hysteresis below exists specifically to
extract a stable decision from a noisy-but-separable trend, not because the signal is tidy.

GROUND-CONTACT POINT AND WIDTH FOR PHASE 3A: kept from v3 (mask bottom row, EMA-smoothed) for
the point; car width at that row is now ALSO read from the mask (leftmost/rightmost car-mask
pixel at the ground-contact row), not the box edges, for the same reason the ground point
moved off the box in v3 -- consistent with actually using segmentation throughout, not just
for motion classification.
"""

import argparse
import sys
from collections import defaultdict, deque

import cv2
import numpy as np

from car_points import car_point_correspondences
import torch
import torchvision.transforms as T
from ultralytics import YOLO

COCO_CAR_CLASS_ID = 2

# Reject "car" detections wider than this multiple of their own height. No real car, at any
# distance or viewing angle, presents this shape -- but a dashcam's own hood/dashboard sitting
# at a fixed position at the bottom of the frame does (confirmed on the 0a8a... test video: a
# near-full-frame-width, ~240px-tall box, continuously misdetected as a car for hundreds of
# frames straight). This is a shape check, not a position check, so it generalizes across
# different dashcam mounts without needing a per-video pixel-region crop.
MAX_CAR_ASPECT_RATIO = 3.0

CUSTOM_CLASS_NAMES = ["crosswalk", "sign_P", "sign_S"]
CUSTOM_COLORS = {"crosswalk": (255, 200, 0), "sign_P": (0, 165, 255), "sign_S": (0, 0, 255)}
CUSTOM_CONF_THRESHOLD = 0.25

FLAG_AFTER_SECONDS = 1.0

YOLOP_IMG_SIZE = 640
YOLOP_MEAN = [0.485, 0.456, 0.406]
YOLOP_STD = [0.229, 0.224, 0.225]
YOLOP_PAD_COLOR = (114, 114, 114)

# Background fundamental-matrix estimation (replaces v2/v3's homography -- see module
# docstring for why: no planarity assumption, directly targeting the confirmed root cause).
FUNDAMENTAL_MAX_FEATURES = 300
FUNDAMENTAL_MIN_MATCHES = 20       # below this many correspondences, don't trust the fit
FUNDAMENTAL_RANSAC_THRESHOLD_PX = 2.0
FUNDAMENTAL_RANSAC_CONFIDENCE = 0.99

# Per-car whole-mask consensus: how many of the car's own points to try to track, and how
# aggressively to drop the least-reliable ones (see module docstring -- car body surfaces,
# especially reflections/specular highlights, track less reliably under Lucas-Kanade than
# textured road/building surfaces do; dropping the noisiest tracks before aggregating reduces,
# but does not eliminate, that noise).
CAR_POINT_MAX_FEATURES = 150
CAR_POINT_MIN_TRACKED = 4          # below this many surviving tracked points, no reading this frame
CAR_POINT_KEEP_FRACTION = 0.7      # keep the best 70% of tracks by LK error, drop the noisiest 30%

# Residual smoothing + hysteresis. RAW PIXELS this time, not scale-normalized -- unlike the
# homography residual, the epipolar-line distance for a genuinely static point does not have a
# structural near/far bias (it isn't derived from a flat-plane approximation whose error grows
# with proximity); what noise remains is from LK tracking imprecision and RANSAC fit noise, not
# distance-dependent geometry. Values below are placeholders reasoned from direct empirical
# testing against one known-parked and one known-oncoming car (see SESSION_LOG_V5.md for the
# exact traces) -- NOT tuned against a labeled ground-truth set, same honesty caveat as every
# threshold in this project. The smoothed value stayed mostly under ~1.6px for the parked car
# even close up, and reached a sustained 2-8px for the oncoming car once genuinely closing
# distance; thresholds are set between those two observed bands, not at their exact edges,
# since only two cases have been checked.
RESIDUAL_SMOOTHING_WINDOW = 9
RESIDUAL_ENTER_STATIONARY_PX = 1.0
RESIDUAL_EXIT_STATIONARY_PX = 2.5
MIN_HISTORY_FOR_CONFIDENCE = 3     # frames of residual history before leaving "uncertain"

GROUND_POINT_EMA_ALPHA = 0.5       # ~3-frame effective smoothing window on the mask-derived
                                    # ground-contact point, per Gemini's suggested 3-5 frames


def estimate_fundamental_matrix(prev_gray, curr_gray, exclude_mask):
    """RANSAC-fit fundamental matrix from masked-background sparse features -- the direct
    replacement for v2/v3's `estimate_ego_motion_homography`. Unlike a homography, F makes no
    assumption that the background features lie on one flat plane: it constrains any STATIC
    point, at any depth, to lie on its predicted epipolar line in the next frame. `exclude_mask`
    is now a per-pixel boolean mask (car segmentation, not boxes) -- see module docstring for
    why using masks here (not boxes) recovers a few more usable background points near each car's
    edges. Returns None (not a guess) if there aren't enough reliably-tracked correspondences."""
    h, w = prev_gray.shape[:2]
    mask = np.where(exclude_mask, 0, 255).astype(np.uint8)

    prev_pts = cv2.goodFeaturesToTrack(prev_gray, maxCorners=FUNDAMENTAL_MAX_FEATURES, qualityLevel=0.01, minDistance=10, mask=mask)
    if prev_pts is None or len(prev_pts) < FUNDAMENTAL_MIN_MATCHES:
        return None

    curr_pts, status, _ = cv2.calcOpticalFlowPyrLK(prev_gray, curr_gray, prev_pts, None)
    status = status.reshape(-1).astype(bool)
    prev_pts, curr_pts = prev_pts[status], curr_pts[status]
    if len(prev_pts) < FUNDAMENTAL_MIN_MATCHES:
        return None

    F, _inliers = cv2.findFundamentalMat(prev_pts, curr_pts, cv2.FM_RANSAC, FUNDAMENTAL_RANSAC_THRESHOLD_PX, FUNDAMENTAL_RANSAC_CONFIDENCE)
    return F


def epipolar_residual_from_correspondences(F, p1, p2):
    """Post-step half of car_epipolar_residual, split out so pipeline_v13.py can share one
    car_point_correspondences() call between the epi and FoE branches (EFFICIENCY_PLAN.md S2).
    Computes each point's perpendicular distance to the epipolar line F predicts for it and
    returns the median distance across all points."""
    lines2 = cv2.computeCorrespondEpilines(p1.reshape(-1, 1, 2), 1, F).reshape(-1, 3)
    a, b, c = lines2[:, 0], lines2[:, 1], lines2[:, 2]
    dist = np.abs(a * p2[:, 0] + b * p2[:, 1] + c) / np.sqrt(a * a + b * b)
    return float(np.median(dist))


def car_epipolar_residual(F, prev_gray, curr_gray, car_mask_u8):
    """Whole-mask consensus residual for one car: tracks up to CAR_POINT_MAX_FEATURES points
    found INSIDE the car's own segmentation mask (not its box) from prev_gray to curr_gray,
    computes each surviving tracked point's perpendicular distance to the epipolar line F
    predicts for it, drops the noisiest CAR_POINT_KEEP_FRACTION by LK tracking error, and
    returns the median distance across what's left. Small = this car's own points move exactly
    the way a static point at their location should, given the background's fitted motion --
    consistent with the car being world-stationary. Large = the car's points are NOT explained
    by the background's motion -- real, independent motion. Returns None if too few points were
    found or survived tracking to trust a reading this frame (not a guess)."""
    corr = car_point_correspondences(prev_gray, curr_gray, car_mask_u8)
    if corr is None:
        return None
    return epipolar_residual_from_correspondences(F, corr[0], corr[1])


def mask_ground_point(mask_bool):
    """Bottom-row center of a car's segmentation mask: the lowest set of pixels in the mask,
    averaged in x. More stable than a bounding box's bottom edge, which is whichever pixel is
    lowest across the WHOLE BOX -- can be a shadow, a neighboring car's mirror poking in, or
    box jitter unrelated to the vehicle's own outline. Returns None if the mask is empty."""
    ys, xs = np.where(mask_bool)
    if ys.size == 0:
        return None
    max_y = ys.max()
    xs_at_max_y = xs[ys == max_y]
    return (float(xs_at_max_y.mean()), float(max_y))


def rasterize_mask_polygon(polygon_xy, shape_hw):
    """Fills a car's segmentation polygon (already in original-image pixel coordinates, as
    Ultralytics' `masks.xy` returns) into a boolean raster the same size as the frame."""
    mask = np.zeros(shape_hw, dtype=np.uint8)
    if polygon_xy is None or len(polygon_xy) == 0:
        return mask.astype(bool)
    pts = polygon_xy.astype(np.int32).reshape((-1, 1, 2))
    cv2.fillPoly(mask, [pts], 1)
    return mask.astype(bool)


def update_ema_point(prev_point, raw_point, alpha):
    if prev_point is None:
        return raw_point
    return (alpha * raw_point[0] + (1 - alpha) * prev_point[0], alpha * raw_point[1] + (1 - alpha) * prev_point[1])


def letterbox_for_img(img, new_shape=640, color=YOLOP_PAD_COLOR):
    """Copied from hustvl/YOLOP lib/utils/augmentations.py letterbox_for_img, to match
    their exact preprocessing (auto=True, scaleup=True defaults) for the pretrained weights."""
    shape = img.shape[:2]
    if isinstance(new_shape, int):
        new_shape = (new_shape, new_shape)
    r = min(new_shape[0] / shape[0], new_shape[1] / shape[1])
    new_unpad = int(round(shape[1] * r)), int(round(shape[0] * r))
    dw, dh = new_shape[1] - new_unpad[0], new_shape[0] - new_unpad[1]
    dw, dh = np.mod(dw, 32), np.mod(dh, 32)
    dw /= 2
    dh /= 2
    if shape[::-1] != new_unpad:
        img = cv2.resize(img, new_unpad, interpolation=cv2.INTER_AREA)
    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    img = cv2.copyMakeBorder(img, top, bottom, left, right, cv2.BORDER_CONSTANT, value=color)
    return img, r, (dw, dh)


class RoadSegmenter:
    """Wraps YOLOP, exposing only the drivable-area branch as a per-frame binary mask."""

    def __init__(self, device):
        self.device = device
        self.model = torch.hub.load("hustvl/YOLOP", "yolop", pretrained=True, trust_repo=True)
        self.model.eval()
        self.model.to(device)
        self.transform = T.Compose([T.ToTensor(), T.Normalize(mean=YOLOP_MEAN, std=YOLOP_STD)])

    def drivable_mask(self, frame_bgr):
        h0, w0 = frame_bgr.shape[:2]
        img, ratio, (dw, dh) = letterbox_for_img(frame_bgr, YOLOP_IMG_SIZE)
        tensor = self.transform(img).unsqueeze(0).to(self.device)
        with torch.no_grad():
            _, da_seg_out, _ = self.model(tensor)
        dh_i, dw_i = int(round(dh)), int(round(dw))
        h_pad, w_pad = da_seg_out.shape[2], da_seg_out.shape[3]
        cropped = da_seg_out[:, :, dh_i : h_pad - dh_i, dw_i : w_pad - dw_i]
        resized = torch.nn.functional.interpolate(cropped, size=(h0, w0), mode="bilinear", align_corners=False)
        mask = torch.argmax(resized, dim=1).squeeze(0).cpu().numpy().astype(np.uint8)
        return mask  # (h0, w0); 1 = drivable area, 0 = not


def mask_span_at_row(mask_bool, row):
    """Leftmost/rightmost True-pixel column at a given row of a boolean mask. Used for both
    the road mask (drivable-area width) and, new in v5, the car's own segmentation mask
    (actual car width at its ground-contact row, instead of the box's x1/x2 -- consistent with
    using segmentation throughout rather than falling back to box edges for this one number)."""
    row = min(max(row, 0), mask_bool.shape[0] - 1)
    cols = np.where(mask_bool[row])[0]
    if len(cols) == 0:
        return None
    return int(cols.min()), int(cols.max())


def phase3a_severity(car_box, car_mask_bool, road_mask):
    """DISTURBANCE_SCORING_MODEL.md section 3: same-row car-width / road-width ratio. Car
    width now comes from the car's own segmentation mask at its ground-contact row when
    available, falling back to the box's x1/x2 if the mask has no pixels there. Returns None
    if the road mask has no drivable pixels at that row (rather than fabricating a number)."""
    x1, y1, x2, y2 = car_box
    ground_row = y2 - 1
    road_span = mask_span_at_row(road_mask == 1, ground_row)
    if road_span is None:
        return None
    road_left, road_right = road_span
    road_width_px = road_right - road_left
    if road_width_px <= 0:
        return None
    car_span = mask_span_at_row(car_mask_bool, ground_row)
    car_width_px = (car_span[1] - car_span[0]) if car_span is not None else (x2 - x1)
    return min(1.0, car_width_px / road_width_px)


def encroachment_ratio(car_box, car_mask_bool, road_mask):
    """v7: supersedes phase3a_severity as the shipped "% blocked" number (see
    v7/SESSION_LOG_V7.md for the full investigation). phase3a_severity divides the car's width by
    the road's width at the same row WITHOUT checking whether the two spans actually occupy the
    same horizontal range -- a car parked entirely beside the drivable strip (curb/shoulder, not
    on it) can still produce a large ratio purely from dividing two unrelated widths. Confirmed on
    two independent real cases (a curb-parked SUV reading "52% blocked" while its own span
    (1363-1918) doesn't overlap the road span (626-1300) AT ALL, and a row of curb-parked cars on
    a tree-lined street reading 2-68% "blocked" while sitting in what is clearly a dedicated
    parking strip beside the traffic lane) that this is the dominant cause of the "at curb" cars
    reading high severity, not a segmentation/occlusion bug.

    This asks a more literal question: of the car's OWN ground-row footprint, what fraction
    actually falls within the drivable span at that row. 0 = the car doesn't reach the drivable
    strip at all; 1 = its entire footprint sits inside it. A first version tried intersecting the
    car's full 2D mask with the road mask directly and was FALSIFIED before shipping: a car
    occludes the pavement it stands on by definition, so full-mask overlap reads ~0 for every car
    regardless of whether it's blocking traffic -- reintroducing the exact occlusion problem this
    metric exists to route around. Reusing the same 1D ground-row spans phase3a_severity already
    computes (interval overlap, not area overlap) avoids that failure mode. Verified more
    temporally stable than phase3a_severity on the confirmed SUV case (rock-steady 0.000 across
    ~30 consecutive frames vs. phase3a_severity swinging 0.003-0.454 with a lone spike to 0.742),
    with one confirmed minor exception: a brief ~4-frame mask-edge blip (~0.23-0.30) as the ego
    vehicle closed to very short range -- present but small, not addressed with smoothing here
    since it's already an improvement over what phase3a_severity's jitter shipped with."""
    x1, y1, x2, y2 = car_box
    ground_row = y2 - 1
    road_span = mask_span_at_row(road_mask == 1, ground_row)
    if road_span is None:
        return None
    road_left, road_right = road_span
    car_span = mask_span_at_row(car_mask_bool, ground_row)
    car_left, car_right = car_span if car_span is not None else (x1, x2)
    car_width_px = car_right - car_left
    if car_width_px <= 0:
        return None
    overlap_left = max(car_left, road_left)
    overlap_right = min(car_right, road_right)
    overlap_width = max(0, overlap_right - overlap_left)
    return overlap_width / car_width_px


# How close (as a fraction of road width at the car's ground row) a stopped car's center needs
# to be to the road mask's edge before it's read as curb/shoulder-parked rather than sitting in
# a driving lane. A heuristic, reasoned the same way as every other threshold in this project --
# not tuned against a labeled ground-truth set of confirmed-blocking vs confirmed-parked cars.
LANE_EDGE_FRACTION_THRESHOLD = 0.2


def car_lane_position(car_box, car_mask_bool, road_mask):
    """Answers a DIFFERENT question than phase3a_severity: not "how much of the road width does
    this car cover" but "is it sitting centrally in a lane (likely blocking through-traffic) or
    tucked against the road's edge (likely curb-parked)". Compares the car's horizontal center
    at its ground-contact row to the road mask's left/right edges at that same row. Returns
    "in_lane", "at_edge", or None if there's no road data at that row. This does NOT detect
    whether a car is genuinely moving vs stationary -- a car driving normally in a lane at your
    own speed (see METHODS_TRIED.md / SESSION_LOG_V5.md convoy-ambiguity discussion) will read
    "in_lane" too, correctly, even though it isn't actually blocking anything; this only adds
    the parked-vs-blocking distinction for cars the motion classifier has already decided are
    stationary."""
    x1, y1, x2, y2 = car_box
    ground_row = y2 - 1
    road_span = mask_span_at_row(road_mask == 1, ground_row)
    if road_span is None:
        return None
    road_left, road_right = road_span
    road_width_px = road_right - road_left
    if road_width_px <= 0:
        return None
    car_span = mask_span_at_row(car_mask_bool, ground_row)
    car_center_x = (car_span[0] + car_span[1]) / 2.0 if car_span is not None else (x1 + x2) / 2.0
    distance_to_nearest_edge = max(0.0, min(car_center_x - road_left, road_right - car_center_x))
    edge_fraction = distance_to_nearest_edge / road_width_px
    return "at_edge" if edge_fraction < LANE_EDGE_FRACTION_THRESHOLD else "in_lane"


def draw_road_overlay(frame, mask):
    overlay = frame.copy()
    overlay[mask == 1] = (0, 180, 0)
    cv2.addWeighted(overlay, 0.15, frame, 0.85, 0, dst=frame)


def draw_legend(frame):
    lines = [
        "car: YOLOv8n-seg + ByteTrack + epipolar (fundamental-matrix) whole-mask consensus",
        "outline = actual segmentation mask; dot = EMA'd ground-contact point (mask bottom row)",
        "yellow box = not enough temporal history yet (just-appeared track), not a disagreement",
        "crosswalk/sign_P/sign_S: fine-tuned YOLOv8n (test mAP50=0.93, clean-photo domain)",
        "road (green tint): YOLOP drivable-area -- Phase 3A severity = car-width/road-width at ground row",
        "IN LANE/at curb: car's position vs road edges at ground row, NOT a moving/stationary check",
        "read as illustrative only -- see SESSION_LOG_V5.md for known failure modes",
    ]
    y = frame.shape[0] - 15 - (len(lines) - 1) * 18
    for line in lines:
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (255, 255, 255), 1, cv2.LINE_AA)
        y += 18


def place_label(frame, placed_rects, x, y_top_preferred, text, color, font_scale=0.55, thickness=2):
    """Greedy label placement: if the preferred spot overlaps an already-placed label in
    this frame, push it down in fixed steps until clear. Fixes real label-on-label overlap
    observed when 3+ cars cluster close together in frame (see SESSION_LOG_V2.md)."""
    (tw, th), baseline = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, font_scale, thickness)
    y = y_top_preferred
    # 8 retries was enough for v5/v6's short single-line labels but not v8's denser per-car
    # stacks (main + optional detail line) once 3+ stationary cars cluster in the same column
    # (a curbside row) -- raised so a crowded frame still resolves instead of silently giving up
    # partway and leaving later labels overlapping.
    for _ in range(40):
        rect = (x, y - th - baseline, x + tw, y + baseline)
        if not any(_rects_overlap(rect, r) for r in placed_rects):
            break
        y += th + baseline + 4
    placed_rects.append((x, y - th - baseline, x + tw, y + baseline))
    cv2.putText(frame, text, (x, y), cv2.FONT_HERSHEY_SIMPLEX, font_scale, color, thickness, cv2.LINE_AA)


def _rects_overlap(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    return ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2


def main():
    parser = argparse.ArgumentParser(description="v5 demo: epipolar (fundamental-matrix) whole-mask consensus motion classification.")
    parser.add_argument("--input", default="../0b21d2708d72b821bec4c81a42d46e92.mp4")
    parser.add_argument("--output", default="demo_scan_output_v5.mp4")
    parser.add_argument("--model", default="yolov8n-seg.pt")
    parser.add_argument("--custom-model", default="../v1/runs/detect/runs/signs_crosswalk_v1/weights/best.pt")
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()

    car_model = YOLO(args.model)
    custom_model = YOLO(args.custom_model)
    road_segmenter = RoadSegmenter(torch.device(args.device))

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        sys.exit(f"Could not open {args.input}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    flag_after_frames = max(1, int(round(FLAG_AFTER_SECONDS * fps)))

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(args.output, fourcc, fps, (width, height))

    prev_gray = None
    ground_point_history = {}  # track_id -> (frame_idx, (gx, gy)) EMA'd ground point, from the previous sighting
    residual_history = defaultdict(lambda: deque(maxlen=RESIDUAL_SMOOTHING_WINDOW))
    persistent_state = defaultdict(lambda: "uncertain")  # track_id -> 'stationary'/'moving'/'uncertain', carried frame to frame
    stationary_streak = defaultdict(int)
    track_stats = defaultdict(lambda: {"frames_seen": 0, "frames_stationary": 0, "frames_uncertain": 0, "first_frame": None, "last_frame": None})
    custom_class_counts = defaultdict(int)
    severity_samples = defaultdict(list)
    no_road_data_count = 0
    fundamental_failures = 0
    frames_with_flow = 0
    car_reading_failures = 0   # frames where a tracked car had too few trackable points of its own

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        car_result = car_model.track(
            frame, classes=[COCO_CAR_CLASS_ID], tracker="bytetrack.yaml", persist=True, verbose=False
        )[0]
        custom_result = custom_model.predict(frame, conf=CUSTOM_CONF_THRESHOLD, verbose=False)[0]
        road_mask = road_segmenter.drivable_mask(frame)
        draw_road_overlay(frame, road_mask)

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

        placed_label_rects = []

        custom_boxes = custom_result.boxes
        if custom_boxes is not None and len(custom_boxes) > 0:
            for box, conf, cls_id in zip(
                custom_boxes.xyxy.cpu().numpy().astype(int),
                custom_boxes.conf.cpu().numpy(),
                custom_boxes.cls.cpu().numpy().astype(int),
            ):
                cls_name = CUSTOM_CLASS_NAMES[cls_id]
                color = CUSTOM_COLORS[cls_name]
                x1, y1, x2, y2 = box
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                place_label(frame, placed_label_rects, x1, max(12, y1 - 6), f"{cls_name} {conf:.2f}", color)
                custom_class_counts[cls_name] += 1

        boxes = car_result.boxes
        masks = car_result.masks
        clipped_boxes = []
        mask_polygons = []
        if boxes is not None and len(boxes) > 0:
            xyxy = boxes.xyxy.cpu().numpy().astype(int)
            confs_all = boxes.conf.cpu().numpy()
            ids_all = boxes.id.cpu().numpy().astype(int) if boxes.id is not None else [None] * len(xyxy)
            # masks.xy is index-aligned with boxes (Ultralytics guarantee), already in
            # original-image pixel coordinates -- no rescaling needed.
            polygons_all = list(masks.xy) if masks is not None else [None] * len(xyxy)
            confs, ids = [], []
            for box, conf, track_id, polygon in zip(xyxy, confs_all, ids_all, polygons_all):
                x1, y1, x2, y2 = box
                box_w, box_h = x2 - x1, y2 - y1
                if box_h <= 0 or (box_w / box_h) > MAX_CAR_ASPECT_RATIO:
                    continue  # implausible car shape -- see MAX_CAR_ASPECT_RATIO comment
                clipped_boxes.append((max(0, x1), max(0, y1), min(width, x2), min(height, y2)))
                confs.append(conf)
                ids.append(track_id)
                mask_polygons.append(polygon)
        else:
            confs, ids = [], []

        # Rasterize every car's mask once (reused for F's exclusion mask, the per-car
        # consensus check, and Phase 3A's car-width lookup) and build the union exclusion
        # mask for fundamental-matrix estimation.
        car_mask_bools = [rasterize_mask_polygon(polygon, gray.shape) for polygon in mask_polygons]
        all_cars_mask = np.zeros(gray.shape, dtype=bool)
        for cb in car_mask_bools:
            all_cars_mask |= cb

        F = None
        if prev_gray is not None:
            F = estimate_fundamental_matrix(prev_gray, gray, all_cars_mask)
            frames_with_flow += 1
            if F is None:
                fundamental_failures += 1

        if boxes is not None and len(boxes) > 0:
            for (x1, y1, x2, y2), conf, track_id, polygon, mask_bool in zip(clipped_boxes, confs, ids, mask_polygons, car_mask_bools):
                if track_id is None:
                    color = (160, 160, 160)
                    label = f"car {conf:.2f} (no track id)"
                    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                    place_label(frame, placed_label_rects, x1, max(12, y1 - 6), label, color, font_scale=0.5, thickness=1)
                    continue

                stats = track_stats[track_id]
                stats["frames_seen"] += 1
                stats["first_frame"] = frame_idx if stats["first_frame"] is None else stats["first_frame"]
                stats["last_frame"] = frame_idx

                # Ground-contact point: from the segmentation mask when available (bottom row
                # of the car's own silhouette), falling back to the bounding box's bottom-
                # center if the mask is missing or empty. Unchanged from v3.
                raw_ground_point = mask_ground_point(mask_bool)
                if raw_ground_point is None:
                    raw_ground_point = ((x1 + x2) / 2.0, float(y2))

                prev_gp_entry = ground_point_history.get(track_id)
                contiguous = prev_gp_entry is not None and prev_gp_entry[0] == frame_idx - 1

                ema_ground_point = update_ema_point(prev_gp_entry[1] if contiguous else None, raw_ground_point, GROUND_POINT_EMA_ALPHA)
                ground_point_history[track_id] = (frame_idx, ema_ground_point)

                # Epipolar whole-mask consensus residual -- the actual motion signal, replacing
                # v2/v3's single-point homography residual. See module docstring.
                if F is not None and contiguous:
                    car_mask_u8 = (mask_bool.astype(np.uint8)) * 255
                    residual = car_epipolar_residual(F, prev_gray, gray, car_mask_u8)
                    if residual is not None:
                        residual_history[track_id].append(residual)
                    else:
                        car_reading_failures += 1

                if len(residual_history[track_id]) >= MIN_HISTORY_FOR_CONFIDENCE:
                    smoothed_residual = float(np.median(residual_history[track_id]))
                    prev_state = persistent_state[track_id]
                    if prev_state == "stationary":
                        new_state = "moving" if smoothed_residual > RESIDUAL_EXIT_STATIONARY_PX else "stationary"
                    elif prev_state == "moving":
                        new_state = "stationary" if smoothed_residual < RESIDUAL_ENTER_STATIONARY_PX else "moving"
                    else:  # first confident reading for this track, no prior state to hold onto
                        new_state = "stationary" if smoothed_residual < RESIDUAL_ENTER_STATIONARY_PX else "moving"
                    persistent_state[track_id] = new_state

                smoothed_state = persistent_state[track_id]

                if smoothed_state == "stationary":
                    stationary_streak[track_id] += 1
                    stats["frames_stationary"] += 1
                else:
                    stationary_streak[track_id] = 0
                    if smoothed_state == "uncertain":
                        stats["frames_uncertain"] += 1

                flagged = stationary_streak[track_id] >= flag_after_frames

                if flagged:
                    color, status = (0, 0, 255), "STATIONARY (flagged)"
                elif smoothed_state == "stationary":
                    color, status = (0, 140, 255), "stationary"
                elif smoothed_state == "uncertain":
                    color, status = (0, 255, 255), "uncertain (new track)"
                else:
                    color, status = (0, 200, 0), "moving"

                if polygon is not None and len(polygon) > 0:
                    cv2.polylines(frame, [polygon.astype(np.int32)], isClosed=True, color=color, thickness=2)
                else:
                    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                gp_x, gp_y = ema_ground_point
                cv2.circle(frame, (int(gp_x), int(gp_y)), 4, color, -1)
                label = f"car#{track_id} {status}"

                if smoothed_state == "stationary":
                    severity = phase3a_severity((x1, y1, x2, y2), mask_bool, road_mask)
                    if severity is not None:
                        severity_samples[track_id].append(severity)
                        label += f" | {severity*100:.0f}% blocked"
                    else:
                        no_road_data_count += 1
                        label += " | no road data"

                    lane_position = car_lane_position((x1, y1, x2, y2), mask_bool, road_mask)
                    if lane_position == "in_lane":
                        label += " | IN LANE"
                    elif lane_position == "at_edge":
                        label += " | at curb"

                place_label(frame, placed_label_rects, x1, max(12, y1 - 6), label, color)

        timestamp_s = frame_idx / fps
        cv2.putText(frame, f"t={timestamp_s:5.1f}s  frame {frame_idx}/{total_frames}", (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(frame, f"t={timestamp_s:5.1f}s  frame {frame_idx}/{total_frames}", (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1, cv2.LINE_AA)
        draw_legend(frame)

        writer.write(frame)
        prev_gray = gray
        frame_idx += 1
        if frame_idx % 50 == 0 or frame_idx == total_frames:
            print(f"  processed {frame_idx}/{total_frames} frames", file=sys.stderr)

    cap.release()
    writer.release()

    print(f"\nWrote annotated video to {args.output}")
    print(f"\n{len(track_stats)} distinct car track(s) detected:")
    for track_id, stats in sorted(track_stats.items()):
        first_s = stats["first_frame"] / fps
        last_s = stats["last_frame"] / fps
        pct_stationary = 100 * stats["frames_stationary"] / stats["frames_seen"] if stats["frames_seen"] else 0
        pct_uncertain = 100 * stats["frames_uncertain"] / stats["frames_seen"] if stats["frames_seen"] else 0
        sev = severity_samples.get(track_id)
        sev_str = f", mean severity {np.mean(sev)*100:.0f}% blocked (n={len(sev)})" if sev else ""
        print(
            f"  car#{track_id}: seen {stats['frames_seen']} frames "
            f"({first_s:.1f}s - {last_s:.1f}s), {pct_stationary:.0f}% classified stationary, "
            f"{pct_uncertain:.0f}% uncertain (new-track bootstrap){sev_str}"
        )

    print("\ncustom-model detections (raw per-frame count, not deduplicated across frames):")
    for cls_name in CUSTOM_CLASS_NAMES:
        print(f"  {cls_name}: {custom_class_counts[cls_name]} boxes across all frames")

    print(f"\nPhase 3A: {no_road_data_count} stationary-car frames had no drivable-area pixels at the car's ground row (severity not computed for those)")
    print(f"Background fundamental matrix: failed to estimate (too few trackable background features) on {fundamental_failures}/{frames_with_flow} frames")
    print(f"Per-car epipolar reading: failed (too few trackable points on the car itself) on {car_reading_failures} car-frames")


if __name__ == "__main__":
    main()
