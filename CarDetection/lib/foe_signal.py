"""
v6 core signal: Focus-of-Expansion (FoE) angle + magnitude likelihood, adapted from
Ogawa, An & Yamashita, "Moving Object Detection from Moving Camera Using Focus of Expansion
Likelihood and Segmentation" (FoELS), arXiv:2507.13628 (2025).

WHY THIS EXISTS (see ../ALGORITHMS_EXPLAINED.md section 6.6 and the v6 chat discussion): v5's
epipolar/fundamental-matrix residual fixed the near-field false-positive problem but regressed
far-field detection speed, and -- like every method in this project -- cannot distinguish a car
moving at the ego vehicle's own speed/direction from a parked one (zero relative motion is zero
relative motion, no matter how the measurement is taken). FoELS is a DIFFERENT mechanism, not a
repeat of v3's reverted direction-consistency attempt:

- v3 checked whether a homography-projected residual VECTOR stayed pointing the same direction
  across SEVERAL FRAMES. A fitted-plane homography's approximation error drifts smoothly near the
  camera as the ego vehicle continues forward, which can fake that kind of multi-frame
  consistency -- this is exactly why v3's attempt regressed the near-field case.
- FoELS instead recomputes a genuine Focus-of-Expansion point FRESH EVERY FRAME from real
  background optical flow (via RANSAC line-intersection, no plane-fitting at all), then checks,
  WITHIN A SINGLE FRAME, whether each point's own flow direction radiates away from that FoE the
  way a static point's would. This is a purely geometric, non-temporal check -- it has no analog
  to the specific failure that broke v3.
- FoELS's own paper found angle alone insufficient for parallel/co-moving motion (their
  Contribution 3) and added a flow-MAGNITUDE check on top, comparing a point's flow speed against
  the local static-region average. This directly targets (though does not fully solve -- see
  below) this project's "convoy ambiguity."

WHAT THIS STILL CANNOT FIX: for an object matching the ego vehicle's velocity EXACTLY (same speed,
same direction), its true relative velocity to the camera is zero, so its optical flow is
IDENTICAL in both angle and magnitude to a static point at that location -- there is no signal
left to detect, by the same physics that limits every method in this project. FoELS's magnitude
check helps for NEARLY-parallel traffic (a car pacing you but drifting slightly faster/slower),
not the literal zero-crossing case.

ADAPTATION NOTE: the source paper computes this over a DENSE per-pixel optical-flow field
(RAFT/UniMatch-family) plus a full panoptic-segmentation prior (OneFormer). This project reuses
its own already-proven SPARSE point-tracking infrastructure instead (the same
goodFeaturesToTrack + calcOpticalFlowPyrLK pipeline v5 already uses for both the background
fundamental-matrix fit and each car's own whole-mask point set) -- a deliberate scope choice
(cheaper, no new heavy model dependency, reuses tested code) rather than a literal port. The
per-car aggregate here (median P_FoE across a car's own tracked points) plays the same structural
role as v5's median epipolar residual, so it can drop into the exact same smoothing + hysteresis
classification pattern for direct, apples-to-apples comparison.
"""

import cv2
import numpy as np

from car_points import car_point_correspondences

# Module-level so estimate_foe_and_static_flow's 200-pair RANSAC draw advances across frames
# (unseeded default, matches historical CLI behavior) rather than being reset every call --
# pipeline_v13.py's apply_determinism_settings() calls seed_rng() to make the draw sequence
# reproducible under --deterministic. Confirmed via EFFICIENCY_PLAN.md S0b: 5 identical runs of
# IMG_0056 produced a 60%/84% stationary split and a PARKED vs TRAFFIC_STOPPED verdict flip on
# car#1 purely from this being unseeded -- everything else (frame count, depth reading, sign
# zone) was byte-identical across runs.
_rng = np.random.default_rng()


def seed_rng(seed):
    global _rng
    _rng = np.random.default_rng(seed)

# Background FoE estimation: same point budget as v5's fundamental-matrix background fit.
FOE_MAX_FEATURES = 300
FOE_MIN_MATCHES = 20
FOE_MIN_FLOW_MAG_PX = 0.5      # background points with near-zero flow define a degenerate line
                                # (no clear direction) -- excluded before FoE fitting.
FOE_RANSAC_ITERS = 200
FOE_RANSAC_INLIER_THRESHOLD_PX = 3.0   # perpendicular distance from a candidate FoE to a
                                        # background flow line, below which that line "votes" for
                                        # the candidate. Reasoned analog of v5's
                                        # FUNDAMENTAL_RANSAC_THRESHOLD_PX -- not tuned against
                                        # ground truth, same honesty caveat as every threshold in
                                        # this project.

# Per-car point tracking: identical budget/keep-fraction to v5's car_epipolar_residual, so any
# behavioral difference between the two signals traces to the SIGNAL, not the point sampling.
CAR_POINT_MAX_FEATURES = 150
CAR_POINT_MIN_TRACKED = 4
CAR_POINT_KEEP_FRACTION = 0.7

# FoELS's own reported constants (paper section III-H): angle threshold at which P_a reaches
# 0.5, and the weighting factor for the magnitude term. Kept as reported, not re-derived --
# these were empirically set by the paper's authors across DAVIS 2016/FBMS-59/their own traffic
# footage, not re-validated against THIS project's footage. Flagged, not silently trusted.
FOE_ANGLE_THRESHOLD_DEG = 30.0
FOE_MAGNITUDE_ALPHA = 0.25
FOE_MIN_VECTOR_MAG_PX = 0.5     # a point coincident with the FoE, or with ~zero observed flow,
                                 # has an undefined angle -- excluded per-point, not per-frame.


def estimate_foe_and_static_flow(prev_gray, curr_gray, exclude_mask):
    """Fits a Focus-of-Expansion point from masked-background sparse flow, via RANSAC
    line-intersection (FoELS section III-G), not a fitted homography or fundamental matrix --
    this is deliberately a DIFFERENT geometric object from anything in v2-v5. Each background
    point's optical-flow vector, extended as a full line through that point, should pass near
    the FoE if the scene were purely static under ego-translation. Returns
    ((foe_x, foe_y), static_mean_flow_mag_px, k_local_or_None) or None if too few usable
    background correspondences survive.

    `static_mean_flow_mag_px` is FoELS's ||v_P,static|| as published -- a single GLOBAL mean over
    ALL background inliers this frame, used as the fallback magnitude reference.

    `k_local` is this project's own addition, NOT in the source paper (verified directly against
    the paper text, arXiv:2507.13628, before adding this -- it proposes no per-location magnitude
    reference). Under pure ego-translation, a static point's expected flow magnitude scales
    with its own radial distance from the FoE (v_expected ~ k * |p - FoE|), not with the frame-
    wide average -- a car near the image edge (usually close to camera, large expected flow) and
    a car near the FoE (usually far, small expected flow) shouldn't be judged against the same
    number. Confirmed by direct measurement: on a scene where the global reference swung 7x
    (3.5-25px) across one parked car's own window, using this per-location scale instead cut that
    car's wrongly-"moving" rate from 63.4% to 47.5% with no cost to an already-correct case (see
    diagnose_foe_local_magnitude.py and the session log for the full experiment). Fit as
    median(inlier_flow_mag / inlier_distance_to_FoE) over the same RANSAC inlier set --
    median for robustness, since a few near-FoE inliers would have wildly noisy ratios (dividing
    by a small, uncertain distance) and shouldn't be allowed to dominate a mean. Returns None if
    fewer than FOE_MIN_MATCHES inliers have a distance-to-FoE of at least 1px (can't fit a stable
    per-pixel scale from nothing but near-FoE points)."""
    mask = np.where(exclude_mask, 0, 255).astype(np.uint8)
    prev_pts = cv2.goodFeaturesToTrack(prev_gray, maxCorners=FOE_MAX_FEATURES, qualityLevel=0.01, minDistance=10, mask=mask)
    if prev_pts is None or len(prev_pts) < FOE_MIN_MATCHES:
        return None

    curr_pts, status, _ = cv2.calcOpticalFlowPyrLK(prev_gray, curr_gray, prev_pts, None)
    status = status.reshape(-1).astype(bool)
    p1 = prev_pts[status].reshape(-1, 2)
    p2 = curr_pts[status].reshape(-1, 2)
    flow = p2 - p1
    mag = np.linalg.norm(flow, axis=1)
    valid = mag >= FOE_MIN_FLOW_MAG_PX
    p1, flow, mag = p1[valid], flow[valid], mag[valid]
    if len(p1) < FOE_MIN_MATCHES:
        return None

    direction = flow / mag[:, None]
    normal = np.stack([-direction[:, 1], direction[:, 0]], axis=1)   # unit normal to each flow line
    c = np.sum(normal * p1, axis=1)                                   # line: normal . X = c

    n_lines = len(p1)
    idx_pairs = _rng.integers(0, n_lines, size=(FOE_RANSAC_ITERS, 2))
    best_inlier_mask, best_count = None, -1
    for i, j in idx_pairs:
        if i == j:
            continue
        A = np.stack([normal[i], normal[j]])
        b = np.array([c[i], c[j]])
        det = A[0, 0] * A[1, 1] - A[0, 1] * A[1, 0]
        if abs(det) < 1e-9:      # near-parallel pair -- no stable intersection, skip
            continue
        candidate = np.linalg.solve(A, b)
        dist = np.abs(normal @ candidate - c)
        inlier_mask = dist < FOE_RANSAC_INLIER_THRESHOLD_PX
        count = int(inlier_mask.sum())
        if count > best_count:
            best_count, best_inlier_mask = count, inlier_mask

    if best_inlier_mask is None or best_count < FOE_MIN_MATCHES:
        return None

    N, C = normal[best_inlier_mask], c[best_inlier_mask]
    foe, *_ = np.linalg.lstsq(N, C, rcond=None)
    foe_point = (float(foe[0]), float(foe[1]))
    static_mean_flow_mag = float(np.mean(mag[best_inlier_mask]))

    inlier_pts = p1[best_inlier_mask]
    inlier_mags = mag[best_inlier_mask]
    inlier_dists = np.linalg.norm(inlier_pts - np.array(foe_point), axis=1)
    valid_d = inlier_dists >= 1.0
    k_local = float(np.median(inlier_mags[valid_d] / inlier_dists[valid_d])) if int(valid_d.sum()) >= FOE_MIN_MATCHES else None

    return foe_point, static_mean_flow_mag, k_local


def car_flow_points(prev_gray, curr_gray, car_mask_u8):
    """Tracks points inside a car's own segmentation mask, identical mechanics to v5's
    car_epipolar_residual point-tracking (same budget, same worst-30%-by-LK-error drop) but
    returns the raw (point, flow_vector) pairs instead of an epipolar distance -- this function
    is signal-agnostic, the epipolar and FoE signals can both consume its output. Points are
    reported at their PREVIOUS-frame position (flow origin), matching the convention a dense
    optical-flow field associates displacement with its source pixel. Returns (points, flows) as
    Nx2 arrays, or None if too few points survived tracking."""
    corr = car_point_correspondences(prev_gray, curr_gray, car_mask_u8)
    if corr is None:
        return None
    p1, p2 = corr
    return p1, p2 - p1


def car_foe_probability(foe_point, static_mean_flow_mag, points, flows,
                         angle_threshold_deg=FOE_ANGLE_THRESHOLD_DEG,
                         alpha=FOE_MAGNITUDE_ALPHA, k_local=None):
    """FoELS equations (1)-(6): per tracked point, compares its observed flow against what a
    STATIC point at that image location should show, given the frame's fitted FoE --

      P_a  = angle-based moving probability: 0 when the point's flow points exactly radially
             away from the FoE (as a static point's would), rising to 1 as the angular deviation
             reaches 2x the threshold.
      F_l  = magnitude-based factor: |log10(this point's flow magnitude / the expected static
             flow magnitude at this point's own location)| -- FoELS's Contribution 3, added
             specifically because angle alone was found insufficient for parallel/co-moving
             motion (see module docstring).
      P_FoE = clip(P_a + alpha * F_l, 0, 1)

    `k_local`, if given (from estimate_foe_and_static_flow's 3rd return value), uses this
    project's own per-location magnitude reference (k_local * this point's own distance to the
    FoE) instead of the single global static_mean_flow_mag for F_l -- a confirmed, measured
    improvement over the paper's global reference (see estimate_foe_and_static_flow's docstring).
    Falls back to the global reference when k_local is None (not enough well-conditioned
    background inliers to fit it that frame) -- degrade to the paper's original behavior rather
    than guess.

    Returns the MEDIAN P_FoE across the car's own surviving tracked points (the aggregation
    choice this project already uses for the epipolar residual, for direct comparability --
    NOT FoELS's own per-pixel object-level fraction-threshold scheme, which assumes a dense
    per-pixel map this sparse-point adaptation doesn't have). Returns None if too few points have
    a well-defined angle (near-zero vectors excluded) or if static_mean_flow_mag is degenerate."""
    if static_mean_flow_mag is None or static_mean_flow_mag <= 1e-6:
        return None

    foe = np.array(foe_point)
    v_F = points - foe
    v_F_mag = np.linalg.norm(v_F, axis=1)
    v_P_mag = np.linalg.norm(flows, axis=1)
    valid = (v_F_mag >= FOE_MIN_VECTOR_MAG_PX) & (v_P_mag >= FOE_MIN_VECTOR_MAG_PX)
    if int(valid.sum()) < 3:
        return None

    v_F, flow_v, v_F_mag, v_P_mag = v_F[valid], flows[valid], v_F_mag[valid], v_P_mag[valid]

    cos_da = np.sum(v_F * flow_v, axis=1) / (v_F_mag * v_P_mag)
    cos_da = np.clip(cos_da, -1.0, 1.0)
    d_a = np.arccos(cos_da)
    theta_th = np.radians(angle_threshold_deg)
    P_a = np.clip(0.5 * d_a / theta_th, 0.0, 1.0)

    if k_local is not None and k_local > 1e-9:
        expected_mag = np.maximum(k_local * v_F_mag, 1e-6)
    else:
        expected_mag = static_mean_flow_mag
    d_l = np.maximum(v_P_mag / expected_mag, 1e-6)
    F_l = np.abs(np.log10(d_l))

    P_FoE = np.clip(P_a + alpha * F_l, 0.0, 1.0)
    return float(np.median(P_FoE))
