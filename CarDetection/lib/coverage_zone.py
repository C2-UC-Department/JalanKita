"""
v10: heuristic "coverage corridor" for a resolved sign_P/sign_S track -- how far along the curb
the sign's restriction plausibly extends, drawn as an overlay so a viewer can see which parked
cars fall inside it.

WHY THIS IS A HEURISTIC, NOT A MEASUREMENT (full research trail in SESSION_LOG_V10.md):

- Neither test video's sign has a supplementary distance/arrow plate (papan tambahan) -- checked
  directly, close-up, on every confident detection frame. There is no printed distance to read.
- Direct research for a default Indonesian regulatory distance for a BARE sign (no plate) did not
  find a citable primary source. PP 34/2006 pasal 34-36 gives fixed distances for GENERAL
  no-parking zones near specific features (6m from intersections, 9m from bus stops, 3m from fire
  hydrants), but that governs where parking is banned near a LANDMARK, not how far a specific
  installed SIGN's own effect reaches -- a different question. A "15 meters" figure recurred
  across several secondary consumer/dealership articles, surfaced via Google's AI-generated search
  summaries -- but WebFetch-ing the actual pages it was attributed to (auto2000.co.id,
  infobekasi.co.id, kursusmengemudi.id, and a real gov.id dishub page) found NO such figure in any
  of their real text. Treated as an unconfirmed, likely search-summary fabrication -- the same
  failure mode this project was already burned by once (v6/SESSION_LOG_V6.md's PDF-summarizer
  incident) -- and NOT used as a cited fact anywhere below.
- The one thing that WAS corroborated, both in Permenhub 13/2014 Pasal 1's definition of papan
  tambahan and consistently across every secondary source that discussed it: when a distance IS
  specified, it runs in the direction of traffic from the sign ("...disesuaikan dengan arah lalu
  lintas"). Since neither clip's sign has a plate, this module assumes the same default direction
  -- forward, the way the dashcam is already driving.

ZONE_LENGTH_M below is therefore an explicitly labeled, arbitrary illustrative default -- NOT a
legal citation -- chosen only so the demo has something concrete to draw. Swap it for a real
number the moment you have one.

METRIC SCALE: converts ZONE_LENGTH_M to pixels using a KNOWN-OBJECT-SIZE PRIOR (a nearby car's own
detected width at a comparable image row, assumed ASSUMED_CAR_WIDTH_M wide) -- the same crude,
no-calibration-needed approach named as candidate #2 in v9/FOCUS_stopped_or_moving.md sec 5b, with
the same named ~10-15% variance risk (sedan vs SUV vs MPV width differences). If no reference car
is visible near the sign's row, the corridor is drawn using an arbitrary fraction of the local
road width instead, with NO meter claim, and the caller is told `metric=False` so it can label the
overlay accordingly.

GEOMETRY: walks the road mask's curb-side edge row by row from the sign's own base in BOTH
directions (see `sign_coverage_zone`'s own docstring for why a one-directional "toward the
horizon only" walk was tried first and abandoned -- it failed on most real frames because a
still-distant sign's own row sits above the entire currently-visible road mask, leaving nowhere
to walk). This follows the actual curb curvature instead of drawing a naive flat rectangle,
and naturally truncates wherever the road mask runs out of data (occlusion, a tree, the frame
edge) rather than extrapolating past what's actually visible -- consistent with this project's
existing road-geometry modules (v5/v7), which also refuse to fabricate past what a given frame's
segmentation actually shows.
"""

import numpy as np

ASSUMED_CAR_WIDTH_M = 1.8
ZONE_LENGTH_M = 15.0  # unverified illustrative default -- see module docstring
ROW_STEP = 4
MAX_ROW_SEARCH = 400          # how far below/above a reference row to search for road-mask data
ROW_MATCH_TOLERANCE = 150     # max row distance for a reference car to be trusted as same-depth
# How wide (in meters) to draw the curb strip itself, OUTWARD from the drivable-area edge --
# i.e. away from the road, into the parking/shoulder strip where a curb-parked car actually
# sits. Corrected after direct testing found the strip drawn INWARD (into the drivable lane)
# never overlapped real curb-parked cars' ground points at all: YOLOP's drivable-area mask does
# not count the curb/parking strip as drivable (the same fact v7's encroachment_ratio already
# documented), so a curb-parked car's ground-contact point sits on the far side of the drivable
# edge from the road, not inside it. ~3m approximates one parallel-parking lane's width.
CURB_STRIP_WIDTH_M = 3.0
CURB_STRIP_WIDTH_FALLBACK_FRACTION = 0.25  # used only when no reference car gives a px/m scale


def mask_span_at_row(mask_bool, row):
    row = min(max(int(row), 0), mask_bool.shape[0] - 1)
    cols = np.where(mask_bool[row])[0]
    if len(cols) == 0:
        return None
    return int(cols.min()), int(cols.max())


def mask_max_width_span(mask_bool):
    """Widest row of a mask -- used ONLY for the calibration reference (a car's real width),
    NOT the ground-contact row v5/v7 use for the severity/lane-position metrics. Confirmed by
    direct testing this distinction matters: a car's mask at its exact bottom (ground-contact)
    row is frequently a narrow sliver (a corner or the point where the silhouette tapers to the
    ground at an angle) rather than the car's true broadside width -- one real case measured only
    12px at the ground row for a car that was ~121px wide at its box, which fed a wildly wrong
    local px-per-meter scale into `local_px_per_meter`. The widest row of the mask is a much more
    reliable stand-in for "how wide is this car, really", independent of viewing angle quirks at
    its very lowest pixel."""
    rows_with_data = np.where(mask_bool.any(axis=1))[0]
    if len(rows_with_data) == 0:
        return None
    best_span, best_width = None, -1
    for row in rows_with_data:
        cols = np.where(mask_bool[row])[0]
        width = cols[-1] - cols[0]
        if width > best_width:
            best_width, best_span = width, (int(cols[0]), int(cols[-1]))
    return best_span


def _nearest_road_row_with_data(road_bool, start_row):
    """Road masks are frequently empty right at a sign's own box (signs are mounted above the
    road, not on it). Searches outward from start_row (both directions) for the nearest row
    that actually has drivable-area pixels, rather than silently returning nothing."""
    h = road_bool.shape[0]
    start_row = min(max(int(start_row), 0), h - 1)
    if mask_span_at_row(road_bool, start_row) is not None:
        return start_row
    for offset in range(ROW_STEP, MAX_ROW_SEARCH, ROW_STEP):
        for row in (start_row + offset, start_row - offset):
            if 0 <= row < h and mask_span_at_row(road_bool, row) is not None:
                return row
    return None


def local_px_per_meter(cars_in_frame, reference_row, row_tolerance=ROW_MATCH_TOLERANCE):
    """cars_in_frame: list of (left_px, right_px, ground_row). Picks whichever car's ground_row
    is closest to reference_row (most likely at a similar depth to the sign) and returns its
    pixel width / ASSUMED_CAR_WIDTH_M. None if no car is within row_tolerance rows -- too big a
    depth mismatch between a candidate reference car and the sign to trust as a local scale."""
    best = None
    for left, right, row in cars_in_frame:
        width_px = right - left
        if width_px <= 0:
            continue
        row_dist = abs(row - reference_row)
        if row_dist > row_tolerance:
            continue
        if best is None or row_dist < best[0]:
            best = (row_dist, width_px)
    if best is None:
        return None
    return best[1] / ASSUMED_CAR_WIDTH_M


def _walk_curb(road_bool, side, start_row, start_span, row_delta, target_len):
    """Walks the curb-side edge of the road mask row by row from start_row in ONE direction
    (row_delta = -ROW_STEP toward the horizon / +ROW_STEP toward the camera), accumulating
    (x, row) points and Euclidean arc length, until target_len is reached or the road mask runs
    out of data. Returns (points, reached_length) -- points is empty if the very first step off
    start_row already has no data (the caller decides what an empty result means)."""
    points = []
    prev_left, prev_right = start_span
    row = start_row
    cum_len = 0.0
    first = True
    while 0 <= row < road_bool.shape[0] and cum_len < target_len:
        span = mask_span_at_row(road_bool, row)
        if span is None:
            break
        left, right = span
        if right - left <= 0:
            break
        curb_x = left if side == "left" else right
        prev_curb_x = prev_left if side == "left" else prev_right
        step_len = 0.0 if first else float(np.hypot(curb_x - prev_curb_x, abs(row_delta)))
        cum_len += step_len
        points.append((curb_x, row, left, right))
        prev_left, prev_right = left, right
        first = False
        row += row_delta
    return points, cum_len


def sign_coverage_zone(sign_box, road_mask, cars_in_frame, frame_shape):
    """Computes one sign's coverage corridor for the CURRENT frame (recomputed fresh every call,
    no motion prediction -- matches v7's road_completion.py convention of classical single-frame
    geometry only). Returns None if there's no usable road data anywhere near the sign, otherwise
    a dict: side ('left'/'right'), metric (bool), zone_length_m/zone_length_px, and `polygon`, a
    list of (x, y) points outlining the shaded corridor for drawing.

    DIRECTION, revised after direct testing: a strictly one-directional walk "toward the horizon
    only" (the literal reading of "the restriction runs in the direction of travel") was tried
    first and FAILED on most of IMG_0056.MOV's real frames -- confirmed by running it: while the
    sign is still far away, its own projected row sits ABOVE (smaller row than) the ENTIRE
    currently-visible road mask, i.e. `_nearest_road_row_with_data` has to search DOWNWARD to find
    any data at all, landing base_row already at the topmost/most-horizon-ward edge of what's
    segmented -- so a further horizon-ward walk from there has nowhere to go and returns 0-1
    points immediately. That is an expected consequence of single-frame monocular segmentation
    range, not a bug to patch around: a road segmenter simply cannot see arbitrarily far ahead,
    and this project has no ego-motion tracking in this version to accumulate a road-ahead map
    across frames (that whole approach was the v4/v9 detour, explicitly shelved -- see
    car-detection-stay-video-only in memory). FIX: walk BOTH directions from base_row and combine,
    splitting the target length between them. This changes what's actually being drawn from "15m
    strictly ahead of the sign" to "curb near the sign's own depth, extending as far as this
    frame's segmentation allows in either direction" -- a more modest, more honest claim, and it
    is labeled that way in demo_scan_v10.py's on-screen legend, not oversold as directional."""
    road_bool = road_mask == 1
    x1, y1, x2, y2 = sign_box
    sign_cx = (x1 + x2) / 2.0

    base_row = _nearest_road_row_with_data(road_bool, y2)
    if base_row is None:
        return None
    base_span = mask_span_at_row(road_bool, base_row)
    if base_span is None:
        return None
    road_left, road_right = base_span
    road_width = road_right - road_left
    if road_width <= 0:
        return None

    side = "left" if (sign_cx - road_left) <= (road_right - sign_cx) else "right"

    px_per_m = local_px_per_meter(cars_in_frame, base_row)
    if px_per_m is not None:
        zone_length_px = ZONE_LENGTH_M * px_per_m
        metric = True
    else:
        zone_length_px = road_width * 3.0  # arbitrary illustrative reach, no meter claim
        metric = False

    half_target = zone_length_px / 2.0
    up_pts, up_len = _walk_curb(road_bool, side, base_row, (road_left, road_right), -ROW_STEP, half_target)
    down_pts, down_len = _walk_curb(road_bool, side, base_row, (road_left, road_right), ROW_STEP, half_target)
    # give whichever direction ran out of room the leftover budget from the other side, in case
    # one direction is cut short (e.g. by the sign's own pole or a mask gap) well before the other
    if up_len < half_target and down_len >= half_target:
        down_pts, down_len = _walk_curb(road_bool, side, base_row, (road_left, road_right), ROW_STEP, zone_length_px - up_len)
    elif down_len < half_target and up_len >= half_target:
        up_pts, up_len = _walk_curb(road_bool, side, base_row, (road_left, road_right), -ROW_STEP, zone_length_px - down_len)

    # up_pts includes base_row; down_pts also includes base_row (both walks start there) --
    # drop the duplicate before combining, order: farthest-up ... base_row ... farthest-down
    combined = list(reversed(up_pts)) + down_pts[1:]
    if len(combined) < 2:
        return None

    curb_pts, inner_pts = [], []
    for curb_x, row, left, right in combined:
        width = right - left
        strip = (CURB_STRIP_WIDTH_M * px_per_m) if px_per_m is not None else (width * CURB_STRIP_WIDTH_FALLBACK_FRACTION)
        # OUTWARD from the drivable edge -- away from the road, into the parking/shoulder strip
        # where a curb-parked car's ground point actually sits (see CURB_STRIP_WIDTH_M comment).
        inner_x = curb_x - strip if side == "left" else curb_x + strip
        curb_pts.append((curb_x, row))
        inner_pts.append((inner_x, row))

    return {
        "side": side,
        "metric": metric,
        "zone_length_m": ZONE_LENGTH_M if metric else None,
        "zone_length_px": zone_length_px,
        "actual_reach_px": up_len + down_len,
        "base_row": base_row,
        "polygon": curb_pts + inner_pts[::-1],
        "curb_pts": curb_pts,
        "inner_pts": inner_pts,
    }


def point_in_zone(px, py, zone):
    """1D span containment check at py, INTERPOLATED between the two curb/inner samples that
    bracket py -- same convention as v7's encroachment_ratio (a row-matched interval comparison,
    not full polygon point-in-polygon). Snapping to the single nearest sampled row (tried first)
    was NOT precise enough: near the bottom of the frame the curb edge can shift ~100px across a
    single ROW_STEP=4 gap (steep close-up perspective), so two rows equally close to py by row-
    distance can disagree sharply on x -- interpolating removes that discontinuity."""
    curb_pts, inner_pts = (zone or {}).get("curb_pts"), (zone or {}).get("inner_pts")
    if not curb_pts:
        return False
    rows = [p[1] for p in curb_pts]
    if py < min(rows) - ROW_STEP or py > max(rows) + ROW_STEP:
        return False
    for i in range(len(curb_pts) - 1):
        row_a, row_b = curb_pts[i][1], curb_pts[i + 1][1]
        lo_row, hi_row = min(row_a, row_b), max(row_a, row_b)
        if lo_row <= py <= hi_row:
            t = 0.0 if hi_row == lo_row else (py - row_a) / (row_b - row_a)
            curb_x = curb_pts[i][0] + t * (curb_pts[i + 1][0] - curb_pts[i][0])
            inner_x = inner_pts[i][0] + t * (inner_pts[i + 1][0] - inner_pts[i][0])
            lo_x, hi_x = (curb_x, inner_x) if curb_x <= inner_x else (inner_x, curb_x)
            return lo_x <= px <= hi_x
    # py is within ROW_STEP of the nearest endpoint but outside every bracket -- use that endpoint
    idx = 0 if abs(py - rows[0]) < abs(py - rows[-1]) else -1
    curb_x, inner_x = curb_pts[idx][0], inner_pts[idx][0]
    lo_x, hi_x = (curb_x, inner_x) if curb_x <= inner_x else (inner_x, curb_x)
    return lo_x <= px <= hi_x
