#!/bin/bash
# Builds the frozen pipeline_v13 onedir bundle with PyInstaller.
#
# Usage: ./build_worker.sh
# Output: dist/pipeline_v13/  (executable + _internal/ support files)
#
# Xcode's "Stage pipeline_v13" run-script build phase copies this directory
# into Contents/Resources/pipeline_v13/ if present -- see JalanKita
# Mac.xcodeproj. This script is NOT run automatically as part of a normal
# Xcode build (it takes minutes and needs a Python venv with torch/
# ultralytics installed); run it explicitly before archiving a build meant
# to run without a dev Python environment present.
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
pyinstaller car_detection_worker.spec --noconfirm

echo "[build_worker] done: dist/pipeline_v13/"
du -sh dist/pipeline_v13
