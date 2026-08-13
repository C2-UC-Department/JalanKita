# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for the `roaddamage-worker` executable JalanKita Mac bundles
# under Contents/Resources/roaddamage-worker/ (see
# RoadDamageService.resolveWorkerLaunch on the Swift side, tier 1).
#
# onedir, not onefile, for the same two reasons as
# PythonWorker/disturbance_worker.spec: onefile self-extracts on every launch,
# which adds startup latency to a worker whose whole point is being kept warm,
# and it complicates per-dylib code signing for notarization. Built with
# `./build_worker.sh`, or `pyinstaller roaddamage_worker.spec --noconfirm`
# directly from an activated venv.
#
# Two data files, and BOTH are load-bearing:
#
#   models/server_trained.pt -- the 19.2 MB detector. `resolve_checkpoint()`
#       hard-errors when it is absent rather than letting ultralytics build a
#       model with random weights (CLAUDE.md fact 9), so omitting it here is at
#       least a loud failure. It still has to be here.
#
#   severity.yaml -- easy to forget, and the failure is NOT loud. `severity.py`
#       resolves it as `Path(__file__).parent / "severity.yaml"`, and PyInstaller
#       relocates modules into _MEIPASS, so the path a checkout resolves is not
#       the path a frozen build resolves. worker_main.py routes both lookups
#       through `bundle_root()` for exactly this reason; the yaml has to land
#       where that points. Neither of the two existing specs in this repo has
#       this wrinkle -- do not assume they are a complete model.
#
# `pathex` includes ROOT so the analyzer can find `severity` as an import at
# all: worker_main.py reaches it via a RUNTIME `sys.path.insert`, which
# PyInstaller's static graph-walker does not execute. Same reasoning as
# CarDetection/cardetection.spec's lib/ and depth/ entries.
#
# `collect_all` rather than plain `hiddenimports` for the heavy packages,
# because ultralytics' and torch's dynamic loading defeats static analysis for
# both submodules and non-.py data (ultralytics ships its default configs and
# fonts as package data, and loses them silently otherwise).
#
# ⚠️ matplotlib is deliberately NOT excluded, unlike disturbance_worker.spec.
# ultralytics/__init__.py eagerly resolves its full model zoo at import time and
# that path imports matplotlib even though nothing here plots. CarDetection hit
# exactly this against a real frozen build -- ModuleNotFoundError before the
# pipeline finished importing -- and this worker imports the same ultralytics.

import os
from pathlib import Path
from PyInstaller.utils.hooks import collect_all

ROOT = Path(os.path.dirname(os.path.abspath(SPEC)))

datas = [
    (str(ROOT / "models" / "server_trained.pt"), "models"),
    # The extent model (ADR-021). Resolved through `bundle_root()` like the detector, so it must
    # land in the same `models/` subdirectory inside `_internal/`. ⚠️ 93,4 MB — it roughly doubles
    # what this worker contributes to the bundle, and a staged build was already 911 MB.
    (str(ROOT / "models" / "unet_resnet34.pt"), "models"),
    (str(ROOT / "severity.yaml"), "."),
]
binaries = []
hiddenimports = []

# `segmentation_models_pytorch` is collected whole rather than let PyInstaller trace it: it builds
# its encoder registry by importing modules dynamically, so static analysis misses most of them and
# the frozen worker dies at `smp.Unet(...)`. `timm` is the same story one level down.
for pkg in ("torch", "torchvision", "ultralytics", "cv2", "PIL", "yaml",
            "segmentation_models_pytorch", "timm"):
    pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(pkg)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hiddenimports

a = Analysis(
    ["worker_main.py"],
    pathex=[str(ROOT)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
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
    name="roaddamage-worker",
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
    name="roaddamage-worker",
)
