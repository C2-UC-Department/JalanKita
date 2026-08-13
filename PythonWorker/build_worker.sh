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

# Stage only the 3 specific models this pipeline actually uses -- NOT the
# whole ~/.cache/huggingface/hub, which on a dev machine is shared across
# unrelated projects and can be tens of GB. See config.py for these IDs
# (MODEL_ID, INSTANCE_MODEL_ID, DEPTH_MODEL_ID).
HF_CACHE_SRC="$HOME/.cache/huggingface/hub"
HF_MODELS=(
    "models--facebook--mask2former-swin-large-mapillary-vistas-semantic"
    "models--facebook--mask2former-swin-large-cityscapes-instance"
    "models--depth-anything--Depth-Anything-V2-Metric-Outdoor-Small-hf"
)
rm -rf hf_cache_staging
if [ -d "$HF_CACHE_SRC" ]; then
    mkdir -p hf_cache_staging
    missing=0
    for model in "${HF_MODELS[@]}"; do
        if [ -d "$HF_CACHE_SRC/$model" ]; then
            echo "[build_worker] staging $model"
            rsync -a "$HF_CACHE_SRC/$model" hf_cache_staging/
        else
            echo "[build_worker] warning: $model not cached locally -- run the worker once" \
                 "(any --serve request) to download it, then re-run this script"
            missing=1
        fi
    done
    if [ "$missing" = "1" ]; then
        echo "[build_worker] warning: building with an incomplete HF cache -- the frozen app will" \
             "still need network access for whichever model(s) above weren't found"
    fi
else
    echo "[build_worker] warning: no $HF_CACHE_SRC found -- none of the 3 HuggingFace models have" \
         "been downloaded on this machine yet. Building without a bundled cache; the frozen app" \
         "will need network access on its own first run instead. Run the worker once first (any" \
         "--serve request) to populate the cache, then re-run this script, to avoid that."
fi

rm -rf build dist
pyinstaller disturbance_worker.spec --noconfirm

echo "[build_worker] done: dist/disturbance-worker/"
du -sh dist/disturbance-worker
