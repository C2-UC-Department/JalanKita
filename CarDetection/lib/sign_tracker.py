"""
v10: fixes a confirmed real bug in the v1 fine-tuned sign_P/sign_S model (see
ALGORITHMS_EXPLAINED.md sec 2.2, test mAP50=0.928 on clean Roboflow photos, NOT on real dashcam
footage) -- on real footage it emits TWO overlapping boxes for the same physical sign, one
`sign_P` one `sign_S`, and additionally leans the wrong way on this sign's real angle/lighting a
meaningful fraction of the time.

Investigated in two passes, and the first pass's diagnosis was corrected by the second, more
precise one (documented honestly, not silently fixed up):

1. First pass (a coarse every-5th-frame sample) looked like simple per-frame label flicker on one
   box. Visually confirmed the object itself is unambiguous -- every upscaled crop across the
   sampled frames shows a plain circle-slash-"P" (dilarang parkir) icon, one physical sign, not
   two, since the box position/size progresses smoothly (a car approaching a static roadside
   sign).
2. Second pass (every real frame, not sampled) found the true mechanism: at frames 58/80/90/100,
   `model.predict()` returns BOTH a `sign_P` box AND a `sign_S` box simultaneously, at
   near-identical coordinates (within 1-5px). Ultralytics' NMS is per-class by default
   (`agnostic_nms=False`) -- it only suppresses overlapping boxes of the SAME class, so two
   different classes predicted on the same object never get merged. `agnostic_nms=True` (set in
   `demo_scan_v10.py`'s custom-model call) collapses these into one detection per object per
   frame, keeping whichever class had higher confidence that frame. That fixes the duplicate-box
   artifact, but NOT the underlying per-frame classification error -- with agnostic NMS on,
   IMG_0056.MOV's sign still gets called `sign_S` on a real fraction of frames (confirmed: 21 of
   84 frames, up to conf 0.73), consistent with `sign_S` being the thinner-trained of the two
   classes (160 boxes vs. sign_P's 285 -- see ALGORITHMS_EXPLAINED.md sec 2.2).

FIX for the remaining per-frame error (this module): a sign is static in the world (unlike a car,
it needs no true motion tracking), so a simple greedy IoU frame-to-frame association is enough to
build a track for it -- no Kalman filter, no ByteTrack, no re-identification across occlusion
needed for a first version. Each track accumulates a class-vote count across every frame it's
matched, and its RESOLVED class is whichever received the most votes over the track's whole
visible lifetime -- the same "trust the temporal aggregate, not any single frame" principle this
project already applies to car motion state (v5's residual smoothing/hysteresis) and
neighbor-synchrony (v8/v9).

VERIFIED after building, on real per-frame data (see SESSION_LOG_V10.md for the full run log):
with `agnostic_nms=True` upstream, IMG_0056.MOV's sign consolidates into ONE track spanning frames
43-127 (85 frames), votes {sign_P: 63, sign_S: 21} -- resolves correctly to sign_P. Without
agnostic NMS, the same footage instead splits into two separate, concurrently-alive tracks (one
mostly-P, one mostly-S) because the duplicate boxes are similar enough to self-associate frame to
frame but not similar enough to merge with each other -- both fixes are needed together, neither
alone is sufficient.
"""

from collections import defaultdict


def _box_area(box):
    x1, y1, x2, y2 = box
    return max(0, x2 - x1) * max(0, y2 - y1)


def _iou(box_a, box_b):
    ax1, ay1, ax2, ay2 = box_a
    bx1, by1, bx2, by2 = box_b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0:
        return 0.0
    union = _box_area(box_a) + _box_area(box_b) - inter
    return inter / union if union > 0 else 0.0


class SignTrack:
    def __init__(self, track_id, frame_idx, box, cls_name):
        self.id = track_id
        self.first_frame = frame_idx
        self.last_frame = frame_idx
        self.box = box
        self.best_box = box          # largest-area sighting -- the best geometric read for
        self.best_frame = frame_idx  # coverage-zone math (closest, most head-on view)
        self.best_area = _box_area(box)
        self.votes = defaultdict(int)
        self.votes[cls_name] += 1
        self.missed = 0

    def update(self, frame_idx, box, cls_name):
        self.last_frame = frame_idx
        self.box = box
        self.votes[cls_name] += 1
        self.missed = 0
        area = _box_area(box)
        if area > self.best_area:
            self.best_area = area
            self.best_box = box
            self.best_frame = frame_idx

    @property
    def resolved_class(self):
        return max(self.votes.items(), key=lambda kv: kv[1])[0]

    @property
    def total_votes(self):
        return sum(self.votes.values())


# Low on purpose: real frame-to-frame IoU for a fast-approaching sign can drop well below the
# 0.3-0.5 range typical of car tracking (the sign grows quickly as the vehicle closes distance --
# see module docstring numbers). Verified this doesn't cause false merges in practice on both
# test clips (SESSION_LOG_V10.md) since only one sign is ever in frame at a time here; a scene
# with multiple simultaneous close-together signs could need a tighter value or a fallback
# centroid-distance check, not attempted here since neither test clip needed it.
SIGN_IOU_MATCH_THRESHOLD = 0.05
# How many consecutive frames a track can go unmatched before it's finalized and dropped. Signs
# are momentarily missed sometimes (motion blur, a passing pole/tree occluding it) without
# actually leaving frame.
SIGN_TRACK_MAX_MISSED = 10
# Minimum votes before a track's resolved_class is shown/used -- avoids trusting a single-frame
# first sighting before the majority-vote fix has anything to vote on yet.
SIGN_MIN_VOTES_TO_TRUST = 3


class SignTracker:
    """Greedy IoU tracker + majority-vote class resolution for crosswalk/sign_P/sign_S
    detections. See module docstring for why this exists and what it fixes."""

    def __init__(self, iou_threshold=SIGN_IOU_MATCH_THRESHOLD, max_missed=SIGN_TRACK_MAX_MISSED):
        self.iou_threshold = iou_threshold
        self.max_missed = max_missed
        self.active = {}
        self.finalized = []
        self._next_id = 1

    def update(self, frame_idx, detections):
        """detections: list of (box, cls_name, conf). Returns the list of currently-active
        SignTrack objects after this frame's update (including brand-new ones)."""
        candidates = []
        for det_idx, (box, cls_name, conf) in enumerate(detections):
            for track_id, track in self.active.items():
                iou = _iou(box, track.box)
                if iou >= self.iou_threshold:
                    candidates.append((iou, det_idx, track_id))
        candidates.sort(key=lambda c: -c[0])

        used_dets, used_tracks = set(), set()
        for iou, det_idx, track_id in candidates:
            if det_idx in used_dets or track_id in used_tracks:
                continue
            box, cls_name, conf = detections[det_idx]
            self.active[track_id].update(frame_idx, box, cls_name)
            used_dets.add(det_idx)
            used_tracks.add(track_id)

        matched_this_frame = set(used_tracks)
        for det_idx, (box, cls_name, conf) in enumerate(detections):
            if det_idx in used_dets:
                continue
            track_id = self._next_id
            self._next_id += 1
            self.active[track_id] = SignTrack(track_id, frame_idx, box, cls_name)
            matched_this_frame.add(track_id)

        for track_id in list(self.active.keys()):
            if track_id not in matched_this_frame:
                self.active[track_id].missed += 1
                if self.active[track_id].missed > self.max_missed:
                    self.finalized.append(self.active.pop(track_id))

        return list(self.active.values())

    def finalize_all(self):
        self.finalized.extend(self.active.values())
        self.active = {}
        return self.finalized
