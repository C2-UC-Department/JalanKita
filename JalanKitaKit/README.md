# JalanKitaKit

Shared Swift package between the two native app targets in [`JalanKita Mac/`](../JalanKita%20Mac/)
— `JalanKita Mac` (the desk console) and `JalanKita iOS` (the field recorder). It holds the data
model both apps agree on and the CloudKit sync layer that moves data between them; neither app
target talks to CloudKit or to the other app directly.

Not published to a package registry — both app targets add it as a local Swift package dependency
pointing at this directory.

## Requirements

- iOS 18+ / macOS 15+
- Swift tools version 6.0

## What's here

```
Sources/JalanKitaKit/
  Models/        Session, Finding, ParkingAnalysis, CarCandidate/CarDetectionSummary,
                  ReviewFrame, SegmentResult, CalibrationProfile, Surveyor — the shared
                  vocabulary between the recorder and the console, and the typed contract
                  for decoding each Python worker's JSON output.
  CloudKit/       CloudKitSchema, the CKRecordConvertible protocol, and the Synced* record
                  types (SyncedClip, SyncedGPSTrack, SyncedParkingResult) — the actual
                  sync plumbing. A `Session`'s CloudKit container identifier must match
                  exactly what's configured in both apps' entitlements (see the root
                  SETUP.md) or sync fails silently.
  DesignSystem/   Shared visual taxonomy — e.g. DefectType, unifying road-damage classes
                  (pothole, alligator, crack) and the parking-disturbance finding
                  (blockedPark) under one set of colors/icons used by both apps.
Tests/JalanKitaKitTests/
  SeverityTests.swift   Tests for the road-condition severity/scoring logic.
```

## Why this exists as a separate package

Some of the model types here (`CarCandidate`, `CarDetectionSummary`) have `CodingKeys` that
deliberately mirror a Python worker's JSON field names verbatim (e.g. `track_id`, `stop_class`,
`depth_reading`) — this package is the typed boundary between Swift and whatever the Python
subprocess workers in [`CarDetection/`](../CarDetection/), [`PythonWorker/`](../PythonWorker/), and
[`RoadDamage/`](../RoadDamage/) print to stdout. Keeping it in one shared package (rather than
duplicating the model in each app target) means a change to a worker's output shape only needs
updating in one place.

## Building and testing

```bash
cd JalanKitaKit
swift build
swift test
```

Normally you won't invoke this directly — Xcode builds it automatically as a dependency when you
build either app target in `JalanKita Mac.xcodeproj`.
