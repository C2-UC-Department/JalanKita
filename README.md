# JalanKita — Road Intelligence

Turns a phone-recorded street survey into two independent, comparable measurements: how much road
width is physically blocked by parked vehicles, and how damaged the road surface is. Both scores
attach to the same road segment and combine into one priority — **SEGERA** (urgent), **PANTAU**
(monitor), or **ABAIKAN** (ignore) — so a limited road-maintenance budget goes where it matters
first.

This is not a detection dashboard. It's a survey pipeline: a field surveyor drives or walks a
street with a phone recording, and everything else — GPS tagging, vehicle detection, road
reconstruction, damage scoring, map placement — happens automatically.

## How it works

1. **Record** — the `JalanKita iOS` app (Peninjauan) records video with GPS attached automatically.
   No separate GPS device, no manual logging.
2. **Sync** — the finished session syncs to the `JalanKita Mac` desk console via CloudKit. No
   cables, no manual export.
3. **Analyze** — the Mac console runs three independent computer-vision pipelines on the synced
   footage:
   - **Car detection** (`CarDetection/`) — detects and tracks every vehicle in the clip, then
     decides which ones are genuinely parked (not just stopped in traffic).
   - **Disturbance measurement** (`PythonWorker/`) — for each parked vehicle, reconstructs the road
     surface hidden behind it and measures how much functional road width is blocked, in m² and %.
   - **Road condition** (`RoadDamage/`) — samples frames from the same clip independently, detects
     potholes/cracks, and scores each frame's surface condition (0–100, PCI-informed deductions).
4. **Decide** — both scores land on the same session, on the same timeline, and surface on a map
   and in reports, ranked worst-first.

A deeper technical write-up (system architecture, model deployment, source layout) lives in
[`docs/architecture/`](docs/architecture/) as a LaTeX document.

## Repository layout

| Path | What's there |
|---|---|
| `JalanKita Mac/` | Xcode project with both native app targets — `JalanKita Mac` (desk console) and `JalanKita iOS` (field recorder) — sharing one `.xcodeproj`. See [its README](JalanKita%20Mac/README.md). |
| `JalanKitaKit/` | Shared Swift package: data models + the CloudKit sync layer used by both app targets. See [its README](JalanKitaKit/README.md). |
| `CarDetection/` | Python worker — video → vehicle detection/tracking/parked-status verdict (one-shot subprocess). |
| `PythonWorker/` | Python worker — photo → parking-disturbance measurement (warm NDJSON worker). |
| `RoadDamage/` | Python worker — photo → road-damage boxes + condition score (warm NDJSON worker). |
| `docs/architecture/` | LaTeX architecture write-up: system design, model deployment, source structure. |
| `SETUP.md` | What a new developer machine needs to change (Apple Developer Team ID, bundle IDs, CloudKit container) before the app will sync. |
| `sign_workers.sh`, `worker-signing.entitlements` | Post-archive code-signing for the frozen Python workers (currently covers `disturbance-worker` and `pipeline_v13` by name — see [JalanKita Mac's README](JalanKita%20Mac/README.md#distribution--signing)), used before distributing a built app. |

Each Python worker directory has its own `README.md` with setup, dataset, and evaluation details
specific to that pipeline — start there for anything Python-related.

## Getting started

- **UI-only work** (Swift/SwiftUI) needs no Python toolchain at all — the app builds and runs
  without any worker `.venv` installed; features that need a worker just log instead of crashing.
- **First time on a new machine**: read [`SETUP.md`](SETUP.md) first. The repo pins one Apple
  Developer account's Team ID, bundle identifiers, and CloudKit container — miss one of the four
  places that needs changing and CloudKit sync fails *silently* (no error, just an empty inbox).
- **Working on a Python pipeline**: see that worker's own README —
  [`CarDetection/README.md`](CarDetection/README.md),
  [`PythonWorker/README.md`](PythonWorker/README.md), or
  [`RoadDamage/README.md`](RoadDamage/README.md) — each has its own venv, dependencies, and model
  checkpoints; the three are deliberately never merged into one environment.

## Tech stack

- **Swift 6, SwiftUI, CloudKit** — the two native app targets and the shared `JalanKitaKit`
  package. `JalanKitaKit` targets iOS 18+ / macOS 15+ as its package minimum; the app targets
  themselves pin a newer deployment target — see [`JalanKita Mac`'s README](JalanKita%20Mac/README.md)
  for the exact versions.
- **Python / PyTorch** — three independent workers, each combining Ultralytics YOLO detection with
  its own additional models (ByteTrack, Mask2Former, Depth-Anything-V2, MiDaS, and JalanKita's own
  trained OFRSNet and UNet extent models). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Known limitations

Documented in detail in each worker's own README, not repeated here — in short: the road-damage
detector is trained on public data (RDD2022) and not yet validated on Indonesian roads; the
parking-disturbance model's dataset combines the public KITTI Road dataset with the team's own
West Surabaya footage; the map/segment-prioritization view currently runs on sample data pending
real segment-aggregation logic. Check the relevant worker README before presenting any of these
numbers as validated ground truth.

## License

All rights reserved — see [`LICENSE`](LICENSE). This repository bundles or depends on third-party
models and datasets that carry their own license terms regardless of the notice above, including
an AGPL-3.0-licensed model family (Ultralytics YOLO) with real implications for distribution — see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before releasing or redistributing this work.
