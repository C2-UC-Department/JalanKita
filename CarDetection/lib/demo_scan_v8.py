"""
v8 demo scanner. Carries the full validated v5/v6/v7 stack forward unchanged (YOLOv8n-seg +
ByteTrack, v5's epipolar signal, v6's FoE signal + confidence gate + disputed-state debounce,
v7's encroachment_ratio_v7 severity metric, car_lane_position) and adds ONE new layer on top:
distinguishing PARKED from TRAFFIC_STOPPED for cars the existing pipeline has already flagged
"STATIONARY (flagged)".

WHY THIS IS A DIFFERENT PROBLEM THAN EVERYTHING BEFORE IT: every motion signal in this project
(epipolar residual, FoE angle+magnitude) measures velocity RELATIVE TO THE CAMERA at a single
instant. A parked car and a car stopped in traffic produce the IDENTICAL reading at that instant --
both are zero relative velocity. This is the same structural blind spot that motivated building FoE
in the first place (the "convoy" case: a car moving at the ego vehicle's own speed looks stationary
to any camera-relative measurement), just showing up one level up the reasoning chain. No amount of
tuning the existing signals can fix this -- the distinguishing evidence has to come from something
OTHER than "how is this car currently moving relative to the camera."

Two signals, neither requiring a new sensor or model, do carry that evidence:

1. RESUMPTION -- does this same track eventually go back to "moving" (not just an instantaneous
   blip, a sustained return) before it leaves the frame? A traffic-stopped car does; a parked car,
   by definition, does not (within the observation window this footage gives us).
2. NEIGHBOR SYNCHRONY -- are OTHER currently-tracked cars nearby ALSO stationary right now? Traffic
   congestion is fundamentally a multi-car, correlated phenomenon; a parked car sits still while
   surrounding through-traffic keeps moving around it. This is the one genuinely new piece of
   machinery here -- every motion signal so far classifies each car fully independently, with zero
   cross-referencing between tracks in the same frame.

"Nearby" is defined via GROUND-CONTACT ROW PROXIMITY (see NEIGHBOR_ROW_BAND_PX below), not raw
pixel/Euclidean distance -- chosen deliberately over both alternatives considered: raw pixel
distance is badly perspective-distorted on this portrait dashcam (100px apart near the horizon is a
much larger real gap than 100px apart near the camera), and a proper ground-plane distance needs
Phase B's physical IPM calibration, which isn't built yet and would block this feature on an
unrelated logistics step. Ground row is a reasonable proxy for DEPTH (closer to the ego vehicle =
larger row number), and depth-proximity is exactly what "part of the same local traffic queue right
now" needs -- it does not distinguish left lane / right lane / opposing traffic at the same depth,
which is a real, acknowledged limitation, not a hidden one.

Curb proximity (a THIRD candidate signal GPT's second-opinion round proposed as new) already
exists and already ships -- v5.car_lane_position's "at_edge"/"in_lane" tag. Not duplicated here.

Both new signals feed a per-track, rule-based classifier (not ML -- log the features and watch
them against real footage first, same "measurement before mechanism" discipline used throughout
this project) producing a FOURTH state alongside stationary/moving/uncertain/disputed, for tracks
that reach "STATIONARY (flagged)":

    TRAFFIC_STOPPED  -- resumed sustained motion after the stop, OR a majority of nearby cars are
                        also currently stationary while flagged.
    PARKED           -- reached the end of its visible track (video ended or it left frame) while
                        still flagged, never resumed, and neighbors were mostly moving throughout.
    UNRESOLVED       -- track ended before enough resumption/neighbor evidence accumulated either
                        way (e.g. occluded, or genuinely too little surrounding traffic to judge).
                        Deliberately not forced to a side, same precedent as the "uncertain" and
                        "disputed" states already in this pipeline -- see DISPUTE_SECONDS in v6.

The live per-frame label shows a tentative read (TRAFFIC_STOPPED if resumed-so-far or currently
high neighbor ratio, else "PARKED?" as a running candidate); the end-of-run summary gives the
authoritative classification using the FULL observation window, same pattern as severity's live
number vs. its mean-over-track summary stat.
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
from demo_scan_v6 import (
    classify_from_history, combine_states,
    FOE_SMOOTHING_WINDOW, FOE_ENTER_STATIONARY, FOE_EXIT_STATIONARY, FOE_MIN_HISTORY_FOR_CONFIDENCE,
    CONFIDENCE_GATE_K, CONFIDENCE_GATE_FLOOR, FOE_JITTER_WINDOW,
    BACKGROUND_EXCLUDE_CLASSES,
    FOE_MAX_JUMP_FRACTION_OF_DIAGONAL, FOE_JUMP_REJECT_ESCAPE_VALVE,
    STATIONARY_DEBOUNCE_SECONDS, DISPUTE_SECONDS,
)

# How close two cars' ground-contact rows need to be (in pixels) to count as "nearby" for the
# neighbor-synchrony signal -- see module docstring for why row proximity (a depth proxy) was
# chosen over raw pixel distance or a full ground-plane distance. Reasoned as "roughly one car's
# own vertical extent at moderate distance in these videos" -- untuned, same honesty caveat as
# every threshold in this project.
NEIGHBOR_ROW_BAND_PX = 80

# Minimum number of nearby cars required before the neighbor-ratio signal is trusted at all. A
# lone stationary car with no other traffic anywhere nearby has an UNDEFINED neighbor ratio, not a
# 0% (moving-neighbors) ratio -- "no evidence" and "evidence of no congestion" are different
# things, and conflating them would silently bias every isolated parked car toward looking
# correlated-with-nothing, which is not the same as looking uncorrelated with real traffic.
NEIGHBOR_MIN_COUNT = 1

# Fraction of nearby cars that must ALSO be stationary/flagged for a stop to be read as correlated
# with surrounding traffic. A simple majority, reasoned the same way as every other threshold here.
NEIGHBOR_RATIO_TRAFFIC_THRESHOLD = 0.5

# How long a track must sustain "moving" AFTER having been flagged before it counts as a genuine
# resumption (not a single-frame tracking/motion-signal blip). Same debounce scale already used
# for entering "stationary" in v6, applied symmetrically here for the same reason: a real semantic
# transition should be sustained, not instantaneous.
RESUMPTION_DEBOUNCE_SECONDS = STATIONARY_DEBOUNCE_SECONDS

# How many EXTRA seconds of confirmed "stationary" time (beyond the existing flag threshold,
# v5.FLAG_AFTER_SECONDS) a track needs before its track ending (for ANY reason -- occlusion,
# leaving the frame, or the clip itself ending) is trusted as a confident PARKED read.
#
# First version of this file gated PARKED on "the video ended while this car was still visible" --
# wrong, caught by testing before it shipped: the DOMINANT way a real parked-car track ends in a
# single-pass dashcam is the ego vehicle driving past and the car leaving the frame, not the clip
# running out. That version silently misclassified every ordinary "drove past a parked car" case
# as UNRESOLVED. What actually matters is not WHY the track ended, but whether it ended after we'd
# already watched it stay put for a good while without resuming -- that's true regardless of
# whether the camera happened to still be pointed at it. A track that barely crossed the initial
# flag threshold before disappearing hasn't given the resumption/neighbor signals enough time to
# say anything meaningful, so it should stay UNRESOLVED; one observed stationary for substantially
# longer, with no resumption, is a reasonable PARKED call.
MIN_EXTRA_STATIONARY_SECONDS_FOR_PARKED = 2.0


def neighbor_stop_ratio(this_ground_row, this_track_id, frame_records):
    """Fraction of OTHER cars in this SAME frame, restricted to ones v5.car_lane_position calls
    "in_lane", whose ground-contact row is within NEIGHBOR_ROW_BAND_PX of this car's, that are
    themselves currently stationary/disputed.

    Restricting to "in_lane" neighbors specifically (found necessary during testing, not assumed
    up front -- see SESSION_LOG_V8.md): a naive version counting ANY nearby stationary car
    conflates two very different situations that look identical under "fraction of neighbors
    stopped" -- a genuine traffic jam (several IN-LANE cars stopped together) and a curb-parking
    corridor (several AT-CURB cars that all happen to be parked at once, which this whole project's
    v7 phase spent significant effort mapping out). A row of independently curb-parked cars would
    otherwise register as "high neighbor synchrony" and get wrongly read as correlated traffic,
    exactly backwards. Filtering the neighbor pool (and its denominator) to only "in_lane" cars
    means the ratio answers "of the traffic actually sharing this car's lane, how much of it is
    also stopped" -- curb-parked neighbors are excluded from BOTH the count and the total, not
    counted as evidence either way.

    Returns None if fewer than NEIGHBOR_MIN_COUNT such in-lane neighbors exist this frame (see
    NEIGHBOR_MIN_COUNT docstring -- absence of neighbors is not evidence of anything)."""
    neighbors = [
        r for r in frame_records
        if r["track_id"] != this_track_id
        and abs(r["ground_row"] - this_ground_row) <= NEIGHBOR_ROW_BAND_PX
        and r["lane_position"] == "in_lane"
    ]
    if len(neighbors) < NEIGHBOR_MIN_COUNT:
        return None
    stopped = sum(1 for r in neighbors if r["combined"] in ("stationary", "disputed"))
    return stopped / len(neighbors)


def draw_legend(frame):
    lines = [
        "car: YOLOv8n-seg + ByteTrack + v5 epipolar + v6 FoE (combined, debounced, disputed-aware)",
        "v7 severity: encroachment_ratio_v7 (shadow/occlusion-corrected road-span overlap), car_lane_position at curb/in lane",
        "v8 NEW: once STATIONARY (flagged), classify the STOP EVENT, not just the car -- see demo_scan_v8.py header",
        "  TRAFFIC_STOPPED = resumed sustained motion afterward, OR most nearby cars (same ground-row band) are also stopped",
        "  PARKED = reached end of track, still flagged, never resumed, neighbors mostly moving -- 'PARKED?' live = tentative, not yet confirmed",
        "  UNRESOLVED = track ended before enough resumption/neighbor evidence either way (occluded, left frame, too little nearby traffic)",
        "neighbor = another tracked car within NEIGHBOR_ROW_BAND_PX ground-row distance (a depth proxy, not lateral lane-aware)",
        "EXPERIMENTAL: v8's stop-event classifier is a first rule-based baseline, not validated against a labeled set -- see SESSION_LOG_V8.md",
    ]
    y = frame.shape[0] - 15 - (len(lines) - 1) * 16
    for line in lines:
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(frame, line, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (255, 255, 255), 1, cv2.LINE_AA)
        y += 16


def main():
    parser = argparse.ArgumentParser(description="v8 demo: v5+v6+v7 stack plus parked-vs-traffic-stopped stop-event classification.")
    parser.add_argument("--input", default="../0b21d2708d72b821bec4c81a42d46e92.mp4")
    parser.add_argument("--output", default="demo_scan_output_v8.mp4")
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
    resumption_debounce_frames = max(1, int(round(RESUMPTION_DEBOUNCE_SECONDS * fps)))
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

    # v8 new per-track state for stop-event classification.
    ever_flagged = defaultdict(bool)
    post_flag_moving_streak = defaultdict(int)
    resumed_after_flagged = defaultdict(bool)
    neighbor_ratio_samples = defaultdict(list)  # collected only while flagged, same as severity's own convention

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

        # ---- PASS 1: update each car's own motion state (unchanged from v6) and record enough
        # per-car data (ground row, combined state) for the v8 neighbor-synchrony pass below,
        # which needs EVERY car's state in this frame before it can compute any one car's ratio. ----
        frame_records = []
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

            # v8 resumption tracking: only meaningful once a track has been flagged at least once.
            # A sustained "moving" streak AFTER that point is a genuine resumption; anything before
            # the first flag isn't relevant (the car hasn't been called stopped yet).
            if ever_flagged[track_id]:
                if combined == "moving":
                    post_flag_moving_streak[track_id] += 1
                    if post_flag_moving_streak[track_id] >= resumption_debounce_frames:
                        resumed_after_flagged[track_id] = True
                else:
                    post_flag_moving_streak[track_id] = 0

            ground_row = ema_ground_point[1]
            # Computed for EVERY car (not just stationary ones) because the neighbor-synchrony
            # ratio needs the full population of "in_lane" cars nearby -- including ones currently
            # MOVING -- to form a correct denominator ("of the traffic sharing this lane, how much
            # is stopped"), not just a count of already-stopped neighbors with no base rate.
            lane_position = v5.car_lane_position((x1, y1, x2, y2), mask_bool, road_mask)
            frame_records.append({
                "track_id": track_id, "box": (x1, y1, x2, y2), "polygon": polygon, "mask_bool": mask_bool,
                "ema_ground_point": ema_ground_point, "ground_row": ground_row, "lane_position": lane_position,
                "combined": combined, "flagged": flagged, "epi_state": epi_state[track_id], "foe_state": foe_state[track_id],
            })

        # ---- PASS 2: neighbor-synchrony (needs every car's state from pass 1) + drawing ----
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

            if polygon is not None and len(polygon) > 0:
                cv2.polylines(frame, [polygon.astype(np.int32)], isClosed=True, color=color, thickness=2)
            else:
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            gp_x, gp_y = rec["ema_ground_point"]
            cv2.circle(frame, (int(gp_x), int(gp_y)), 4, color, -1)

            agree = rec["epi_state"] == rec["foe_state"]
            sub_color = color if agree else (0, 0, 255)
            # Short label by design: this used to spell out every field ("car#8 STATIONARY
            # (flagged) | 100% blocked | at curb | PARKED? (nbr=23%)") and became unreadable --
            # overlapping and running off-frame -- the moment 3+ stationary cars clustered
            # together (e.g. a curbside row). Abbreviated tokens + dropping the epi/foe detail
            # line when it agrees with the main state (the common case) cuts both the text width
            # and the number of separate label boxes place_label has to stack per car.
            short_status = {"STATIONARY (flagged)": "FLAGGED", "DISPUTED (epi/foe disagree)": "DISPUTED"}.get(status, status)
            label = f"#{track_id} {short_status}"

            if combined == "stationary":
                severity, _corrected_sides = encroachment_ratio_v7((x1, y1, x2, y2), mask_bool, road_mask)
                if severity is not None:
                    severity_samples[track_id].append(severity)
                    label += f" {severity*100:.0f}%blk"
                    if severity > 0.8 and os.environ.get("DEBUG_SEVERITY"):
                        print(f"DEBUG_HIGH_SEV t={frame_idx/fps:.2f} car#{track_id} severity={severity:.3f} sides={_corrected_sides} box=({x1},{y1},{x2},{y2})", file=sys.stderr)
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

            v5.place_label(frame, placed_label_rects, x1, max(12, y1 - 6), label, color, font_scale=0.48, thickness=2)
            if not agree:
                detail = f"epi:{rec['epi_state']} foe:{rec['foe_state']}"
                v5.place_label(frame, placed_label_rects, x1, max(12, y1 - 6) + 16, detail, sub_color, font_scale=0.4, thickness=1)

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

        # v8 final, authoritative stop-event classification -- uses the FULL observation window,
        # unlike the live per-frame label which can only guess with what's been seen so far.
        stop_class_str = ""
        if ever_flagged[track_id]:
            n_samples = neighbor_ratio_samples.get(track_id)
            mean_n_ratio = np.mean(n_samples) if n_samples else None
            min_stationary_frames_for_parked = flag_after_frames + int(round(MIN_EXTRA_STATIONARY_SECONDS_FOR_PARKED * fps))
            observed_long_enough = stats["frames_stationary"] >= min_stationary_frames_for_parked
            if resumed_after_flagged[track_id]:
                stop_class = "TRAFFIC_STOPPED (resumed)"
            elif mean_n_ratio is not None and mean_n_ratio >= NEIGHBOR_RATIO_TRAFFIC_THRESHOLD:
                stop_class = f"TRAFFIC_STOPPED (neighbor sync {mean_n_ratio*100:.0f}%)"
            elif observed_long_enough:
                stop_class = "PARKED"
            else:
                stop_class = "UNRESOLVED"
            nratio_str = f", mean neighbor-stop-ratio {mean_n_ratio*100:.0f}% (n={len(n_samples)})" if n_samples else ", no neighbor data"
            stop_class_str = f", STOP_CLASS={stop_class}{nratio_str}"

        print(
            f"  car#{track_id}: seen {n} frames ({first_s:.1f}s - {last_s:.1f}s), "
            f"combined {pct_stationary:.0f}% stationary / {pct_uncertain:.0f}% uncertain "
            f"(epi {pct_epi_stat:.0f}% stat, foe {pct_foe_stat:.0f}% stat, "
            f"{aborted} stationary-candidacy aborted before debounce committed{disputed_str}){sev_str}{stop_class_str}"
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
