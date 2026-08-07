# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for the `cardetection` executable JalanKita Mac bundles
# under Contents/Resources/car-detection/ (see CarDetectionService.resolveLaunch
# on the Swift side). Mirrors PythonWorker/disturbance_worker.spec's shape and
# reasoning -- see that file's own header comment for why `collect_all`
# rather than `hiddenimports` (dynamic `from_pretrained`/plugin-loading
# machinery that PyInstaller's static analysis alone misses).
#
# `pathex` includes lib/ and depth/ explicitly: pipeline_v13.py finds those
# sibling modules via its own `sys.path.insert(0, ...)` at RUNTIME, which
# PyInstaller's static import graph-walker does not execute, so it would
# otherwise never discover demo_scan_v5.py etc. as things to bundle at all.
#
# torch_hub_cache/: YOLOP + MiDaS_small (+ MiDaS's own nested
# rwightman_gen-efficientnet-pytorch dependency) are loaded via torch.hub at
# RUNTIME, not `import`ed -- PyInstaller cannot see or bundle that code the
# normal way. Instead this bundles a real, already-populated
# ~/.cache/torch/hub/ tree as plain data; cardetection_main.py copies it to a
# writable location and points TORCH_HOME at it before pipeline_v13 (and
# therefore torch.hub) is ever imported, so no network fetch happens at
# runtime. Built with `./build_cardetection.sh`, which populates this cache
# path from the build machine's own ~/.cache/torch/hub if not already staged.

import os
from pathlib import Path
from PyInstaller.utils.hooks import collect_all

ROOT = Path(os.path.dirname(os.path.abspath(SPEC)))

datas = [
    (str(ROOT / "yolov8n-seg.pt"), "."),
    (str(ROOT / "models" / "signs_crosswalk_v10_hardneg_r3_best.pt"), "models"),
]
binaries = []
hiddenimports = []

# Populated by build_cardetection.sh from the build machine's own torch.hub
# cache -- see that script and cardetection_main.py's _seed_torch_hub_cache().
torch_hub_cache_src = ROOT / "torch_hub_cache"
if torch_hub_cache_src.is_dir():
    datas.append((str(torch_hub_cache_src), "torch_hub_cache"))

for pkg in ("torch", "torchvision", "ultralytics", "cv2", "scipy", "PIL",
            "timm", "prefetch_generator", "yacs", "lap"):
    pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(pkg)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hiddenimports

a = Analysis(
    ["cardetection_main.py"],
    pathex=[str(ROOT), str(ROOT / "lib"), str(ROOT / "depth")],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    # NOT matplotlib -- unlike PythonWorker's spec (which this was copied
    # from), ultralytics/__init__.py eagerly resolves its full model zoo at
    # import time (FastSAM -> yolo.semantic.train), which imports matplotlib
    # even though pipeline_v13.py's own code never touches training/plotting.
    # Confirmed via a real frozen build: excluding it crashed with
    # ModuleNotFoundError before pipeline_v13 even finished importing.
    excludes=["pandas", "streamlit", "IPython", "notebook", "pytest"],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="cardetection",
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
    name="cardetection",
)
