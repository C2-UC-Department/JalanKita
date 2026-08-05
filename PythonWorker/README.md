# PythonWorker

The parking-disturbance pipeline (`src/disturbance.py`'s `--serve` NDJSON worker mode) that
JalanKita Mac's `InferenceService` talks to as a subprocess. This is a trimmed, self-contained copy
of the relevant slice of [AmodalRoadSegmentation](https://github.com/) — just what
`python -m src.disturbance --serve` needs, not the full training/dataset/annotation tooling. Kept
here so contributors can build and run the macOS app without a second repo checkout.

## What's here

```
config.py                  Central config (paths, model ids, thresholds)
checkpoints/ofrsnet_best.pt Our own trained OFRSNet checkpoint (required — no download fallback)
src/                        disturbance.py + its direct dependency closure (bev, common, geometry,
                             instances, predict, s3_detect_foreground, s5_export_semantics,
                             calibration, ofrs/model.py)
worker_main.py               Concrete-script entry point PyInstaller freezes (disturbance.py's own
                              `main()` expects `-m src.disturbance`, which PyInstaller can't target)
disturbance_worker.spec      PyInstaller spec for the onedir build
build_worker.sh              Builds dist/disturbance-worker/ from a clean venv
requirements.txt             Inference-only dependencies (no streamlit/pandas/pytest)
```

Three HuggingFace models (Mask2Former semantic segmentation, Mask2Former instance segmentation,
Depth-Anything-V2) download and cache themselves on first run — see `InferenceService`'s first-run
download handling on the Swift side. `checkpoints/ofrsnet_best.pt` is the one weight file that
**must** be present locally; there's no download fallback for it (see `src/predict.py`'s
`load_ofrsnet` — a missing checkpoint silently degrades to random weights, so
`disturbance_worker.spec` always bundles it and `worker_main.py` always resolves it explicitly).

## Dev setup (no PyInstaller build needed)

```
cd PythonWorker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

That's it — `InferenceService.resolveWorkerLaunch()` auto-detects `PythonWorker/.venv/bin/python3`
as a sibling of the Xcode project and invokes `python3 -m src.disturbance --serve` directly by full
path (not via a shell's `PATH`, since Xcode-launched apps don't inherit one). No environment
variable needed for the common case; set `JALANKITA_DISTURBANCE_REPO` to point elsewhere (e.g. a
full AmodalRoadSegmentation checkout, which has the same `.venv`/`src/`/`config.py` shape) only if
you want to override it.

Sanity-check the worker directly before touching Xcode at all:

```
echo '{"id":"t","image_path":"/path/to/a/photo.jpg"}' | python worker_main.py --serve
```

Should print exactly one JSON line to stdout (`{"id":"t","ok":true,...}`); progress/log chatter goes
to stderr.

## Building the frozen worker (`disturbance-worker`)

Needed once before archiving a build meant to run without a dev Python environment present — a
normal `xcodebuild`/Xcode Run/Debug does **not** require this, it uses the dev venv above instead.

```
./build_worker.sh
```

Produces `dist/disturbance-worker/` (the executable + an `_internal/` folder with everything it
needs — torch, transformers, opencv, and their data files, `collect_all`'d in
`disturbance_worker.spec` since PyInstaller's static analysis misses their dynamic
`from_pretrained`/plugin-loading machinery). This is a large output (multiple GB — torch and
transformers are not small); expect the build itself to take several minutes.

The Xcode project's "Stage disturbance-worker" run-script build phase copies
`dist/disturbance-worker/` into `Contents/Resources/disturbance-worker/` automatically if present,
and no-ops (with a warning, not a failure) if you haven't built it — so UI-only development never
needs a Python toolchain at all.

## Keeping this in sync with AmodalRoadSegmentation

This is a manually-maintained copy, not a submodule. If `src/disturbance.py` (or anything it
imports) changes upstream in AmodalRoadSegmentation, re-copy the affected files here by hand and
re-run the dev sanity check above. The file list is short and stable (see "What's here"); a stray
new `import` from a module not already listed there is the only real integration hazard, and it
either shows up immediately as an `ImportError` in the dev sanity check or in `build_worker.sh`'s
frozen run — both fail loudly, not silently.
