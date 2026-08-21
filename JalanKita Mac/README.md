# JalanKita Mac / JalanKita iOS

One Xcode project (`JalanKita Mac.xcodeproj`), two native app targets, sharing the
[`JalanKitaKit`](../JalanKitaKit/) package:

- **`JalanKita Mac`** — the desk console. Ingests synced sessions, runs the three Python worker
  pipelines, and surfaces results for review.
- **`JalanKita iOS`** — the field recorder ("Peninjauan"). Records survey video with GPS, syncs
  finished sessions to the console.

They never talk to each other directly — see [`JalanKitaKit`'s README](../JalanKitaKit/README.md)
for how CloudKit sits between them.

## Requirements

- Deployment targets (from the current project settings): **iOS 18.0**, **macOS 26.5**.
- A recent Xcode with SDKs covering both of the above.
- An Apple Developer account — see [`SETUP.md`](../SETUP.md) at the repo root before your first
  build on a new machine; the repo pins one account's Team ID, bundle identifiers, and CloudKit
  container, and a mismatch on the CloudKit container specifically fails **silently** (app builds
  and runs, sync just never produces anything).

## Building and running

1. Open `JalanKita Mac.xcodeproj` in Xcode.
2. Pick the `JalanKita Mac` or `JalanKita iOS` scheme.
3. Run. No Python installation is required for UI-only work — worker-dependent features log
   instead of crashing if a worker isn't set up locally.

## `JalanKita Mac/` — the desk console

```
Models/            AppModel — single source of truth (Observation framework); owns session
                     state, the CloudKit ingest, and the three worker-launching services.
Services/
  Inference/        CarDetectionService, InferenceService, RoadDamageService and their
                     WorkerProcess counterparts — each resolves and launches its Python
                     worker (packaged binary → env var → local .venv → sibling checkout,
                     in that order) and speaks either a one-shot file contract
                     (CarDetection) or the warm NDJSON protocol (PythonWorker, RoadDamage).
  Video/             Frame/clip handling shared across the review flows.
  CloudKit/           Ingest side of the sync (see JalanKitaKit/CloudKit for the shared half).
Views/
  SessionInbox/      Incoming synced/uploaded sessions awaiting processing.
  ProcessingQueue/    Live status of the three pipelines running on a session.
  ParkingReview/      Per-vehicle disturbance results, BEV panel.
  MapSegments/        Map + segment table (see the root README's "Known limitations" —
                       this view currently runs on sample data).
  Reports/            Finished-session history.
  Settings/, Sidebar/  App chrome.
```

## `JalanKita iOS/` — the field recorder

```
App/                AppDelegate/orientation lock — recording is forced landscape to match
                     what the Mac pipeline expects from a clip.
Recording/          Capture session + GPS logging, running in parallel while recording.
Onboarding/          Phone-mounting guide + camera calibration flow — needed for the BEV
                     geometry math in PythonWorker to have a known camera height/angle.
Dashboard/          Session list, record/import, manual + foreground-driven auto-sync.
Coverage/           "Peta Cakupan" — this device's own recorded coverage on a map.
ParkingReport/      Local-side parking result display.
Sync/               CloudKitSyncEngine — the recorder's half of the sync (see JalanKitaKit).
```

## Distribution / signing

`sign_workers.sh` and `worker-signing.entitlements` at the repo root re-sign PyInstaller-frozen
worker bundles inside a built `.app` with a real signing identity (PyInstaller leaves them
ad-hoc-signed, which `spctl`/notarization reject outright), then re-signs the outer `.app` itself.
Run once per archive, after `xcodebuild archive` and before `-exportArchive` / notarizing.

⚠️ As of this writing, `sign_workers.sh` only re-signs **`disturbance-worker`** (PythonWorker) and
**`pipeline_v13`** (CarDetection) by name — it does not cover **`roaddamage-worker`**
(RoadDamage). If RoadDamage's frozen worker is staged in a build meant for notarized distribution,
either extend this script's `WORKER_DIR` list or re-sign it separately before notarizing.
