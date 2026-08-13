#!/bin/bash
# Builds the frozen roaddamage-worker onedir bundle with PyInstaller.
#
# Usage: ./build_worker.sh
# Output: dist/roaddamage-worker/  (executable + _internal/ support files)
#
# Xcode's "Stage RoadDamage" run-script build phase copies this directory into
# Contents/Resources/roaddamage-worker/ if present -- see JalanKita Mac.xcodeproj
# and RoadDamageService.resolveWorkerLaunch's tier 1. NOT run automatically as
# part of a normal Xcode build: it takes minutes, needs a venv with torch +
# ultralytics installed, and produces multiple GB. Run it explicitly before
# archiving a build meant to work without a dev Python environment present.
#
# Until this is run, Peninjauan's Stage 0 (the pre-computed dataset) still works
# in a distributed app and Stage 1 ("Unggah foto...") does not -- the interpreter
# ladder simply finds no candidate and reports which paths it tried.
#
# Unlike CarDetection/build_cardetection.sh there is no ~/.cache/torch/hub to
# stage: this worker loads a local .pt via YOLO(str(ckpt)) and never calls
# torch.hub, so there is nothing to download on a first run.
set -euo pipefail
cd "$(dirname "$0")"

# Fail early and legibly rather than 20 minutes into a build that cannot work.
# resolve_checkpoint() is deliberately fatal at worker startup, but a spec whose
# `datas` entry is missing fails inside PyInstaller with a much worse message.
if [ ! -f models/server_trained.pt ]; then
    echo "[build_worker] error: models/server_trained.pt is missing." >&2
    echo "               It is tracked in git -- try 'git checkout -- models/'." >&2
    exit 1
fi
if [ ! -f models/unet_resnet34.pt ]; then
    echo "[build_worker] error: models/unet_resnet34.pt is missing." >&2
    echo "               The extent model (ADR-021). It is tracked in git -- try" >&2
    echo "               'git checkout -- models/', or copy it from" >&2
    echo "               ../../road_seg/runs/unet_resnet34/best.pt (93.4 MB)." >&2
    exit 1
fi
if [ ! -f severity.yaml ]; then
    echo "[build_worker] error: severity.yaml is missing." >&2
    echo "               Re-vendor it WITH severity.py, never separately (CLAUDE.md)." >&2
    exit 1
fi

if [ ! -d .venv ]; then
    echo "[build_worker] no .venv found -- creating one and installing requirements.txt"
    echo "               (its own venv, never PythonWorker's: ultralytics resolves"
    echo "                numpy 2.x and PythonWorker pins numpy<2.1 -- see ADR-016)"
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
else
    source .venv/bin/activate
fi

pip install --quiet "pyinstaller>=6.10"

# Cheap correctness gate before the expensive part: --selftest loads severity.yaml
# and asserts two anchor gradings without importing torch at all, so a bad
# re-vendor of the config is caught in a second rather than after the build.
python3 worker_main.py --selftest

rm -rf build dist
pyinstaller roaddamage_worker.spec --noconfirm

# Stamp the capability contract beside the binary. The app reads this before using the frozen
# worker and skips it, loudly, when it does not match what the app expects.
#
# 🔥 Not bookkeeping — this closes a bug that cost three days of silent wrongness. The launch ladder
# prefers the bundled binary, so a `dist/` from 2026-08-10 kept serving after the extent model and
# the video sampler landed: Stage 1 stopped emitting `extent_pct`, that field is optional by design,
# and the UI simply rendered one number instead of two. Nothing errored. Only video caught it, and
# only because argparse rejects an unknown flag.
CONTRACT=$(.venv/bin/python3 -c 'import worker_main; print(worker_main.WORKER_CONTRACT)')
echo "$CONTRACT" > dist/roaddamage-worker/WORKER_CONTRACT
echo "[build_worker] contract: $CONTRACT"

echo "[build_worker] done: dist/roaddamage-worker/"
du -sh dist/roaddamage-worker

# The frozen binary must answer the same NDJSON contract the dev worker does.
# A build that produces an executable which cannot load its own checkpoint is the
# failure mode this whole file exists to prevent, and it is silent until someone
# archives the app and tries Stage 1 on another machine.
echo "[build_worker] smoke-testing the frozen worker's --selftest"
./dist/roaddamage-worker/roaddamage-worker --selftest
echo "[build_worker] frozen worker resolved its checkpoint and severity.yaml"
