# RoadDamage — the Peninjauan worker

Third Python component of JalanKita, after `PythonWorker/` (photo → parking disturbance) and
`CarDetection/` (video → parked cars). This one turns **one photo → road-damage boxes + a
PCI-informed condition score**, and it is what the *Peninjauan* screen calls when you use
**"Analisis foto…"**.

Per [ADR-015](../JOURNAL.md) this vertical ships **bounding boxes, not segmentation**. Don't add a
segmentation model here — the measurements that killed that option are in the ADR.

---

## Why this is a separate process (and a separate venv)

🚫 **It cannot join `PythonWorker/`.** That worker pins `numpy<2.1`; ultralytics resolves numpy 2.x.
*"Never merge the two Python environments"* is a hard rule in [`CLAUDE.md`](../CLAUDE.md), and this
is the second time it has bitten. [ADR-016](../JOURNAL.md) records the choice.

It speaks **Protocol A** — the warm NDJSON worker protocol, same as `PythonWorker/` — and
deliberately *not* `CarDetection/`'s one-shot file contract. Peninjauan is a photo→findings flow
that finishes in seconds; a warm process amortises the model load and there is no long job needing
a file handoff.

---

## Setup

```bash
cd RoadDamage
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

⚠️ **Its own `.venv`.** Never install this into `PythonWorker/.venv`.

If you already have the sibling `../../test-road-damage-detection/` checkout with a working `.venv`,
the app will fall back to it and you can skip the install entirely — see the resolution order below.

### The checkpoint

`models/server_trained.pt` (19 MB, YOLO11s, mAP@50 0.53 on Japan+India) must be present.

> ⚠️ A missing checkpoint is a **hard error** here, on purpose. Ultralytics will happily build a
> model with untrained weights, which is how `PythonWorker` once degraded silently to random
> weights ([`CLAUDE.md`](../CLAUDE.md) fact 9). This worker refuses to start instead.

Resolution order: `--ckpt` → `JALANKITA_ROAD_DAMAGE_CKPT` → `models/server_trained.pt` →
`../../test-road-damage-detection/models/server_trained.pt`.

---

## Run it

```bash
# Config + taxonomy + anchor cases. No model load, so it's instant.
python3 worker_main.py --selftest

# The worker itself. Expect EXACTLY ONE json line on stdout; everything else is stderr.
echo '{"id":"t","image_path":"/full/path/to/frame.jpg"}' | python3 worker_main.py --serve
```

Verifying the stdout/stderr split matters: `RoadDamageWorkerProcess` decodes stdout strictly, so a
stray `print()` becomes a malformed-response log line. Ultralytics prints on import and on first
predict, which is why the model load is wrapped in `redirect_stdout(sys.stderr)`.

---

## How the app finds the interpreter

| order | source |
|---|---|
| 1 | `JALANKITA_ROAD_DAMAGE_PYTHON` — an explicit interpreter |
| 2 | `JALANKITA_ROAD_DAMAGE_REPO`/`.venv/bin/python3` |
| 3 | `RoadDamage/.venv/bin/python3` — the intended steady state |
| 4 | `../test-road-damage-detection/.venv/bin/python3` — the sibling checkout |

Tier 4 exists so the feature works on a dev machine that has already run the upstream detector
project, without spending ~2 GB and several minutes on a fourth environment.

> 🚫 **There is no bundled/frozen tier, so an archived app cannot do live analysis.** `RoadDamage/`
> has no `build_worker.sh`, exactly like `CarDetection/` ([`CLAUDE.md`](../CLAUDE.md) fact 13).
> Peninjauan's **Stage 0** — the pre-computed dataset — still works in a distributed build; only
> "Analisis foto…" does not. Adding PyInstaller here is the fix and it is not done.

---

## Keeping severity honest

`severity.py` and `severity.yaml` are **vendored copies** of
`../../test-road-damage-detection/src/severity.py` and `configs/severity.yaml`.

⚠️ **Re-vendor them as a pair, never one alone.** The entire point of ADR-016 is that exactly one
severity implementation exists: Stage 0 reads `condition` and `deduct_effective` out of CSVs the
upstream copy produced, and Stage 1 recomputes them here. If they drift, the same road scores two
different numbers depending on which path the reviewer took, and nothing on screen says which is
right.

The copies were verified identical by replaying all 236 damaged Surabaya frames through both
implementations: 0 divergences in `condition`, 0 in per-box `deduct_effective`. Re-run that check
after any re-vendor.

Detector defaults (`conf 0.20`, `imgsz 1280`) are pinned to the run that produced the Stage 0 CSVs,
so a frame analysed live lands on the same boxes as the same frame read from the dataset —
confirmed on `IMG_0040_f000030_t0001000`, which scores 50 / MONITOR either way. Changing them makes
the two paths disagree.

---

## Known limits

- ⚠️ **The detector is not validated on Indonesian data.** 0.53 mAP is a Japan+India figure; no
  Indonesian box labels exist. It **under-fires** (24.6% of frames, 236/958), so counts are a floor.
  Every response ships a `warnings` string saying so.
- **No `areaSqm`.** Box area is a fraction of the frame, not m². Real metres need
  `../../test-road-damage-detection/src/ipm.py` wired up plus one known-scale calibration frame.
- **No GPS.** The Surabaya clips carry no track (ffprobe-verified; `frames_provenance.csv` records
  `gps_source=none`). Findings cannot be mapped until re-capture.
- **CPU-forced from the app.** `JALANKITA_ROAD_DAMAGE_FORCE_CPU=1` is set by
  `RoadDamageWorkerProcess`, mirroring [ADR-012](../JOURNAL.md)'s posture for the disturbance
  worker. A CLI run still gets MPS, so app-vs-terminal timings are not comparable. One frame is
  ~1.7 s on CPU, so this costs little here.
