#!/bin/bash
# Builds the frozen disturbance-worker onedir bundle with PyInstaller.
#
# Usage: ./build_worker.sh
# Output: dist/disturbance-worker/  (executable + _internal/ support files)
#
# Xcode's "Stage disturbance-worker" run-script build phase copies this
# directory into Contents/Resources/disturbance-worker/ if present -- see
# JalanKita Mac.xcodeproj. This script is NOT run automatically as part of
# a normal Xcode build (it takes minutes and needs a Python venv with
# torch/transformers installed); run it explicitly before archiving a build
# meant to run without a dev Python environment present.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
    echo "[build_worker] no .venv found -- creating one and installing requirements.txt"
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
else
    source .venv/bin/activate
fi

rm -rf build dist
pyinstaller disturbance_worker.spec --noconfirm

echo "[build_worker] done: dist/disturbance-worker/"
du -sh dist/disturbance-worker
