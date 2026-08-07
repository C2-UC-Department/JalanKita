"""
Demo screenshot generator: pipeline_v13.py's actual product-facing output. A full annotated video
is not what a real "is this car illegally parked" app would show as evidence -- one clear photo
per detected-PARKED car is. This takes the MIDDLE frame of each such car's observed span (farthest-
to-nearest -- the project owner's revised choice; an earlier version used the farthest/first frame,
see chat), draws its FINAL verdict (known only once the whole track has been watched) onto that one
frame, and saves it.

Folder layout, one call per source video:

    demo/screenshots/<video_basename>/
        car{track_id:04d}_{STOP_CLASS slug}{_DISTURBANCE}_t{mid_seconds}s.jpg
        _summary.json

_summary.json is the machine-readable version of the same list, for anything downstream that
wants to consume this without re-parsing filenames.
"""

import json
import os
import re

import cv2
import numpy as np

COLOR_DISTURBANCE = (0, 0, 255)     # red -- PARKED AND inside a sign's zone
COLOR_PARKED = (0, 140, 255)        # orange -- PARKED, no zone (still worth showing)
COLOR_TEXT_BG = (0, 0, 0)


def _slug(stop_class):
    return re.sub(r"[^a-zA-Z0-9]+", "-", stop_class).strip("-").upper()


def _draw_bold_label(img, x, y, text, color, font_scale=0.7, thickness=2):
    cv2.putText(img, text, (x, y), cv2.FONT_HERSHEY_SIMPLEX, font_scale, COLOR_TEXT_BG,
                thickness + 3, cv2.LINE_AA)
    cv2.putText(img, text, (x, y), cv2.FONT_HERSHEY_SIMPLEX, font_scale, color, thickness, cv2.LINE_AA)


def write_screenshots(input_video, output_video, frame_cache, candidate_frame_box, demo_candidates,
                      out_dir=None):
    """
    demo_candidates: list of (track_id, stop_class, in_zone, depth_txt, mid_frame_idx, mid_seconds)
    -- mid_frame_idx/mid_seconds is the MIDDLE of the track's observed span (farthest-to-nearest),
    chosen by the caller (pipeline_v13.py), not necessarily this car's actual first-seen frame.
    Only ever called with PARKED-ish candidates (filtered by the caller) -- this function doesn't
    re-check STOP_CLASS, it trusts what it's given.

    out_dir: override for where screenshots land (JalanKita Mac passes its own session working
    directory here so the Swift side has a predictable path to read from). Defaults to this
    repo's own demo/screenshots/<video>/ for standalone CLI use.

    Writes TWO images per candidate: an annotated one (box + label burned in, for human review --
    unchanged from before) and a CLEAN one (no overlay at all). The clean one exists because
    OFRSNet (JalanKita's disturbance model) reads this same frame with its own Mask2Former/
    Depth-Anything segmentation -- a solid burned-in box + text is a much stronger artifact than
    the 15% road-overlay tint that was found to corrupt this project's own depth model (see
    docs/CHANGELOG_V12_TO_V13.md), sitting right at the vehicle boundary that OFRSNet's per-vehicle
    attribution most needs to read cleanly. Never hand OFRSNet the annotated version.
    """
    video_name = os.path.splitext(os.path.basename(input_video))[0]
    if out_dir is None:
        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo", "screenshots", video_name)
    os.makedirs(out_dir, exist_ok=True)

    summary = []
    for track_id, stop_class, in_zone, depth_txt, mid_frame_idx, mid_seconds in demo_candidates:
        raw = frame_cache.get(mid_frame_idx)
        box = candidate_frame_box.get(track_id)
        if raw is None or box is None:
            continue
        clean_img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        img = clean_img.copy()
        x1, y1, x2, y2 = box
        color = COLOR_DISTURBANCE if in_zone else COLOR_PARKED
        cv2.rectangle(img, (x1, y1), (x2, y2), color, 3)

        tag = "DISTURBANCE" if in_zone else "PARKED"
        _draw_bold_label(img, x1, max(28, y1 - 42), f"#{track_id} {tag}", color, font_scale=0.8, thickness=2)
        _draw_bold_label(img, x1, max(28, y1 - 42) + 26, f"STOP_CLASS={stop_class}  depth={depth_txt}",
                         (255, 255, 255), font_scale=0.5, thickness=1)

        stem = f"car{track_id:04d}_{_slug(stop_class)}{'_DISTURBANCE' if in_zone else ''}_t{mid_seconds:.1f}s"
        fname = f"{stem}.jpg"
        fname_clean = f"{stem}_clean.jpg"
        cv2.imwrite(os.path.join(out_dir, fname), img)
        cv2.imwrite(os.path.join(out_dir, fname_clean), clean_img)
        summary.append({
            "track_id": int(track_id), "stop_class": stop_class, "disturbance": bool(in_zone),
            "depth_reading": depth_txt, "mid_frame": int(mid_frame_idx),
            "mid_seconds": round(float(mid_seconds), 1), "file": fname, "file_clean": fname_clean,
        })

    with open(os.path.join(out_dir, "_summary.json"), "w") as f:
        json.dump({"source_video": os.path.basename(input_video),
                   "output_video": os.path.basename(output_video),
                   "cars_detected_parked": summary}, f, indent=2)

    print(f"\nWrote {len(summary)} demo screenshot(s) (+ clean variants) to {out_dir}")
