#!/usr/bin/env python3
"""
Records one or more pipeline_v13.py runs into baselines/<label>/<clip>/ for later comparison
by compare_runs.py -- see ../EFFICIENCY_PLAN.md Section 6.

Never imported by pipeline_v13.py itself (per the plan's explicit constraint): this is an
external harness that shells out to the real CLI, exactly as the Mac app does, so what gets
compared is the actual product behavior, not some import-level shortcut that could diverge
from it.

Usage:
    # Record one full baseline across all 4 ground-truth clips:
    record_run.py --label s0-seeded

    # Self-test: run ONE clip N times, to measure run-to-run determinism (S0b):
    record_run.py --clip IMG_0056 --repeat 5 --label determinism-check

Each run's captured artifacts land in:
    baselines/<label>/<clip_label>/run<N>/
        stdout.txt   stderr.txt   summary.json  (never-null: {} if the real file was absent)
        debug.json   (only if pipeline_v13.py was given --debug-json; absent otherwise)
        hashes.json  (sha256 of the annotated mp4, sha256 of every jpg in --screenshot-dir)
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tomllib

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
CARDETECTION_DIR = os.path.dirname(TOOLS_DIR)
PYTHON = os.path.join(CARDETECTION_DIR, ".venv", "bin", "python3")
PIPELINE = os.path.join(CARDETECTION_DIR, "pipeline_v13.py")
BASELINES_DIR = os.path.join(TOOLS_DIR, "baselines")


def load_clips():
    with open(os.path.join(TOOLS_DIR, "clips.toml"), "rb") as f:
        data = tomllib.load(f)
    return {c["label"]: c for c in data["clip"]}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_once(clip, out_dir, with_debug_json, mps_heavy=False):
    os.makedirs(out_dir, exist_ok=True)
    mp4_path = os.path.join(out_dir, "annotated.mp4")
    screenshot_dir = os.path.join(out_dir, "screenshots")
    debug_json_path = os.path.join(out_dir, "debug.json")

    cmd = [
        PYTHON, PIPELINE,
        "--input", clip["path"],
        "--output", mp4_path,
        "--screenshot-dir", screenshot_dir,
        "--deterministic",
    ]
    # --debug-json is added by S0d. Until that lands, pipeline_v13.py rejects unknown flags --
    # callers of this tool before S0d must omit --with-debug-json.
    if with_debug_json:
        cmd += ["--debug-json", debug_json_path]
    if mps_heavy:
        cmd += ["--mps-heavy-models"]

    result = subprocess.run(cmd, capture_output=True, text=True)

    with open(os.path.join(out_dir, "stdout.txt"), "w") as f:
        f.write(result.stdout)
    with open(os.path.join(out_dir, "stderr.txt"), "w") as f:
        f.write(result.stderr)
    with open(os.path.join(out_dir, "cmd.txt"), "w") as f:
        f.write(" ".join(cmd) + f"\nexit={result.returncode}\n")

    # _summary.json is written ONLY if >=1 car reached a PARKED-family verdict (pipeline_v13.py's
    # own guard: `if demo_candidates:`). Absent is the NORMAL case on 3 of the 4 ground-truth
    # clips -- treat it as an empty result, not an error, exactly like the Swift side does
    # (CarDetectionWorkerProcess.swift's own comment on this).
    summary_path = os.path.join(screenshot_dir, "_summary.json")
    if os.path.exists(summary_path):
        with open(summary_path) as f:
            summary = json.load(f)
    else:
        summary = {"source_video": os.path.basename(clip["path"]),
                   "output_video": os.path.basename(mp4_path), "cars_detected_parked": []}
    with open(os.path.join(out_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)

    hashes = {"exit_code": result.returncode}
    if os.path.exists(mp4_path):
        hashes["annotated_mp4"] = sha256_file(mp4_path)
    jpg_hashes = {}
    if os.path.isdir(screenshot_dir):
        for fname in sorted(os.listdir(screenshot_dir)):
            if fname.endswith(".jpg"):
                jpg_hashes[fname] = sha256_file(os.path.join(screenshot_dir, fname))
    hashes["screenshots"] = jpg_hashes
    with open(os.path.join(out_dir, "hashes.json"), "w") as f:
        json.dump(hashes, f, indent=2)

    return result.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True, help="baseline directory name under tools/baselines/")
    ap.add_argument("--clip", default=None,
                     help="run only this one clip (by label from clips.toml); default: all 4")
    ap.add_argument("--repeat", type=int, default=1,
                     help="run the same clip this many times, into run0/run1/... (for the S0b "
                          "determinism self-test; only valid with --clip)")
    ap.add_argument("--with-debug-json", action="store_true",
                     help="pass --debug-json to pipeline_v13.py (only valid after S0d lands)")
    ap.add_argument("--mps-heavy", action="store_true",
                     help="pass --mps-heavy-models to pipeline_v13.py (EFFICIENCY_PLAN.md 8.13-8.14; "
                          "NOT bit-identical, T0 must be checked, not assumed)")
    ap.add_argument("--assert-identical", action="store_true",
                     help="after recording --repeat runs, fail loudly if hashes.json/summary.json "
                          "differ between any two runs")
    args = ap.parse_args()

    if args.repeat > 1 and not args.clip:
        sys.exit("--repeat requires --clip (repeating all 4 clips is not what S0b needs)")

    clips = load_clips()
    targets = [clips[args.clip]] if args.clip else list(clips.values())

    label_dir = os.path.join(BASELINES_DIR, args.label)
    all_ok = True
    for clip in targets:
        actual_sha = sha256_file(clip["path"]) if os.path.exists(clip["path"]) else None
        if actual_sha != clip["sha256"]:
            print(f"WARNING: {clip['label']} sha256 mismatch vs clips.toml "
                  f"(got {actual_sha}, expected {clip['sha256']}) -- clip file may have changed",
                  file=sys.stderr)

        clip_dir = os.path.join(label_dir, clip["label"])
        n_runs = args.repeat if args.clip else 1
        for i in range(n_runs):
            run_dir = os.path.join(clip_dir, f"run{i}")
            print(f"[{clip['label']}] run{i} -> {run_dir}", file=sys.stderr)
            rc = run_once(clip, run_dir, args.with_debug_json, args.mps_heavy)
            if rc != 0:
                all_ok = False
                print(f"  exit code {rc} -- see {run_dir}/stderr.txt", file=sys.stderr)

    if args.assert_identical:
        clip_dir = os.path.join(label_dir, args.clip)
        run_dirs = sorted(
            d for d in os.listdir(clip_dir) if d.startswith("run")
        )
        ref = None
        mismatches = []
        for d in run_dirs:
            with open(os.path.join(clip_dir, d, "hashes.json")) as f:
                h = json.load(f)
            with open(os.path.join(clip_dir, d, "summary.json")) as f:
                s = json.load(f)
            fingerprint = (h.get("annotated_mp4"), h.get("screenshots"), s.get("cars_detected_parked"))
            if ref is None:
                ref = (d, fingerprint)
            elif fingerprint != ref[1]:
                mismatches.append(d)
        if mismatches:
            print(f"\nNOT IDENTICAL: {ref[0]} differs from {mismatches} "
                  f"({len(mismatches)}/{len(run_dirs)-1} other runs)", file=sys.stderr)
            sys.exit(1)
        else:
            print(f"\nIDENTICAL across all {len(run_dirs)} runs of {args.clip}.", file=sys.stderr)

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
