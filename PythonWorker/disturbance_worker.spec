# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for the `disturbance-worker` executable JalanKita Mac
# bundles under Contents/Resources/disturbance-worker/ (see
# InferenceService.resolveWorkerLaunch on the Swift side).
#
# onedir, not onefile: onefile self-extracts into a temp dir on every
# launch, which adds startup latency and complicates per-dylib code signing
# for notarization. Built with `./build_worker.sh` (or `pyinstaller
# disturbance_worker.spec --noconfirm` directly from an activated venv).
#
# torch/transformers/opencv all need `collect_all`, not just `hiddenimports`:
# their `from_pretrained`/plugin-loading machinery is dynamic enough that
# PyInstaller's static import analysis misses both real submodules and non-.py
# data files (tokenizer configs, image-processor JSON, torchvision codecs).
# This was verified empirically against a real run of this spec, not assumed.

from PyInstaller.utils.hooks import collect_all

datas = [("checkpoints/ofrsnet_best.pt", "checkpoints")]
binaries = []
hiddenimports = []

for pkg in ("torch", "torchvision", "transformers", "accelerate", "cv2",
            "tokenizers", "safetensors", "scipy"):
    pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(pkg)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hiddenimports

a = Analysis(
    ["worker_main.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    # None of these are imported anywhere in PythonWorker/src -- excluded
    # defensively in case a transitive dependency pulls one in.
    excludes=["matplotlib", "pandas", "streamlit", "IPython", "notebook", "pytest"],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="disturbance-worker",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="disturbance-worker",
)
