"""
v6 demo scanner. Adds a second, structurally DIFFERENT motion signal alongside v5's epipolar
(fundamental-matrix) whole-mask consensus: a Focus-of-Expansion (FoE) angle + magnitude
likelihood, adapted from Ogawa, An & Yamashita's FoELS paper (arXiv:2507.13628, 2025) -- see
`foe_signal.py` for the full mechanism and why it is NOT a repeat of v3's reverted
direction-consistency attempt. Full research trail, empirical testing, and the visual evidence
that motivated shipping this: `../ALGORITHMS_EXPLAINED.md` section 6 (v6 addendum) and this
session's chat log.

WHY A SECOND SIGNAL, NOT A REPLACEMENT: v5's epipolar residual and every method before it shares
one structural blind spot -- a car moving at close to the ego vehicle's own speed and direction
produces close to zero apparent motion relative to the camera, which is mathematically
indistinguishable from parked using ANY method that only measures camera-relative motion. This
was flagged as a fundamental, unfixable-by-vision-alone limit (`ALGORITHMS_EXPLAINED.md` section
6.6). It turned out to be only PARTIALLY true: FoELS's own contribution (a flow-magnitude check
in addition to angle, added specifically because pure angle also fails for parallel motion) can
catch a car that's moving roughly parallel to the ego vehicle but at a genuinely different speed
-- which covers most real "car in the same lane ahead of you" traffic. It CANNOT catch the literal
zero-relative-velocity edge case (no measurement can, by the same physics), but real-footage
testing on this project's own videos visually confirmed it correctly flags multiple cars driving
in traffic that v5's epipolar signal alone reads as wrongly stationary (a busy multi-lane street,
`0a8a...mp4`: `car#3`/`car#13`/`car#5`/`car#15`/`car#189`, each independently visually confirmed
to be genuinely driving, not parked).

WHY COMBINE RATHER THAN SWITCH ENTIRELY TO FoE: FoE has its own real, separately-confirmed
weakness -- on a car approaching close to head-on (not parallel), it can correctly catch the
motion early, then wrongly revert to "stationary" for several seconds before correctly
re-detecting (visually confirmed on `car#288`, the known far-field oncoming car in
`0b21d2708d72b821bec4c81a42d46e92.mp4`: correct at t=12.5s, wrong at t=15.5s, still wrong at
t=17.5s even after v5's epipolar signal catches up). The two signals are NOT derived from the
same underlying computation (epi = fundamental-matrix epipolar-line distance; FoE = RANSAC
line-intersection vanishing point + per-point angle/magnitude) -- unlike v3's direction-
consistency + expansion-residual, which were both functions of the same single homography and
therefore failed together, not independently. That gives a principled reason to actually trust
an OR-combination here: either signal confidently reading "moving" is treated as moving,
covering each one's blind spot with the other's strength. See COMBINED CLASSIFICATION LOGIC
below for the exact rule. This has NOT been exhaustively tuned -- it is a first, reasoned
combination checked against the same known cases as every prior version, not a labeled-ground-
truth-fitted decision boundary.

Everything else (detection, tracking, road segmentation, Phase 3A severity, in-lane/at-curb
check, hood-misdetection filter) is unchanged from `../v5/demo_scan_v5.py` -- imported directly
rather than copy-pasted, so a fix to any of those in v5 doesn't silently diverge here.
"""

import argparse
import os
import sys
from collections import defaultdict, deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # vendored copy: siblings in this dir (v12/lib/)

import cv2
import numpy as np
import torch
from ultralytics import YOLO

import demo_scan_v5 as v5
from foe_signal import estimate_foe_and_static_flow, car_flow_points, car_foe_probability
from road_completion import encroachment_ratio_v7

# FoE classification hysteresis. Chosen as the direct analog of v5's own epipolar hysteresis
# structure (a 0-1 probability instead of a pixel distance), reasoned from FoELS's own 0.5
# per-pixel binarization point. Checked against real footage this session (both videos, multiple
# known cars) -- not fit to a labeled ground-truth set, same honesty caveat as every threshold
# in this project.
FOE_SMOOTHING_WINDOW = v5.RESIDUAL_SMOOTHING_WINDOW
FOE_ENTER_STATIONARY = 0.30
FOE_EXIT_STATIONARY = 0.55
FOE_MIN_HISTORY_FOR_CONFIDENCE = v5.MIN_HISTORY_FOR_CONFIDENCE

# Car-level FoE confidence gate, added after IMG_0063.MOV's confirmed-parked SUV investigation
# (see diagnose_foe_sensitivity.py / diagnose_foe_car_level_gate.py and the session log for the
# full multi-round experiment trail). Root cause, confirmed by direct measurement: P_a's angular
# evidence is unreliable when a car's own tracked points sit close to the estimated FoE relative
# to how much the FoE itself is currently jittering frame-to-frame -- a small positional error in
# the FoE estimate induces a LARGE angular error for a nearby point (e_perp/distance, standard
# small-angle/parallax relation) but a small one for a distant point. Two other mechanisms were
# tried and rejected first: shrinking a low-confidence point's P_a value toward 0.5 made things
# WORSE (shrinking toward the classifier's own decision threshold biases everything across it);
# down-weighting points within a car's own aggregation was a NULL result (a car's own mask is
# small relative to its distance to the FoE, so its own points don't vary enough in distance for
# point-level weighting to matter -- the confidence signal lives BETWEEN cars, not within one).
#
# This gates admission at the CAR level instead: each frame, a car's own median distance to the
# FoE is compared against the FoE's own recent positional jitter (sigma_foe, a trailing median of
# its frame-to-frame displacement -- an empirical, assumption-free proxy for its uncertainty).
# confidence = d^2 / (d^2 + (k*sigma_foe)^2) -- a smooth 0-1 weight, 0.5 at d = k*sigma_foe. Below
# CONFIDENCE_GATE_FLOOR, that frame's P_FoE is simply NOT pushed into the smoothing history --
# the window holds its last trustworthy readings rather than being diluted by a geometrically
# unreliable one this frame. No change to car_foe_probability's math, no new FSM state.
#
# k and the floor are untuned free parameters, same honesty caveat as every threshold in this
# project -- chosen from a small sweep (k in {1,2,3}, floor in {0.3,0.5,0.7}) checked against all
# three known ground-truth cases (a confirmed-parked SUV, a different confirmed-parked car, and a
# confirmed-MOVING convoy car FoE exists specifically to catch), run through the REAL
# classify_from_history/combine_states state machine, not a proxy metric. k=2/floor=0.5 was the
# best balance found: real, repeatable improvement on the parked SUV (roughly 85%->55-65% wrongly
# "moving" across repeated RANSAC-random trials) with ZERO measured cost to the other known-good
# parked car and only a small cost to the convoy car's detection (~95% correct, down from ~97-99%
# baseline). A smoothly-adaptive alpha (scaling F_l's own weight by this same confidence, instead
# of a fixed 0.25) was also tried, on the reasoning that F_l's LOCAL magnitude reference shares
# the same noisy distance-to-FoE denominator as P_a near the FoE -- but verified over 3 repeated
# runs to NOT reliably beat the simple fixed alpha=0.25, so it was not adopted; added complexity
# without a repeatable payoff.
CONFIDENCE_GATE_K = 2.0
CONFIDENCE_GATE_FLOOR = 0.5
FOE_JITTER_WINDOW = FOE_SMOOTHING_WINDOW  # same trailing-window scale as every other smoothing constant here

# Background-exclusion classes for BOTH the epipolar and FoE background fits. Only "car" (2) was
# excluded originally -- fine on the two videos v6 was built against, but on a dense mixed-traffic
# street (confirmed on IMG_0063.MOV: a genuinely parked car read 9% FoE-stationary because
# unmasked motorcycles/pedestrians, which are NOT static, were feeding both the RANSAC
# vanishing-point fit and the "expected static flow magnitude" reference) this corrupts FoE badly
# -- the estimated FoE point was observed jumping 50-300px between frames and the static-flow
# reference swinging 3.5-25px on the same short clip. Classes: person(0), bicycle(1), car(2),
# motorcycle(3), bus(5), truck(7). Cost is ~free -- `classes=` filters YOLO's output after
# inference runs, it does not trigger a second forward pass.
BACKGROUND_EXCLUDE_CLASSES = [0, 1, v5.COCO_CAR_CLASS_ID, 3, 5, 7]

# Safety net on top of the class-expansion fix above, for whatever contamination or geometric
# ill-conditioning still gets through: reject a frame's FoE background estimate outright if the
# fitted FoE point jumped implausibly far from the last-accepted one. A real ego-motion vanishing
# point moves smoothly frame to frame; a several-hundred-pixel jump is a sign the RANSAC fit locked
# onto a spurious consensus (e.g. a cluster of independently-moving objects), not a legitimate
# change in heading. Threshold is relative to frame diagonal so it isn't tied to one video's
# resolution -- reasoned, not fit to labeled ground truth, same caveat as this project's other
# thresholds. The escape valve (accept anyway after several consecutive rejections) exists so a
# real, sustained heading change doesn't get permanently locked out.
FOE_MAX_JUMP_FRACTION_OF_DIAGONAL = 0.15
FOE_JUMP_REJECT_ESCAPE_VALVE = 5

# combine_states() itself has no memory -- it's recomputed fresh every frame from two ALREADY
# smoothed+hysteresis sub-signals. That's fine for entering "moving" (both sub-signals already
# require sustained evidence, and catching real motion fast is a confirmed win worth keeping).
# It's not enough for entering "stationary": a car near-head-on to the ego vehicle can make FoE's
# raw signal wrong for 2+ seconds straight (confirmed on car#288, ALGORITHMS_EXPLAINED.md-adjacent
# session log), far longer than the 9-frame (~0.36s @25fps) smoothing window either sub-signal
# uses. This debounce requires the COMBINED reading to say "stationary" for a sustained stretch
# before it's actually committed to the displayed/logged state -- shrinks that kind of multi-
# second misfire, does not guarantee eliminating it if the misfire itself outlasts the debounce.
STATIONARY_DEBOUNCE_SECONDS = 0.75

# "Disputed" state, added after IMG_0063.MOV (dense, slow, stop-and-go narrow-street traffic)
# surfaced a real structural problem with the AND-gate: on that footage, FoE's raw signal is not
# just occasionally noisy on a genuinely parked car, it is PERSISTENTLY wrong -- confirmed via
# direct per-frame tracing (a confirmed-parked SUV read epi 99% stationary / FoE ~10-13%
# stationary for its entire 8+ second time on screen; broadening FoE's own background-exclusion
# mask barely moved that number, since actual non-car-moving-object contamination in that window
# measured only ~1.4% mean frame coverage -- not the dominant cause).
#
# The first attempt here was a single-signal override: if epi alone reads "stationary"
# continuously for a long sustained stretch, trust it over a disagreeing FoE. That was proven
# UNSAFE, not just untested -- direct measurement found the confirmed-parked car's sustained
# epi-stationary streak (8.6s) is SHORTER than the confirmed-MOVING convoy car's own sustained
# epi-stationary streak (13.8s, `car#3`, the exact case v6's FoE signal exists to catch). No
# duration threshold can separate these; raising it doesn't reorder which is longer. "epi
# confident for a long time while FoE disagrees" is the SAME shape of evidence whether epi is
# right or FoE is right -- there is no principled way to pick a winner from these two signals'
# own histories alone.
#
# So this doesn't try to. When epi reads "stationary" and FoE reads "moving" continuously for a
# sustained stretch, the combined state becomes "disputed" -- a fourth state, distinct from
# stationary/moving/uncertain, that does NOT progress toward the STATIONARY (flagged) escalation
# and does NOT get scored for severity/lane-position (this project doesn't guess when it doesn't
# know -- see the "uncertain" state's own precedent). It surfaces the disagreement for a human to
# resolve instead of silently picking a side that's right exactly half the time by construction.
# Threshold reasoned the same way as every other duration constant in this project -- not fit to
# labeled ground truth.
DISPUTE_SECONDS = 6.0


def classify_from_history(history, state, enter_threshold, exit_threshold, min_history, greater_is_moving=True):
    """Shared smoothing + hysteresis pattern, used identically for both the epipolar and FoE
    signals (only the threshold direction/values differ). `state` is the single persisted
    state for this track/signal, updated in place by the caller reading the return value."""
    if len(history) < min_history:
        return state
    smoothed = float(np.median(history))
    if state == "stationary":
        return "moving" if smoothed > exit_threshold else "stationary"
    elif state == "moving":
        return "stationary" if smoothed < enter_threshold else "moving"
    else:
        return "stationary" if smoothed < enter_threshold else "moving"


def combine_states(epi_state, foe_state):
    """COMBINED CLASSIFICATION LOGIC, the actual new decision rule in v6: either signal
    confidently reading 'moving' wins (catches whichever failure mode the OTHER signal is
    currently blind to); both must agree 'stationary' to call it stationary (conservative --
    a car isn't declared safely parked unless neither independent geometric check objects);
    anything else (one uncertain, or a genuine split that isn't a moving-vote) stays
    'uncertain' rather than guessing. See module docstring for why these two signals are
    independent enough to combine this way, unlike v3's reverted attempt. NOTE: the caller in
    main() upgrades a SUSTAINED epi='stationary'/foe='moving' split to a distinct 'disputed'
    state (see DISPUTE_SECONDS) -- this function itself has no memory and doesn't know that."""
    if epi_state == "moving" or foe_state == "moving":
        return "moving"
    if epi_state == "stationary" and foe_state == "stationary":
        return "stationary"
    return "uncertain"


def draw_legend(frame):
    lines = [
        "car: YOLOv8n-seg + ByteTrack + v5 epipolar signal COMBINED with v6 FoE signal (see below)",
        "combined rule: EITHER signal saying moving -> moving; BOTH saying stationary -> stationary; else uncertain",
        "stationary commit requires ~0.75s sustained agreement (debounce) -- moving stays instant, see demo_scan_v6.py header",
        "label shows epi:<v5 signal> and foe:<v6 signal> separately so a disagreement is visible",
        "FoE catches cars moving parallel/co-moving with the ego vehicle that epi alone misses (convoy case)",
        "epi catches cars FoE can transiently mis-read while approaching near head-on (see ALGORITHMS_EXPLAINED.md 6.6)",
        "magenta DISPUTED = epi says stationary, foe says moving, sustained 6+s -- neither auto-picked, see demo_scan_v6.py header",
        "FoE uses a per-location magnitude reference + distance-to-FoE confidence gate (post-IMG_0063.MOV fix, see CONFIDENCE_GATE_K header)",
        "yellow box = not enough temporal history yet (just-appeared track), not a disagreement",
        "crosswalk/sign_P/sign_S: fine-tuned YOLOv8n (test mAP50=0.93, clean-photo domain)",
        "road (green tint): YOLOP drivable-area -- IN LANE/at curb: position check, NOT a moving/stationary check",
        "EXPERIMENTAL COMBINATION, not exhaustively validated -- see ALGORITHMS_EXPLAINED.md section 6 (v6 addendum)",
    ]
    y = frame.shape[0] - 15 - (len(lines) - 1) * 16
    for line in lines:
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (255, 255, 255), 1, cv2.LINE_AA)
        y += 16


def main():
    parser = argparse.ArgumentParser(description="v6 demo: epipolar signal (v5) combined with Focus-of-Expansion signal.")
    parser.add_argument("--input", default="../0b21d2708d72b821bec4c81a42d46e92.mp4")
    parser.add_argument("--output", default="demo_scan_output_v6.mp4")
    parser.add_argument("--model", default="yolov8n-seg.pt")
    parser.add_argument("--custom-model", default="../v1/runs/detect/runs/signs_crosswalk_v1/weights/best.pt")
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()

    car_model = YOLO(args.model)
    custom_model = YOLO(args.custom_model)
    road_segmenter = v5.RoadSegmenter(torch.device(args.device))

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        sys.exit(f"Could not open {args.input}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    flag_after_frames = max(1, int(round(v5.FLAG_AFTER_SECONDS * fps)))
    stationary_debounce_frames = max(1, int(round(STATIONARY_DEBOUNCE_SECONDS * fps)))
    foe_max_jump_px = FOE_MAX_JUMP_FRACTION_OF_DIAGONAL * float(np.hypot(width, height))
    dispute_frames = max(1, int(round(DISPUTE_SECONDS * fps)))

    writer = cv2.VideoWriter(args.output, cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))

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
    track_stats = defaultdict(lambda: {
        "frames_seen": 0, "frames_stationary": 0, "frames_uncertain": 0, "frames_disputed": 0,
        "epi_frames_stationary": 0, "foe_frames_stationary": 0,
        "stationary_candidacies_aborted": 0, "max_disagreement_streak": 0,
        "first_frame": None, "last_frame": None,
    })
    custom_class_counts = defaultdict(int)
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

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        car_result = car_model.track(
            frame, classes=BACKGROUND_EXCLUDE_CLASSES, tracker="bytetrack.yaml", persist=True, verbose=False
        )[0]
        custom_result = custom_model.predict(frame, conf=v5.CUSTOM_CONF_THRESHOLD, verbose=False)[0]
        road_mask = road_segmenter.drivable_mask(frame)
        v5.draw_road_overlay(frame, road_mask)

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        placed_label_rects = []

        custom_boxes = custom_result.boxes
        if custom_boxes is not None and len(custom_boxes) > 0:
            for box, conf, cls_id in zip(
                custom_boxes.xyxy.cpu().numpy().astype(int),
                custom_boxes.conf.cpu().numpy(),
                custom_boxes.cls.cpu().numpy().astype(int),
            ):
                cls_name = v5.CUSTOM_CLASS_NAMES[cls_id]
                color = v5.CUSTOM_COLORS[cls_name]
                x1, y1, x2, y2 = box
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                v5.place_label(frame, placed_label_rects, x1, max(12, y1 - 6), f"{cls_name} {conf:.2f}", color)
                custom_class_counts[cls_name] += 1

        boxes = car_result.boxes
        masks = car_result.masks
        clipped_boxes, mask_polygons, ids = [], [], []
        other_moving_mask_bools = []
        if boxes is not None and len(boxes) > 0:
            xyxy = boxes.xyxy.cpu().numpy().astype(int)
            cls_all = boxes.cls.cpu().numpy().astype(int)
            ids_all = boxes.id.cpu().numpy().astype(int) if boxes.id is not None else [None] * len(xyxy)
            polygons_all = list(masks.xy) if masks is not None else [None] * len(xyxy)
            for (x1, y1, x2, y2), cls_id, tid, poly in zip(xyxy, cls_all, ids_all, polygons_all):
                if cls_id != v5.COCO_CAR_CLASS_ID:
                    # Not tracked/classified as a car -- only used below to keep it out of the
                    # "this is static background" pool for both motion signals (see
                    # BACKGROUND_EXCLUDE_CLASSES above).
                    other_moving_mask_bools.append(v5.rasterize_mask_polygon(poly, gray.shape))
                    continue
                box_w, box_h = x2 - x1, y2 - y1
                if box_h <= 0 or (box_w / box_h) > v5.MAX_CAR_ASPECT_RATIO:
                    continue
                clipped_boxes.append((max(0, x1), max(0, y1), min(width, x2), min(height, y2)))
                ids.append(tid)
                mask_polygons.append(poly)

        car_mask_bools = [v5.rasterize_mask_polygon(p, gray.shape) for p in mask_polygons]
        all_cars_mask = np.zeros(gray.shape, dtype=bool)
        for cb in car_mask_bools:
            all_cars_mask |= cb
        all_moving_objects_mask = all_cars_mask.copy()
        for ob in other_moving_mask_bools:
            all_moving_objects_mask |= ob

        F, foe_result = None, None
        if prev_gray is not None:
            frames_with_flow += 1
            # epi's own fundamental-matrix fit was never the broken signal here -- confirmed by a
            # direct regression test that broadening ITS exclusion mask too (to the same
            # all_moving_objects_mask FoE needs) dropped a known-good parked car from 95% to 68%
            # correctly-stationary. RANSAC fundamental-matrix fitting is a well-constrained fit
            # over many points; excluding large person/motorcycle-covered regions of a crowded
            # narrow street apparently starves it of otherwise-fine background points more than it
            # helps. Left on the original car-only mask, unchanged from v5.
            F = v5.estimate_fundamental_matrix(prev_gray, gray, all_cars_mask)
            if F is None:
                fundamental_failures += 1
            foe_result = estimate_foe_and_static_flow(prev_gray, gray, all_moving_objects_mask)
            if foe_result is not None:
                candidate_foe_point, _, _ = foe_result
                # Raw jitter tracking for the confidence gate below -- deliberately independent of
                # the jump-rejection block right after this: that block decides whether to use a
                # wildly-off estimate AT ALL, this one measures how much the (accepted-or-not) raw
                # estimate is naturally moving frame to frame, the empirical uncertainty proxy the
                # gate is built on. Mixing the two would mean a rejected jump silently vanishes
                # from the jitter estimate too, understating exactly the instability the gate
                # needs to see.
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

        for (x1, y1, x2, y2), track_id, polygon, mask_bool in zip(clipped_boxes, ids, mask_polygons, car_mask_bools):
            if track_id is None:
                continue

            stats = track_stats[track_id]
            stats["frames_seen"] += 1
            stats["first_frame"] = frame_idx if stats["first_frame"] is None else stats["first_frame"]
            stats["last_frame"] = frame_idx

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
                        # No jitter history yet (start of video) -> admit by default, don't invent
                        # a penalty from nothing. See CONFIDENCE_GATE_K docstring above for the
                        # full derivation/validation of this gate.
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
            if epi_state[track_id] == "stationary" and foe_state[track_id] == "moving":
                disagreement_streak[track_id] += 1
            else:
                disagreement_streak[track_id] = 0
            stats["max_disagreement_streak"] = max(stats["max_disagreement_streak"], disagreement_streak[track_id])

            raw_combined = combine_states(epi_state[track_id], foe_state[track_id])
            prev_candidate_streak = stationary_candidate_streak[track_id]
            # Checked before the normal moving/stationary commit below: this condition can only be
            # true when epi=="stationary" and foe=="moving" (see disagreement_streak above), which
            # is exactly the one case where combine_states()'s OR-rule would otherwise silently
            # resolve a genuine, sustained conflict by picking "moving" -- see DISPUTE_SECONDS
            # docstring for why picking either side automatically was proven unsafe.
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
                # else: still a candidate -- keep displaying whatever was already committed
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
                color, status = (0, 0, 255), "STATIONARY (flagged)"
            elif combined == "stationary":
                color, status = (0, 140, 255), "stationary"
            elif combined == "disputed":
                # Deliberately not stationary or moving -- epi and foe have sustained-disagreed
                # long enough that picking either automatically was proven unsafe (module
                # docstring on DISPUTE_SECONDS). Distinct color so it reads as "needs a human
                # look," not as a third confidence level between the other two.
                color, status = (255, 0, 255), "DISPUTED (epi/foe disagree)"
            elif combined == "uncertain":
                color, status = (0, 255, 255), "uncertain"
            else:
                color, status = (0, 200, 0), "moving"

            if polygon is not None and len(polygon) > 0:
                cv2.polylines(frame, [polygon.astype(np.int32)], isClosed=True, color=color, thickness=2)
            else:
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            gp_x, gp_y = ema_ground_point
            cv2.circle(frame, (int(gp_x), int(gp_y)), 4, color, -1)

            agree = epi_state[track_id] == foe_state[track_id]
            sub_color = color if agree else (0, 0, 255)
            label = f"car#{track_id} {status}"

            if combined == "stationary":
                severity, _corrected_sides = encroachment_ratio_v7((x1, y1, x2, y2), mask_bool, road_mask)
                if severity is not None:
                    severity_samples[track_id].append(severity)
                    label += f" | {severity*100:.0f}% blocked"
                    if severity > 0.8 and os.environ.get("DEBUG_SEVERITY"):
                        print(f"DEBUG_HIGH_SEV t={frame_idx/fps:.2f} car#{track_id} severity={severity:.3f} sides={_corrected_sides} box=({x1},{y1},{x2},{y2})", file=sys.stderr)
                else:
                    no_road_data_count += 1
                    label += " | no road data"
                lane_position = v5.car_lane_position((x1, y1, x2, y2), mask_bool, road_mask)
                if lane_position == "in_lane":
                    label += " | IN LANE"
                elif lane_position == "at_edge":
                    label += " | at curb"

            v5.place_label(frame, placed_label_rects, x1, max(12, y1 - 6), label, color)
            detail = f"  epi:{epi_state[track_id]} foe:{foe_state[track_id]}"
            v5.place_label(frame, placed_label_rects, x1, max(12, y1 - 6) + 16, detail, sub_color, font_scale=0.42, thickness=1)

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
        n = stats["frames_seen"]
        pct_stationary = 100 * stats["frames_stationary"] / n if n else 0
        pct_uncertain = 100 * stats["frames_uncertain"] / n if n else 0
        pct_disputed = 100 * stats["frames_disputed"] / n if n else 0
        pct_epi_stat = 100 * stats["epi_frames_stationary"] / n if n else 0
        pct_foe_stat = 100 * stats["foe_frames_stationary"] / n if n else 0
        sev = severity_samples.get(track_id)
        sev_str = f", mean severity {np.mean(sev)*100:.0f}% blocked (n={len(sev)})" if sev else ""
        aborted = stats["stationary_candidacies_aborted"]
        max_streak_s = stats["max_disagreement_streak"] / fps
        disputed_str = f", {pct_disputed:.0f}% disputed (max sustained disagreement {max_streak_s:.1f}s)" if stats["frames_disputed"] else ""
        print(
            f"  car#{track_id}: seen {n} frames ({first_s:.1f}s - {last_s:.1f}s), "
            f"combined {pct_stationary:.0f}% stationary / {pct_uncertain:.0f}% uncertain "
            f"(epi {pct_epi_stat:.0f}% stat, foe {pct_foe_stat:.0f}% stat, "
            f"{aborted} stationary-candidacy aborted before debounce committed{disputed_str}){sev_str}"
        )

    print("\ncustom-model detections (raw per-frame count, not deduplicated across frames):")
    for cls_name in v5.CUSTOM_CLASS_NAMES:
        print(f"  {cls_name}: {custom_class_counts[cls_name]} boxes across all frames")

    print(f"\nPhase 3A: {no_road_data_count} stationary-car frames had no drivable-area pixels at the car's ground row")
    print(f"Background fundamental matrix: failed on {fundamental_failures}/{frames_with_flow} frames")
    print(f"Background FoE estimation: failed on {foe_estimation_failures}/{frames_with_flow} frames")
    print(f"Background FoE estimate rejected as an implausible jump: {foe_jump_rejections}/{frames_with_flow} frames")
    print(f"Per-car epipolar reading: failed on {epi_reading_failures} car-frames")
    print(f"Per-car FoE reading: failed on {foe_reading_failures} car-frames")
    total_gate_decisions = foe_gate_admissions + foe_gate_rejections
    gate_reject_pct = (100 * foe_gate_rejections / total_gate_decisions) if total_gate_decisions else 0.0
    print(f"Car-level FoE confidence gate: rejected {foe_gate_rejections}/{total_gate_decisions} car-frames ({gate_reject_pct:.1f}%) as too close to the FoE relative to its current jitter")


if __name__ == "__main__":
    main()
