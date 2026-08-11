"""Frozen entry point for the `disturbance-worker` executable (PyInstaller).

`python -m src.disturbance --serve` needs a concrete script when frozen --
PyInstaller can't target a `-m` module invocation directly, only a script.

This also overrides two of config.py's `Path(__file__).resolve().parent`-based
ROOT defaults, which do not reliably point at real, writable locations once
frozen (PyInstaller's `_MEIPASS` is the actual base for bundled `datas`, not a
frozen module's `__file__`):

  --ckpt  the bundled checkpoint (checkpoints/ofrsnet_best.pt). Without this,
          a missing checkpoint degrades silently to random OFRSNet weights
          instead of failing loudly -- see src/predict.py's `load_ofrsnet`.
  --out   config.DATA_DIR's default points *inside* the frozen bundle
          (Contents/Resources/disturbance-worker/_internal/data/...), which
          is part of the .app and not writable at runtime -- PermissionError
          on the first `_candidates.png`/`_bev.png` write. Redirected to
          ~/Library/Application Support instead, a real writable location.
"""
import multiprocessing
import os
import shutil
import sys
from pathlib import Path

# Onedir builds place bundled `datas` under sys._MEIPASS (the `_internal/`
# folder next to the executable); unfrozen, fall back to this script's own
# directory so `python worker_main.py --serve` also works for local testing
# without a PyInstaller build.
BASE_DIR = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
sys.path.insert(0, str(BASE_DIR))

from src.disturbance import main  # noqa: E402


def _seed_hf_cache() -> None:
    """Copy the bundled HuggingFace model cache to a writable location once,
    and point HF_HOME at it -- mirrors CarDetection's torch.hub cache seeding
    (see cardetection_main.py's `_seed_torch_hub_cache`) for the same reason:
    `s3_detect_foreground.load_model()` and `geometry.get_depth_model()` call
    `from_pretrained()` with no try/except around it (unlike the optional
    instance model in `instances.py`), so a machine that can't reach
    huggingface.co on first run hard-fails the whole disturbance-scoring
    request. Bundling a pre-populated cache removes that dependency on network
    access entirely, the same trade (extra bundle size for offline
    reliability) already made for CarDetection's YOLOP/MiDaS models.

    huggingface_hub resolves its cache at $HF_HOME/hub/... by default, so the
    writable copy's directory must literally be named "hub". HF_HUB_OFFLINE=1
    is set too, once seeded, so `from_pretrained()` never attempts even a
    metadata round-trip -- it goes straight to the local cache.

    copytree(..., symlinks=True) matters here specifically (torch.hub's cache
    doesn't need this): huggingface_hub's cache layout stores real file
    content once under blobs/<hash> and has snapshots/<rev>/ hold symlinks
    into it, deduping revisions that share files. The default
    symlinks=False follows and copies the symlink TARGET's content, so
    every snapshot file becomes its own physical copy of the blob --
    confirmed via a real seeded run: 1.75 GB of models on disk became a
    3.4 GB copy without this flag.
    """
    bundled_cache = BASE_DIR / "hf_cache_staging"
    if not bundled_cache.is_dir():
        # Unfrozen dev run, or a frozen build made without the cache staged
        # -- leave HF_HOME unset so huggingface_hub uses its own real default
        # (~/.cache/huggingface), same as running src/disturbance.py directly.
        return

    hf_home = Path.home() / "Library" / "Application Support" / "JalanKita Mac" / "hf_home"
    hub_dir = hf_home / "hub"
    marker = hub_dir / ".seeded"
    if not marker.exists():
        hub_dir.mkdir(parents=True, exist_ok=True)
        for child in bundled_cache.iterdir():
            dest = hub_dir / child.name
            if dest.exists():
                continue
            if child.is_dir():
                shutil.copytree(child, dest, symlinks=True)
            else:
                shutil.copy2(child, dest)
        marker.touch()

    os.environ["HF_HOME"] = str(hf_home)
    os.environ["HF_HUB_OFFLINE"] = "1"


if __name__ == "__main__":
    # Required for a frozen build: without this, anything that triggers
    # multiprocessing (confirmed here -- PyTorch starts a resource_tracker
    # helper process on its own) relaunches via sys.executable, which in a
    # frozen build IS this same executable, not a real Python interpreter --
    # it gets called with interpreter flags (-B -S -I -c ...) that this app's
    # own argparse doesn't recognize, fails, and resource_tracker retries
    # forever. freeze_support() makes multiprocessing route that relaunch
    # through PyInstaller's own bootloader sentinel instead. Confirmed via a
    # real frozen build: without this, the worker crashed shortly after
    # reaching "ready", spamming "unrecognized arguments: -B -S -I -c
    # from multiprocessing.resource_tracker import main;main(N)".
    multiprocessing.freeze_support()

    _seed_hf_cache()

    ckpt_path = BASE_DIR / "checkpoints" / "ofrsnet_best.pt"
    if "--ckpt" not in sys.argv and ckpt_path.exists():
        sys.argv += ["--ckpt", str(ckpt_path)]

    if "--out" not in sys.argv:
        out_dir = Path.home() / "Library" / "Application Support" / "JalanKita Mac" / "disturbance-worker"
        out_dir.mkdir(parents=True, exist_ok=True)
        sys.argv += ["--out", str(out_dir)]

    main()
