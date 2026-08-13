"""Frozen entry point for the `cardetection` executable (PyInstaller).

Mirrors PythonWorker/worker_main.py's role and reasoning -- pipeline_v13.py
computes its own SCRIPT_DIR from `__file__` (module import time, before any
wrapper code could override it), which does not reliably point at a real,
writable/readable location once frozen. Rather than touch pipeline_v13.py's
own path logic (used by both dev and frozen runs), this wrapper does the
frozen-only setup BEFORE importing it: correct sys.path, explicit --model/
--custom-model overrides (pipeline_v13's own DEFAULT_MODEL/DEFAULT_CUSTOM_MODEL
use its SCRIPT_DIR too, but argparse args passed here take priority), and
torch.hub cache redirection.

torch.hub cache: pipeline_v13.py loads two hub repos at runtime (YOLOP for
road segmentation, MiDaS_small for depth -- see lib/demo_scan_v5.py and
depth/render_depth_video.py), and MiDaS's own hubconf.py pulls in a third
nested repo. None of that is `import`-visible to PyInstaller's static
analysis, so it can't be bundled as code the normal way. Instead, the whole
~/.cache/torch/hub tree from a real run is bundled as PyInstaller `datas`
(see cardetection.spec) under `torch_hub_cache/`, and copied here into a
writable location on first run with TORCH_HOME pointed at it -- so torch.hub
finds everything already cached and never touches the network, and never
tries to write into the read-only, signed .app bundle itself.
"""
import multiprocessing
import os
import shutil
import sys
from pathlib import Path

# Onedir builds place bundled `datas` under sys._MEIPASS (the `_internal/`
# folder next to the executable); unfrozen, fall back to this script's own
# directory so `python cardetection_main.py --input ...` also works for
# local testing without a PyInstaller build.
BASE_DIR = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))

# Must happen BEFORE `import pipeline_v13` -- that import runs
# `sys.path.insert(0, .../lib)` / `sys.path.insert(0, .../depth)` itself
# using its own (frozen-broken) SCRIPT_DIR, but as long as the CORRECT paths
# are already present first, its sibling imports (`import demo_scan_v5 as v5`
# etc.) resolve through these instead. The redundant, wrong insert it does
# afterward is harmless.
sys.path.insert(0, str(BASE_DIR))
sys.path.insert(0, str(BASE_DIR / "lib"))
sys.path.insert(0, str(BASE_DIR / "depth"))


def _seed_torch_hub_cache() -> None:
    """Copy the bundled torch.hub cache to a writable location once, and
    point TORCH_HOME at it. Must run before anything imports pipeline_v13
    (which imports lib/demo_scan_v5.py, whose YOLOP loader calls
    torch.hub.load at class-init time -- actually at first RoadSegmenter()
    construction, not import time, but there's no benefit to cutting this
    close: do it unconditionally, first, same as the sys.path setup above).

    torch.hub.get_dir() resolves repos under `$TORCH_HOME/hub/...` -- so the
    writable copy's directory must literally be named "hub" for TORCH_HOME
    (its parent) to point torch.hub at it.
    """
    bundled_cache = BASE_DIR / "torch_hub_cache"
    if not bundled_cache.is_dir():
        # Unfrozen dev run (or a frozen build made without the cache staged)
        # -- leave TORCH_HOME unset so torch.hub uses its own real default
        # (~/.cache/torch/hub), same as running pipeline_v13.py directly.
        return

    torch_home = Path.home() / "Library" / "Application Support" / "JalanKita Mac" / "torch_home"
    hub_dir = torch_home / "hub"
    marker = hub_dir / ".seeded"
    if not marker.exists():
        hub_dir.mkdir(parents=True, exist_ok=True)
        for child in bundled_cache.iterdir():
            dest = hub_dir / child.name
            if dest.exists():
                continue
            if child.is_dir():
                shutil.copytree(child, dest)
            else:
                shutil.copy2(child, dest)
        marker.touch()

    os.environ["TORCH_HOME"] = str(torch_home)


if __name__ == "__main__":
    # Same reasoning as worker_main.py's freeze_support() call: PyInstaller
    # freezes sys.executable to point at this same binary, not a real Python
    # interpreter, which breaks anything that tries to relaunch itself via
    # multiprocessing (confirmed necessary for PythonWorker's disturbance-
    # worker; applied here proactively since ultralytics/torch can plausibly
    # do the same thing, e.g. DataLoader workers).
    multiprocessing.freeze_support()

    _seed_torch_hub_cache()

    if "--model" not in sys.argv:
        sys.argv += ["--model", str(BASE_DIR / "yolov8n-seg.pt")]
    if "--custom-model" not in sys.argv:
        sys.argv += ["--custom-model", str(BASE_DIR / "models" / "signs_crosswalk_v10_hardneg_r3_best.pt")]

    from pipeline_v13 import main
    main()
