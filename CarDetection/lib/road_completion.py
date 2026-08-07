"""
v7: extends v5's Phase A severity metric (car-width/road-width ratio at the car's ground row)
with a row-band boundary extrapolation, to recover the TRUE road edge when it's truncated by the
measured car's own occlusion.

Confirmed real failure mode (see chat, two independent screenshots: `demo_scan_output_v6_0a8a.mp4`
~t=7s orange SUV "at curb", and `demo_scan_output_v6.mp4` ~t=2s `car#172` "at curb" 63% blocked):
a car parked flush against the true curb leaves no unoccluded road pixel beyond it at its own
ground row (the road mask's edge on that side silently truncates to the car's own near edge,
sometimes with a visible strip of genuinely-unoccluded-but-unsegmented pavement in between too --
this is not purely an occlusion problem, YOLOP also under-segments some visible curbside
pavement). Either way, the same-row edge is untrustworthy on the curb side, understating total
road width and inflating "% blocked".

Inspired by (NOT a port of) two literature results, neither directly adoptable to this project's
monocular phone dashcam (see chat for the full assessment):
  - OFRSNet (Sensors 2019, "Occlusion-Free Road Segmentation Leveraging Semantics for Autonomous
    Vehicles"): predicts occluded road continuation from VISIBLE CONTEXT in the
    same semantic mask via a small trained network. No public code/weights, and needs its own
    "occlusion-free" ground-truth dataset this project doesn't have.
  - Oniga, Nedevschi & Meinecke (ITSC 2008), multi-frame curb persistence map: accumulates curb
    evidence across TIME. Needs stereo 3D reconstruction (a DEM) + vehicle CAN-bus speed/yaw-rate
    sensors for ego-motion compensation -- this project has neither.

This borrows the shared underlying principle both papers rely on -- use context that wasn't
itself occluded to estimate what's hidden -- via classical, monocular, SINGLE-FRAME geometry
instead of a trained network or stereo+sensors: sample the road mask's edge at a small band of
rows BELOW the car (between the car and the ego vehicle -- guaranteed unoccluded by this specific
car, since its own mask doesn't extend that low), fit a simple local linear trend, and evaluate it
at the car's own ground row. Only ever moves an edge OUTWARD (more generous road width), never
inward -- occlusion can only hide road, it can't invent road that isn't there, so a "correction"
that shrinks an already-good measurement would be indefensible.
"""
import numpy as np
from scipy.stats import theilslopes

import demo_scan_v5 as v5  # caller must already have v5's directory on sys.path

# Widened after probe_row_band.py showed the real widening trend (a curbside road edge
# perspective-converging toward the camera) plays out over ~150 ROWS below a car's ground row --
# a first version sampling only 12 rows * 3px = 36px past the car barely moved past the truncated
# start of that trend, which is why it found almost no improvement on the two confirmed cases
# (see chat). This range also reaches into a discontinuous artifact zone near the very bottom of
# the frame (dashboard/hood area -- this project's existing hood-exclusion elsewhere is exactly
# because of this) on some videos, which is why the fit below uses a robust (Theil-Sen) estimator
# instead of ordinary least squares -- a minority of contaminated rows near the bottom shouldn't
# be allowed to swing the whole fit the way a single bad point can swing OLS.
ROAD_EDGE_SAMPLE_ROWS = 40           # candidate rows sampled below the car's ground row
ROAD_EDGE_SAMPLE_STEP_PX = 4         # pixel spacing between sampled rows (40*4 = 160px reach)
ROAD_EDGE_MIN_VALID_SAMPLES = 8      # need at least this many usable rows before trusting a fit
ROAD_EDGE_MAX_RESIDUAL_PX = 25       # reject the fit if it doesn't explain the sampled points this well -- an
                                      # untuned, reasoned threshold, same honesty caveat as every threshold
                                      # in this project.

# Added after a second real false positive on the tree-lined-street video (see chat /
# SESSION_LOG_V7.md part 9): a row of MULTIPLE curb-parked cars produces a jagged, non-monotonic
# left-edge signal below the car of interest (each neighboring car creates its own gap/protrusion
# at a different row, from a DIFFERENT physical edge than the true curb next to THIS car), unlike
# the single clean monotonic trend the mechanism was validated on. Theil-Sen's MEDIAN residual
# alone can't tell these apart -- a first attempt to also cap the MAX residual (tried and reverted
# here) rejected the confirmed-good VW case too, because that case ALSO has a couple of
# still-shadowed samples right next to the car with large individual residuals; a single point-wise
# error bound can't distinguish "mostly one clean trend, with brief expected contamination right at
# the source of the problem" from "not a coherent single trend at all". What actually separates the
# two (verified on both real cases): R-squared. The VW's 40 samples fit a genuine monotonic line
# with R2=0.858; the false-positive case's samples have R2=0.018 -- essentially no linear
# relationship, because the row-band there mixes two DIFFERENT physical edges (the true curb, and a
# separate nearer obstruction) that a single line cannot coherently explain. R2 measures exactly
# the thing this method assumes true (a single, coherent, monotonic edge across the sampled band),
# rather than an arbitrary pixel-distance cutoff.
ROAD_EDGE_MIN_R2 = 0.7

# Gate on WHICH side gets corrected, added after visually verifying the first version against
# real frames (see chat): without this, the extrapolated trend's ordinary fitting noise would
# occasionally land slightly outside the raw measurement on a side that never had an occlusion
# problem at all (e.g. the wide-open side of a mid-lane car), causing a spurious "correction"
# driven by curve-fit noise, not genuine truncation. Only attempt extrapolation on a side where
# the car's own edge sits suspiciously close to the raw road edge already -- actual evidence of
# the failure mode this exists to fix, not just an opportunistic delta.
TRUNCATION_MARGIN_THRESHOLD_PX = 40


def _fit_edge_trend(road_mask, start_row, height_limit, side):
    """Samples the road mask's `side` edge ("left" or "right") at rows start_row, start_row+step,
    ... up to ROAD_EDGE_SAMPLE_ROWS samples (capped at height_limit), fits x = m*y + b with a
    Theil-Sen estimator (median of pairwise slopes) -- robust to the minority of contaminated rows
    that show up near the very bottom of the sampled range on some videos (dashboard/hood
    artifacts), unlike ordinary least squares which a handful of such points can swing badly.
    Returns (slope, intercept) or None if too few valid samples survive, or if the fit doesn't
    explain the sampled points well (median residual > ROAD_EDGE_MAX_RESIDUAL_PX -- e.g. because
    the road curves, forks, or something ELSE occludes those rows too).

    Excludes any sampled row whose edge sits AT the frame boundary (column 0 for the left side,
    width-1 for the right side) -- found via a real false positive on the tree-lined-street video
    (see chat / SESSION_LOG_V7.md part 9): a car clipped by the frame's left edge (box x1=0) had a
    CORRECT raw same-row reading of 0 overlap, but every clean row below it also read left-edge=0,
    because the ego lane there is simply unobstructed all the way to the edge of the CAMERA'S
    FIELD OF VIEW, not because the true road edge is actually at column 0. Fitting a trend through
    those values and extrapolating produced a degenerate flat-zero line, which then "grew" the
    road span all the way to column 0 and wrongly credited the clipped car with 100% overlap. A
    frame-boundary value is censored data (the true edge, if any, is off-frame and unknowable),
    not a measurement of where the road actually ends, so it must not feed the trend fit."""
    rows, edges = [], []
    width_limit = road_mask.shape[1] - 1
    for i in range(ROAD_EDGE_SAMPLE_ROWS):
        row = start_row + i * ROAD_EDGE_SAMPLE_STEP_PX
        if row >= height_limit:
            break
        span = v5.mask_span_at_row(road_mask == 1, row)
        if span is None:
            continue
        edge = span[0] if side == "left" else span[1]
        if edge <= 0 or edge >= width_limit:
            continue
        rows.append(row)
        edges.append(edge)
    if len(rows) < ROAD_EDGE_MIN_VALID_SAMPLES:
        return None
    rows_arr, edges_arr = np.array(rows, dtype=float), np.array(edges, dtype=float)
    slope, intercept, _, _ = theilslopes(edges_arr, rows_arr)
    predicted = slope * rows_arr + intercept
    residuals = np.abs(edges_arr - predicted)
    if np.median(residuals) > ROAD_EDGE_MAX_RESIDUAL_PX:
        return None
    ss_res = np.sum((edges_arr - predicted) ** 2)
    ss_tot = np.sum((edges_arr - np.mean(edges_arr)) ** 2)
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0
    if r2 < ROAD_EDGE_MIN_R2:
        return None
    return slope, intercept


def corrected_road_span(car_box, car_mask_bool, road_mask):
    """Recomputes the road span at the car's ground row (v5.mask_span_at_row's raw result), then,
    ONLY for a side where the car's own edge already sits within TRUNCATION_MARGIN_THRESHOLD_PX of
    the raw road edge (actual evidence of possible truncation, not just any car), tries to
    extrapolate a better edge from unoccluded rows BELOW the car (nearer the ego vehicle -- this
    car's own mask cannot occlude those rows). Only moves an edge OUTWARD. Returns (road_left,
    road_right, corrected_sides) -- corrected_sides names which side(s) were actually adjusted --
    or None if there's no road data at all at the ground row."""
    x1, y1, x2, y2 = car_box
    ground_row = y2 - 1
    height_limit = road_mask.shape[0]
    raw_span = v5.mask_span_at_row(road_mask == 1, ground_row)
    if raw_span is None:
        return None
    road_left, road_right = float(raw_span[0]), float(raw_span[1])
    corrected_sides = set()

    car_span = v5.mask_span_at_row(car_mask_bool, ground_row)
    car_left = car_span[0] if car_span is not None else x1
    car_right = car_span[1] if car_span is not None else x2
    margin_left = car_left - road_left
    margin_right = road_right - car_right

    if margin_left <= TRUNCATION_MARGIN_THRESHOLD_PX:
        fit = _fit_edge_trend(road_mask, y2 + 2, height_limit, "left")
        if fit is not None:
            slope, intercept = fit
            extrapolated_edge = slope * ground_row + intercept
            if extrapolated_edge < road_left:
                road_left = extrapolated_edge
                corrected_sides.add("left")

    if margin_right <= TRUNCATION_MARGIN_THRESHOLD_PX:
        fit = _fit_edge_trend(road_mask, y2 + 2, height_limit, "right")
        if fit is not None:
            slope, intercept = fit
            extrapolated_edge = slope * ground_row + intercept
            if extrapolated_edge > road_right:
                road_right = extrapolated_edge
                corrected_sides.add("right")

    return road_left, road_right, corrected_sides


def phase3a_severity_v7(car_box, car_mask_bool, road_mask):
    """v7's corrected version of v5.phase3a_severity: identical car-width/road-width ratio, but
    road width comes from corrected_road_span() instead of the raw same-row measurement alone.
    Returns (severity_or_None, corrected_sides_set)."""
    result = corrected_road_span(car_box, car_mask_bool, road_mask)
    if result is None:
        return None, set()
    road_left, road_right, corrected_sides = result
    road_width_px = road_right - road_left
    if road_width_px <= 0:
        return None, corrected_sides
    x1, y1, x2, y2 = car_box
    ground_row = y2 - 1
    car_span = v5.mask_span_at_row(car_mask_bool, ground_row)
    car_width_px = (car_span[1] - car_span[0]) if car_span is not None else (x2 - x1)
    return min(1.0, car_width_px / road_width_px), corrected_sides


def encroachment_ratio_v7(car_box, car_mask_bool, road_mask):
    """Combines v5.encroachment_ratio's interval-overlap formulation with corrected_road_span's
    row-band extrapolation, after discovering (see chat / SESSION_LOG_V7.md part 8) that the
    row-band mechanism -- originally built to recover road width truncated by CAR OCCLUSION --
    ALSO fixes a second, unrelated failure mode: a stationary car's own cast shadow, landing
    directly on the pavement at its own ground-contact row, gets misclassified as non-drivable by
    YOLOP (confirmed by inspecting raw pixel brightness: the affected band reads near-black,
    consistent with the camera's auto-exposure crushing the shadowed patch), which truncates
    mask_span_at_row's reading at EXACTLY the row v5.encroachment_ratio queries -- silently making
    an in-lane car read as if it were curb-parked. Rows a few dozen pixels further below the car
    (between it and the ego vehicle, past the shadow's reach) are back in daylight and correctly
    classified, so the same trend-fit-and-extrapolate mechanism recovers the true edge here too,
    for the same reason it recovers occlusion-truncated edges: it never assumes WHY the near row
    was wrong, only that farther, unoccluded/well-lit rows are trustworthy context.

    Verified on the confirmed case (a VW misread as "at curb" on a tree-lined street, dappled
    shade): raw encroachment 0.10 -> corrected 1.00, while every other (genuinely curb-parked) car
    in the SAME frame stayed at 0.00 after the same correction was attempted -- the gate only
    fires where the car's own edge already sits suspiciously close to the raw road edge, so it
    doesn't indiscriminately inflate every car's number.

    Does NOT fix genuine full occlusion (a car with no visible pavement anywhere nearby, or one
    that occupies the entire visible width with nothing beyond it) -- that remains genuinely
    unrecoverable from a single monocular frame, same caveat as corrected_road_span itself.
    Returns (encroachment_ratio_or_None, corrected_sides_set)."""
    result = corrected_road_span(car_box, car_mask_bool, road_mask)
    if result is None:
        return None, set()
    road_left, road_right, corrected_sides = result
    x1, y1, x2, y2 = car_box
    ground_row = y2 - 1
    car_span = v5.mask_span_at_row(car_mask_bool, ground_row)
    car_left, car_right = car_span if car_span is not None else (x1, x2)
    car_width_px = car_right - car_left
    if car_width_px <= 0:
        return None, corrected_sides
    overlap_left = max(car_left, road_left)
    overlap_right = min(car_right, road_right)
    overlap_width = max(0, overlap_right - overlap_left)
    return overlap_width / car_width_px, corrected_sides
