"""Frozen entry point for the `disturbance-worker` executable (PyInstaller).

`python -m src.disturbance --serve` needs a concrete script when frozen --
PyInstaller can't target a `-m` module invocation directly, only a script.

This also resolves the bundled checkpoint (checkpoints/ofrsnet_best.pt)
explicitly via `--ckpt`, rather than relying on config.py's
`Path(__file__).resolve().parent`-based ROOT: that does not reliably point
at the onedir bundle's real files once frozen (PyInstaller's `_MEIPASS` is
the actual base for bundled `datas`, not a frozen module's `__file__`).
Without this, a missing checkpoint degrades silently to random OFRSNet
weights instead of failing loudly -- see src/predict.py's `load_ofrsnet`.
"""
import sys
from pathlib import Path

# Onedir builds place bundled `datas` under sys._MEIPASS (the `_internal/`
# folder next to the executable); unfrozen, fall back to this script's own
# directory so `python worker_main.py --serve` also works for local testing
# without a PyInstaller build.
BASE_DIR = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
sys.path.insert(0, str(BASE_DIR))

from src.disturbance import main  # noqa: E402

if __name__ == "__main__":
    ckpt_path = BASE_DIR / "checkpoints" / "ofrsnet_best.pt"
    if "--ckpt" not in sys.argv and ckpt_path.exists():
        sys.argv += ["--ckpt", str(ckpt_path)]
    main()
