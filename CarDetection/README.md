# CarDetection

The car-detection-from-video pipeline (v13's `pipeline_v13.py`) that JalanKita Mac's
`CarDetectionService` talks to as a one-shot subprocess per video, feeding its output into the
disturbance pipeline (`PythonWorker/`). This is a trimmed, self-contained copy of the relevant
runtime slice of the original v13 dev workspace — just what `pipeline_v13.py` needs to run, not
the historical dev artifacts (test clips, run logs, calibration docs, the v12 file it was diffed
against). Kept here for the same reason `PythonWorker/README.md` gives for its own copy: so
contributors can build and run the macOS app without a second repo checkout.

## What's here

```
pipeline_v13.py              The pipeline: YOLOv8n-seg+ByteTrack detection/tracking, v5 epipolar +
                              v6 FoE motion signals, v8 STOP_CLASS, v10 sign/zone DISTURBANCE
                              verdict, MiDaS depth as an UNRESOLVED tiebreaker (Option B).
demo_screenshots.py           Called automatically by pipeline_v13.py at the end of a run — writes
                              one annotated + one clean JPEG per PARKED-family car, plus
                              _summary.json (see below).
lib/                          v5/v6/v8 signal code + v10 sign/coverage-zone code, its direct
                              dependency closure.
depth/                        Depth-rate measurement (MiDaS backend + calibration).
models/signs_crosswalk_v10_hardneg_r3_best.pt   Our own trained sign/crosswalk detector weights.
yolov8n-seg.pt                 Stock Ultralytics vehicle detector/segmenter weights.
requirements.txt               Inference-only dependencies (+ pyinstaller, for build_worker.sh).
car_detection_worker.spec      PyInstaller spec for the onedir build.
build_worker.sh                Builds dist/pipeline_v13/ from a clean venv.
```

Two more models download and cache themselves on first run via `torch.hub` (`~/.cache/torch/hub`,
shared across venvs, same caching JalanKita Mac's other worker relies on for its own HuggingFace
models): YOLOP (road segmentation) and MiDaS_small (depth). No manual download needed, but the
first real run will be slower while these fetch.

## Dev setup (no PyInstaller build needed)

```
cd CarDetection
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`CarDetectionService.resolveLaunch()` auto-detects `CarDetection/.venv/bin/python3` as a sibling
of the Xcode project, same tier as `InferenceService`'s own `PythonWorker/.venv` auto-detection.
No environment variable needed for the common case; set `JALANKITA_V13_REPO` /
`JALANKITA_V13_PYTHON` only if you want to point at a different checkout (e.g. a full v13 dev
workspace with more than this trimmed runtime slice).

Sanity-check the pipeline directly before touching Xcode at all:

```
python3 pipeline_v13.py --input /path/to/a/clip.mov --output /tmp/out.mp4 \
                        --screenshot-dir /tmp/cardetection-test --deterministic
```

Should print a per-track table to stderr and, if any car reached a PARKED-family verdict, write
`_summary.json` + JPEGs into `--screenshot-dir`. `--deterministic` forces single-threaded CPU (~6
min for a 5s clip) but reproducible — this is what the app actually invokes, deliberately, over the
faster `--device mps` default: without it, ByteTrack's own run-to-run non-determinism can flip
whether the one ground-truth violation clip in this project's history reports 0 or 1 disturbances
between identical runs. Slow-and-correct over fast-and-sometimes-wrong.

## requirements.txt was built empirically, not by copying an existing environment

Every entry here was added because a fresh venv failed loudly without it (`ModuleNotFoundError`),
not guessed from `pip freeze` on a large, unrelated personal environment. Three of the eight lines
are transitive dependencies of `torch.hub`-loaded repos (YOLOP needs `prefetch_generator` and
`yacs`; ByteTrack needs `lap`) that don't show up in any `import` statement in this folder's own
`.py` files — `ultralytics` will silently auto-install `lap` itself at runtime if it's missing
("AutoUpdate success"), which is why it's listed explicitly here instead of being left to that
mechanism: a teammate's first run shouldn't depend on an internet-connected surprise pip install
mutating their venv mid-run.

## Building the frozen worker (`pipeline_v13`)

Needed once before archiving a build meant to run without a dev Python environment present — a
normal Xcode Run/Debug does **not** require this, it uses the dev venv above instead.

```
./build_worker.sh
```

Produces `dist/pipeline_v13/` (the executable + an `_internal/` folder with everything it needs —
torch, torchvision, ultralytics, opencv, and their data files, plus `yacs`/`prefetch_generator`/`lap`
explicitly `collect_all`'d in `car_detection_worker.spec` even though nothing in this folder's own
`.py` files imports them directly — they're real transitive dependencies of code `torch.hub`
downloads and executes at runtime (YOLOP, ByteTrack), invisible to PyInstaller's static analysis).
Unlike `disturbance_worker.spec`, no wrapper entry-point script was needed: `pipeline_v13.py` is
already invoked as a plain script (`python3 pipeline_v13.py --input ...`), which PyInstaller can
target directly.

`pipeline_v13.py`'s own `SCRIPT_DIR` (used to find the bundled `yolov8n-seg.pt` and
`models/signs_crosswalk_v10_hardneg_r3_best.pt`) resolves via `sys._MEIPASS` when frozen — the
same fix `PythonWorker/worker_main.py` needed for its checkpoint, now inlined directly into
`pipeline_v13.py` itself since it's already the PyInstaller entry point.

The two `torch.hub`-downloaded models (YOLOP, MiDaS_small) are **not** bundled — they still
download and cache themselves on first run exactly as in dev mode (this was verified: the frozen
executable, run standalone with a stripped environment, found and reused the same
`~/.cache/torch/hub` a prior dev-mode run had already populated).

The Xcode project's "Stage pipeline_v13" run-script build phase copies `dist/pipeline_v13/` into
`Contents/Resources/pipeline_v13/` automatically if present, and no-ops (with a warning, not a
failure) if you haven't built it — so UI-only development never needs a Python toolchain at all.
`CarDetectionService.resolveLaunch()` checks that packaged path first, before either dev tier.

## Keeping this in sync with the v13 dev workspace

This is a manually-maintained copy, not a submodule — same caveat as `PythonWorker/README.md`
states for its own copy. If `pipeline_v13.py` (or anything it imports) changes in the dev
workspace, re-copy the affected files here by hand and re-run the dev sanity check above.
