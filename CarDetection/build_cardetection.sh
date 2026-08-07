#!/bin/bash
# Builds the frozen cardetection onedir bundle with PyInstaller.
#
# Usage: ./build_cardetection.sh
# Output: dist/cardetection/  (executable + _internal/ support files)
#
# Xcode's "Stage CarDetection" run-script build phase copies this directory
# into Contents/Resources/car-detection/ if present -- see
# JalanKita Mac.xcodeproj. Not run automatically as part of a normal Xcode
# build (takes minutes, needs a Python venv with torch/ultralytics
# installed, and a real ~/.cache/torch/hub -- see below); run it explicitly
# before archiving a build meant to run without a dev Python environment
# present.
#
# Requires YOLOP + MiDaS_small (+ MiDaS's own nested efficientnet dependency)
# already cached at ~/.cache/torch/hub -- run pipeline_v13.py on any clip at
# least once first if this machine has never run it (torch.hub downloads
# them on first use). This script copies that real cache into
# torch_hub_cache/ so cardetection.spec can bundle it; without it, the
# frozen build still works but needs network access on ITS first run too.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
    echo "[build_cardetection] no .venv found -- creating one and installing requirements.txt"
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
else
    source .venv/bin/activate
fi

TORCH_HUB_SRC="$HOME/.cache/torch/hub"
if [ -d "$TORCH_HUB_SRC" ]; then
    echo "[build_cardetection] staging torch.hub cache from $TORCH_HUB_SRC"
    rm -rf torch_hub_cache
    mkdir -p torch_hub_cache
    rsync -a --exclude ".seeded" "$TORCH_HUB_SRC/" torch_hub_cache/
else
    echo "[build_cardetection] warning: no $TORCH_HUB_SRC found -- YOLOP/MiDaS_small have never been" \
         "downloaded on this machine. Building without a bundled cache; the frozen app will need" \
         "network access on its own first run instead. Run pipeline_v13.py on any clip once first" \
         "to populate the cache, then re-run this script, to avoid that."
fi

rm -rf build dist
pyinstaller cardetection.spec --noconfirm

echo "[build_cardetection] done: dist/cardetection/"
du -sh dist/cardetection
