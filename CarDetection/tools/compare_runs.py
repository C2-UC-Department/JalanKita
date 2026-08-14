#!/usr/bin/env python3
"""
Tiered diff between two baselines recorded by record_run.py -- see ../EFFICIENCY_PLAN.md
Section 6 for the tier definitions and why they're tiered at all (short version: _summary.json
is empty on 3 of the 4 ground-truth clips, so comparing only it gives false confidence on 75%
of the corpus -- the stdout per-track table is the real fingerprint on those).

Tiers:
  T0  disturbance/verdict facts: per-car stop_class + disturbance + bbox from summary.json,
      the "N DISTURBANCE(s)" stdout line, sha256 of every *_clean.jpg (what OFRSNet consumes).
      MUST be identical after any step in the efficiency plan. A T0 diff fails the run.
  T1  decision-adjacent: full per-track stdout table (exact integer frames_seen), depth_reading
      strings, "in a sign zone N/M" strings. Shown in the Mac UI. S1/S2/S3 must not touch this
      either; only the deferred MPS step is allowed to.
  T2  display/console only: annotated jpg/mp4 hashes, "mean severity" strings, lane/curb label
      suffixes. Free to change; reported but never fails the run.

Usage:
    compare_runs.py baselines/A baselines/B
    compare_runs.py baselines/A baselines/B --clip IMG_0056

Exit code 0 iff T0 and T1 are identical across every clip compared. T2 differences are reported
but never affect the exit code.
"""
import argparse
import json
import os
import re
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))

DISTURBANCE_LINE_RE = re.compile(r"^\d+ DISTURBANCE\(s\):")
CAR_LINE_RE = re.compile(r"^  car#(\d+): seen (\d+) frames.*")
# "mean severity N% blocked (n=N)" is display-only (T2, per the module docstring) but lives
# inside the same stdout line as the T1 fields -- stripped before T1 comparison so a YOLOP-skip
# step (which changes severity's sample count) doesn't false-fail T1. See EFFICIENCY_PLAN.md 8.20.
SEVERITY_RE = re.compile(r", mean severity \d+% blocked \(n=\d+\)")


def _run_dirs(clip_dir):
    return sorted(d for d in os.listdir(clip_dir) if d.startswith("run")) if os.path.isdir(clip_dir) else []


def _load_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def _load_text(path):
    if not os.path.exists(path):
        return ""
    with open(path) as f:
        return f.read()


def _t0_from_run(run_dir):
    """(cars: sorted list of {track_id, stop_class, disturbance, bbox}, n_disturbances,
    clean_jpg_hashes: {fname: sha256})"""
    summary = _load_json(os.path.join(run_dir, "summary.json"), {"cars_detected_parked": []})
    cars = sorted(
        ({"track_id": c["track_id"], "stop_class": c["stop_class"],
          "disturbance": c["disturbance"], "bbox": c["bbox"]}
         for c in summary.get("cars_detected_parked", [])),
        key=lambda c: c["track_id"],
    )
    stdout = _load_text(os.path.join(run_dir, "stdout.txt"))
    n_disturbances = None
    for line in stdout.splitlines():
        if DISTURBANCE_LINE_RE.match(line):
            n_disturbances = int(line.split()[0])
            break
    hashes = _load_json(os.path.join(run_dir, "hashes.json"), {"screenshots": {}})
    clean_hashes = {k: v for k, v in hashes.get("screenshots", {}).items() if k.endswith("_clean.jpg")}
    return cars, n_disturbances, clean_hashes


def _t1_from_run(run_dir):
    """(car_table_lines: {track_id: stdout line with the T2 severity clause stripped},
    severity_clauses: {track_id: the stripped clause, for T2 reporting}, debug: dict or None)"""
    stdout = _load_text(os.path.join(run_dir, "stdout.txt"))
    lines, severity = {}, {}
    for line in stdout.splitlines():
        m = CAR_LINE_RE.match(line)
        if m:
            tid = int(m.group(1))
            sev_m = SEVERITY_RE.search(line)
            severity[tid] = sev_m.group(0) if sev_m else None
            lines[tid] = SEVERITY_RE.sub("", line)
    debug = _load_json(os.path.join(run_dir, "debug.json"), None)
    return lines, severity, debug


def _t2_from_run(run_dir):
    hashes = _load_json(os.path.join(run_dir, "hashes.json"), {})
    annotated = {k: v for k, v in hashes.get("screenshots", {}).items() if not k.endswith("_clean.jpg")}
    return hashes.get("annotated_mp4"), annotated


def compare_clip(clip_label, dir_a, dir_b):
    """Returns (t0_diffs: [str], t1_diffs: [str], t2_diffs: [str])."""
    t0_diffs, t1_diffs, t2_diffs = [], [], []

    runs_a, runs_b = _run_dirs(dir_a), _run_dirs(dir_b)
    if not runs_a or not runs_b:
        return ([f"{clip_label}: missing runs (A has {len(runs_a)}, B has {len(runs_b)})"], [], [])
    # Compare run0 vs run0 -- multi-run comparison across labels isn't this tool's job (that's
    # record_run.py --assert-identical, for same-label repeat runs).
    run_a, run_b = os.path.join(dir_a, runs_a[0]), os.path.join(dir_b, runs_b[0])

    cars_a, nd_a, clean_a = _t0_from_run(run_a)
    cars_b, nd_b, clean_b = _t0_from_run(run_b)
    if cars_a != cars_b:
        t0_diffs.append(f"{clip_label}: T0 cars_detected_parked differs\n"
                        f"    A: {cars_a}\n    B: {cars_b}")
    if nd_a != nd_b:
        t0_diffs.append(f"{clip_label}: T0 disturbance count differs: A={nd_a} B={nd_b}")
    if clean_a != clean_b:
        only_a = set(clean_a) - set(clean_b)
        only_b = set(clean_b) - set(clean_a)
        changed = {k for k in set(clean_a) & set(clean_b) if clean_a[k] != clean_b[k]}
        t0_diffs.append(f"{clip_label}: T0 *_clean.jpg hashes differ "
                        f"(only in A: {only_a or '{}'}, only in B: {only_b or '{}'}, changed: {changed or '{}'})")

    lines_a, sev_a, debug_a = _t1_from_run(run_a)
    lines_b, sev_b, debug_b = _t1_from_run(run_b)
    if lines_a != lines_b:
        all_ids = sorted(set(lines_a) | set(lines_b))
        for tid in all_ids:
            la, lb = lines_a.get(tid), lines_b.get(tid)
            if la != lb:
                t1_diffs.append(f"{clip_label}: T1 car#{tid} stdout line differs\n    A: {la}\n    B: {lb}")
    if debug_a != debug_b and (debug_a is not None or debug_b is not None):
        t1_diffs.append(f"{clip_label}: T1 debug.json differs (A={'present' if debug_a else 'absent'}, "
                        f"B={'present' if debug_b else 'absent'})")
    if sev_a != sev_b:
        all_ids = sorted(set(sev_a) | set(sev_b))
        for tid in all_ids:
            sa, sb = sev_a.get(tid), sev_b.get(tid)
            if sa != sb:
                t2_diffs.append(f"{clip_label}: T2 car#{tid} severity clause differs (A={sa!r} B={sb!r})")

    mp4_a, ann_a = _t2_from_run(run_a)
    mp4_b, ann_b = _t2_from_run(run_b)
    if mp4_a != mp4_b:
        t2_diffs.append(f"{clip_label}: T2 annotated.mp4 hash differs")
    if ann_a != ann_b:
        t2_diffs.append(f"{clip_label}: T2 annotated screenshot hashes differ")

    return t0_diffs, t1_diffs, t2_diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline_a")
    ap.add_argument("baseline_b")
    ap.add_argument("--clip", default=None, help="compare only this clip label; default: all present in A")
    args = ap.parse_args()

    dir_a = args.baseline_a if os.path.isabs(args.baseline_a) else os.path.join(TOOLS_DIR, args.baseline_a)
    dir_b = args.baseline_b if os.path.isabs(args.baseline_b) else os.path.join(TOOLS_DIR, args.baseline_b)
    if not os.path.isdir(dir_a):
        dir_a = os.path.join(TOOLS_DIR, "baselines", args.baseline_a)
    if not os.path.isdir(dir_b):
        dir_b = os.path.join(TOOLS_DIR, "baselines", args.baseline_b)

    clip_labels = [args.clip] if args.clip else sorted(
        d for d in os.listdir(dir_a) if os.path.isdir(os.path.join(dir_a, d))
    )

    all_t0, all_t1, all_t2 = [], [], []
    for clip_label in clip_labels:
        t0, t1, t2 = compare_clip(clip_label, os.path.join(dir_a, clip_label), os.path.join(dir_b, clip_label))
        all_t0 += t0
        all_t1 += t1
        all_t2 += t2

    print(f"Comparing {dir_a}\n      vs. {dir_b}\n  clips: {clip_labels}\n")

    if all_t0:
        print(f"=== T0 (verdict-breaking) DIFFERENCES -- {len(all_t0)} ===")
        for d in all_t0:
            print(f"  ✗ {d}")
    else:
        print("T0 (verdict): identical ✓")

    if all_t1:
        print(f"\n=== T1 (decision-adjacent) DIFFERENCES -- {len(all_t1)} ===")
        for d in all_t1:
            print(f"  ✗ {d}")
    else:
        print("T1 (decision-adjacent): identical ✓")

    if all_t2:
        print(f"\n=== T2 (display-only) differences -- {len(all_t2)} (not failing) ===")
        for d in all_t2:
            print(f"  · {d}")
    else:
        print("T2 (display-only): identical")

    sys.exit(1 if (all_t0 or all_t1) else 0)


if __name__ == "__main__":
    main()
