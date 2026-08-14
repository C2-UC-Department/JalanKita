"""
EFFICIENCY_PLAN.md S2: shared point-tracking prefix for a car's own segmentation mask, factored
out of v5's car_epipolar_residual and foe_signal's car_flow_points -- both ran byte-identical
goodFeaturesToTrack + calcOpticalFlowPyrLK + worst-30%-by-LK-error drop before diverging, so
pipeline_v13.py's call site can now share ONE call between the epi and FoE branches instead of
tracking the same points twice per car per frame.

EFFICIENCY_PLAN.md 8.27: goodFeaturesToTrack (corner detection) is 82% of a car's LK cost and
scans the FULL frame even though car_mask_u8 only allows candidates inside a small car-sized
box -- cornerMinEigenVal/threshold/NMS are all local operations (small kernel support), so
running them on a crop around the mask's bounding box (padded well past that support radius)
finds the identical candidate set, just ~6x faster. calcOpticalFlowPyrLK is intentionally left
on the FULL prev_gray/curr_gray (untouched) -- its pyramid is sensitive to crop-edge alignment
in a way corner detection isn't, and it's only 18% of the cost anyway, so there's nothing to
gain by risking it.
"""

import cv2
import numpy as np

CAR_POINT_MAX_FEATURES = 150
CAR_POINT_MIN_TRACKED = 4          # below this many surviving tracked points, no reading this frame
CAR_POINT_KEEP_FRACTION = 0.7      # keep the best 70% of tracks by LK error, drop the noisiest 30%
CAR_POINT_CROP_PAD = 32            # px around the mask's bbox; must exceed cornerMinEigenVal/dilate kernel support (~3px) by a wide margin


def _find_prev_pts_cropped(prev_gray, car_mask_u8):
    """Same candidate set as goodFeaturesToTrack(prev_gray, mask=car_mask_u8) but computed on a
    crop around the mask's bounding box -- see module docstring for why this is exact, not an
    approximation. Returns None exactly when the full-frame call would (empty mask, or too few
    candidates -- that second case is left to the caller since it also applies to the
    uncropped path)."""
    x, y, w, h = cv2.boundingRect(car_mask_u8)
    if w == 0 or h == 0:
        return None  # empty mask -- goodFeaturesToTrack would find nothing either

    H, W = prev_gray.shape[:2]
    x0, y0 = max(0, x - CAR_POINT_CROP_PAD), max(0, y - CAR_POINT_CROP_PAD)
    x1, y1 = min(W, x + w + CAR_POINT_CROP_PAD), min(H, y + h + CAR_POINT_CROP_PAD)
    crop_gray = np.ascontiguousarray(prev_gray[y0:y1, x0:x1])
    crop_mask = np.ascontiguousarray(car_mask_u8[y0:y1, x0:x1])

    pts = cv2.goodFeaturesToTrack(crop_gray, maxCorners=CAR_POINT_MAX_FEATURES, qualityLevel=0.01, minDistance=4, mask=crop_mask)
    if pts is None:
        return None
    # x0/y0 are small integers -- exact in float32, so this is an identity, not a rounding step.
    return pts + np.array([x0, y0], dtype=np.float32)


def car_point_correspondences(prev_gray, curr_gray, car_mask_u8):
    """Tracks up to CAR_POINT_MAX_FEATURES points found INSIDE a car's own segmentation mask
    (not its box) from prev_gray to curr_gray, drops the noisiest CAR_POINT_KEEP_FRACTION by LK
    tracking error. Returns (p1, p2) Nx2 arrays (previous-frame position, current-frame
    position) after the keep-filter, or None if too few points were found or survived tracking
    to trust a reading this frame."""
    prev_pts = _find_prev_pts_cropped(prev_gray, car_mask_u8)
    if prev_pts is None or len(prev_pts) < CAR_POINT_MIN_TRACKED:
        return None

    curr_pts, status, err = cv2.calcOpticalFlowPyrLK(prev_gray, curr_gray, prev_pts, None)
    status = status.reshape(-1).astype(bool)
    p1, p2, err = prev_pts[status].reshape(-1, 2), curr_pts[status].reshape(-1, 2), err.reshape(-1)[status]
    if len(p1) < CAR_POINT_MIN_TRACKED:
        return None

    keep_n = max(CAR_POINT_MIN_TRACKED, int(len(err) * CAR_POINT_KEEP_FRACTION))
    keep_idx = np.argsort(err)[:keep_n]
    return p1[keep_idx], p2[keep_idx]
