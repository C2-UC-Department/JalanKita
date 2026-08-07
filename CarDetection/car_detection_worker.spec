# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for `pipeline_v13`, the car-detection-from-video pipeline,
# mirroring PythonWorker/disturbance_worker.spec's structure and reasoning.
# Built with `./build_worker.sh` (or `pyinstaller car_detection_worker.spec
# --noconfirm` directly from an activated venv).
#
# Unlike disturbance_worker.spec, this targets `pipeline_v13.py` directly --
# it's already invoked as a plain script (`python3 pipeline_v13.py --input
# ...`), not `-m module`, so PyInstaller can target it with no wrapper
# script needed (contrast worker_main.py, required there only because
# disturbance.py needs `-m src.disturbance`).
#
# `pathex=["lib", "depth"]` is required for PyInstaller's static analysis to
# find pipeline_v13.py's bare-name imports (`import demo_scan_v5 as v5`,
# `from foe_signal import ...`, etc.) -- at runtime this is normally handled
# by pipeline_v13.py's own `sys.path.insert(0, ...)` calls, but PyInstaller's
# import-graph scan happens at BUILD time, before any of that runs.
#
# `collect_all` for yacs/prefetch_generator/lap isn't defensive padding --
# CarDetection/README.md documents these as real, empirically-found
# transitive dependencies of code `torch.hub` downloads and executes at
# RUNTIME (YOLOP needs yacs+prefetch_generator, ByteTrack needs lap), which
# means no static `import` of them exists anywhere in this folder's own .py
# files for PyInstaller to find on its own -- only an explicit `collect_all`
# forces them into the bundle so the dynamically-downloaded code can import
# them once frozen.

from PyInstaller.utils.hooks import collect_all

datas = [
    ("models/signs_crosswalk_v10_hardneg_r3_best.pt", "models"),
    ("yolov8n-seg.pt", "."),
]
binaries = []
hiddenimports = []

for pkg in ("torch", "torchvision", "ultralytics", "cv2", "scipy", "timm",
            "yacs", "prefetch_generator", "lap"):
    pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(pkg)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hiddenimports

a = Analysis(
    ["pipeline_v13.py"],
    pathex=["lib", "depth"],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["streamlit", "IPython", "notebook", "pytest"],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="pipeline_v13",
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
    name="pipeline_v13",
)
