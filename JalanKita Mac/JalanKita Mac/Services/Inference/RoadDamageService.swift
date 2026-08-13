//
//  RoadDamageService.swift
//  JalanKita Mac
//
//  App-facing entry point for the road-damage pipeline (Peninjauan). Owns the
//  lazily-launched, kept-warm RoadDamageWorkerProcess and turns its NDJSON
//  responses into the one thing AppModel wants: a `ReviewFrame` ready for the
//  review queue — the SAME type Stage 0's RoadDamageDataset produces, so the
//  screen cannot tell a live analysis from a dataset frame.
//
//  @MainActor for the same reason as InferenceService: its callers and its
//  progress forwarding both belong on the main actor, while everything genuinely
//  concurrent lives in the actor behind it.
//

import Foundation
import CoreGraphics

@MainActor
final class RoadDamageService {
    static let shared = RoadDamageService()

    private var worker: RoadDamageWorkerProcess?

    /// Forwarded from the worker's stderr — AppModel is the only subscriber.
    var onProgress: ((RoadDamageStderrLine) -> Void)?

    private init() {}

    /// Analyses one photo and returns it as a queue-ready `ReviewFrame`.
    ///
    /// `requestID` only has to be unique in flight; unlike the disturbance worker
    /// there is no result cache to key into, because nothing re-renders a road
    /// damage result after the fact (no BEV equivalent). The frame's own id is
    /// the image filename, so re-analysing the same photo replaces rather than
    /// duplicates it in the queue.
    func analyze(imageURL: URL, requestID: String = UUID().uuidString) async throws -> ReviewFrame {
        let worker = try await ensureStarted()

        // Arm the deadline before the send, disarm it however the send ends. The
        // timer is a detached Task rather than a task-group race so that the
        // `pending` mutation stays inside the actor — see `abandon(requestID:)`.
        let timeout = Task {
            try await Task.sleep(for: .seconds(Self.requestTimeoutSeconds))
            await worker.abandon(requestID: requestID,
                                 afterSeconds: Self.requestTimeoutSeconds)
        }
        defer { timeout.cancel() }

        let response: RoadDamageResponse
        do {
            response = try await worker.send(
                RoadDamageRequest(id: requestID, imagePath: imageURL.path))
        } catch RoadDamageWorkerError.timedOut(let seconds, _) {
            // The worker is still chewing on that request and will eventually
            // write a response for an id nobody is waiting on, which the response
            // pump would silently drop. Replace it rather than reuse it; the next
            // analyze pays one model load, and only after an actual hang.
            await self.worker?.stop()
            self.worker = nil
            throw RoadDamageWorkerError.timedOut(seconds: seconds, duringStart: false)
        }

        guard response.ok else {
            throw RoadDamageWorkerError.requestFailed(
                response.error ?? "Analisis kerusakan jalan gagal tanpa pesan kesalahan.")
        }
        return Self.makeFrame(from: response, imageURL: imageURL)
    }

    /// Samples a clip into frames, then analyses each one through the warm worker.
    ///
    /// Two processes on purpose. Extraction is a **separate one-shot invocation**
    /// (`RoadDamageVideoProcess`) because doing it inside the warm worker measurably
    /// changed the pixels — a live MPS context shifts the decode, moving one frame's
    /// `conf` from 0,7424 to 0,7411. Analysis then goes one frame at a time through
    /// the existing worker, because the detector is one-image-per-call by contract:
    /// ADR-021 measured batching moving `conf` by 7 points.
    ///
    /// ⚠️ Slow, and the arithmetic should be visible to whoever picks the interval.
    /// The app forces CPU (`JALANKITA_ROAD_DAMAGE_FORCE_CPU`), so a frame costs about
    /// 2,7 s — ~1,7 s detector plus ~1,0 s extent model. At a 3 s interval that is
    /// roughly the clip's own duration again; at 1 s it is three times worse.
    ///
    /// A frame that fails is logged and skipped, never fatal — one unreadable frame
    /// must not discard the fifty that worked. Only a total failure throws.
    func analyzeVideo(videoURL: URL,
                      sessionID: String,
                      intervalSec: Double = 3.0,
                      workDir: URL,
                      onExtract: ((RoadDamageVideoProgress) -> Void)? = nil,
                      onFrame: ((Int, Int) -> Void)? = nil) async throws -> [ReviewFrame] {
        let manifest = try await RoadDamageVideoProcess.extract(
            video: videoURL, outputDir: workDir,
            intervalSec: intervalSec, onProgress: onExtract)

        guard !manifest.frames.isEmpty else { return [] }

        var frames: [ReviewFrame] = []
        var failures: [String] = []
        for (index, path) in manifest.frames.enumerated() {
            let url = URL(fileURLWithPath: path)
            do {
                // requestID is per frame, mirroring the video parking path's
                // "<session>#<track>" — `analyze`'s own contract is only that the id
                // is unique in flight.
                frames.append(try await analyze(imageURL: url,
                                                requestID: "\(sessionID)#\(index)"))
            } catch {
                failures.append(url.lastPathComponent)
            }
            onFrame?(index + 1, manifest.frames.count)
        }

        if frames.isEmpty {
            throw RoadDamageWorkerError.requestFailed(
                "Semua \(failures.count) frame gagal dianalisis.")
        }
        return frames
    }

    /// 60 s against a measured ~1,7 s per frame on CPU (ADR-016) — a 35× margin,
    /// so this can only fire on a genuine wedge, never on a slow-but-working run.
    /// Both numbers are recorded together deliberately: a bare `60` is the kind of
    /// constant someone halves later because it "looks arbitrary".
    ///
    /// ⚠️ Do NOT copy these two values to `InferenceService`, which has both of the
    /// same holes. OFRSNet runs are far longer and CPU-forced (ADR-012), so its
    /// deadlines need measuring, not transplanting.
    private static let requestTimeoutSeconds = 60

    /// 120 s for start. Unlike the request timeout this one is NOT measured — it
    /// covers a torch import plus a 19,2 MB YOLO11s load on a cold CPU, which is
    /// tens of seconds in practice, and the margin is a guess. Said plainly so the
    /// next person tightening it knows there is no measurement behind it.
    private static let startTimeoutSeconds = 120

    /// Terminates the child process. Unlike `InferenceService.shutdown()` — which
    /// famously has no caller — this one is wired to app termination in
    /// JalanKita_MacApp, so quitting mid-analysis doesn't orphan a Python process.
    func shutdown() async {
        await worker?.stop()
        worker = nil
    }

    private func ensureStarted() async throws -> RoadDamageWorkerProcess {
        if let worker, await worker.isRunning {
            return worker
        }
        // Reap the dead one before overwriting it. Assigning straight over the
        // old instance orphaned its stderr pump Task, its stdin handle, and —
        // worst — its `pending` map, whose continuations would then never resume
        // at all: a permanent hang for anyone still awaiting one. `stop()` is
        // safe on an already-dead process and resumes those with a real error.
        if let worker {
            await worker.stop()
            self.worker = nil
        }

        let (executable, arguments, cwd) = try Self.resolveWorkerLaunch()
        let newWorker = RoadDamageWorkerProcess(executableURL: executable,
                                                arguments: arguments,
                                                workingDirectory: cwd)
        let forward = onProgress
        await newWorker.setOnStderrLine { line in
            Task { @MainActor in forward?(line) }
        }

        // `start()` blocks on the worker's `{"type":"ready"}` by iterating stderr,
        // which has no deadline of its own — a child that imports torch and then
        // wedges would suspend this call forever, with the same stuck-spinner
        // symptom as a hung request. Racing a sleep against it and calling stop()
        // on timeout kills the process, which ends the reader, which unblocks
        // `waitForReady`; no separate cancellation path is needed.
        // Returns whether it actually fired, so the catch below can tell a timeout
        // apart from a genuine launch failure — the two want different messages,
        // and after `stop()` they otherwise look identical from here (both surface
        // as `workerTerminated`). Cancelling makes the sleep throw, so a disarmed
        // timer reports false; awaiting `.value` after `cancel()` is therefore
        // deterministic either way.
        let startTimeout = Task { () -> Bool in
            do { try await Task.sleep(for: .seconds(Self.startTimeoutSeconds)) }
            catch { return false }
            await newWorker.stop()
            return true
        }
        do {
            try await newWorker.start()
            startTimeout.cancel()
        } catch {
            startTimeout.cancel()
            let timedOut = await startTimeout.value
            await newWorker.stop()
            throw timedOut
                ? RoadDamageWorkerError.timedOut(seconds: Self.startTimeoutSeconds,
                                                 duringStart: true)
                : error
        }

        worker = newWorker
        return newWorker
    }

    // MARK: - Launch resolution

    /// Where the road-damage worker lives, in order:
    ///
    ///  0. **Packaged**: `Contents/Resources/roaddamage-worker/roaddamage-worker`
    ///     — the PyInstaller onedir output staged there by the "Stage RoadDamage"
    ///     run-script phase (see `RoadDamage/build_worker.sh` and
    ///     `roaddamage_worker.spec`). This is how a shipped app runs Stage 1, and
    ///     it is the only tier that needs no Python on the user's machine.
    ///  1. **`JALANKITA_ROAD_DAMAGE_PYTHON`** — an explicit interpreter, which is
    ///     how you point this at an existing environment without building a new one.
    ///  2. **`JALANKITA_ROAD_DAMAGE_REPO`/.venv** — an explicit checkout.
    ///  3. **`RoadDamage/.venv`** — this repo's own worker environment, the
    ///     intended steady state (`RoadDamage/README.md` has the two commands).
    ///  4. **`../test-road-damage-detection/.venv`** — the sibling checkout the
    ///     detector is trained in. Present on a dev machine that has run the
    ///     upstream project, and it already has the exact dependency set, so this
    ///     tier is what makes the feature work before anyone spends ~2 GB and
    ///     several minutes on a fourth venv.
    ///
    /// The bundled tier goes FIRST, matching `InferenceService`: a shipped app
    /// must not prefer a developer's stray checkout, and a dev machine simply has
    /// no `dist/` staged so it falls through to the venv tiers unchanged. The
    /// frozen worker takes `--serve` as its only argument — the script path is
    /// baked in — which is why it is built as a separate candidate rather than
    /// folded into the interpreter list.
    ///
    /// ⚠️ The frozen build is NOT produced by a normal Xcode build. `build_worker.sh`
    /// takes minutes and multiple GB, so the staging phase warns and `exit 0`s when
    /// `dist/` is absent (CLAUDE.md's "UI-only work needs no Python toolchain"
    /// rule). Until someone runs it, an archived app still gets Peninjauan's
    /// Stage 0 — the pre-computed dataset needs no Python at all — and Stage 1
    /// reports which paths it searched.
    ///
    /// Every interpreter tier invokes Python by full path rather than relying on
    /// PATH: Xcode launches the app without a terminal's activated venv, so
    /// `/usr/bin/env python3` would find a Python with none of this installed.
    private static func resolveWorkerLaunch() throws -> (URL, [String], URL?) {
        try resolveLaunch(mode: ["--serve"])
    }

    /// Same five tiers, any entry-point mode.
    ///
    /// `mode` is appended after the script path, so `["--serve"]` starts the warm NDJSON worker and
    /// `["--extract-video", …]` runs a one-shot frame sampler. Sharing the ladder matters more than
    /// it looks: video extraction has to work in a shipped `.app`, where the only thing that exists
    /// is the frozen binary — and that binary takes whatever arguments `worker_main.main()` parses,
    /// so a second entry point costs nothing here and would otherwise need its own staging.
    static func resolveLaunch(mode: [String]) throws -> (URL, [String], URL?) {
        let repoRoot = autoDetectedWorkerRoot()
        let script = repoRoot.appendingPathComponent("worker_main.py")
        let environment = ProcessInfo.processInfo.environment
        var searched: [String] = []

        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("roaddamage-worker/roaddamage-worker"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            let staged = stagedWorkerContract(besides: bundled)
            if staged == expectedWorkerContract {
                // cwd is the bundle dir, not repoRoot: a frozen worker resolves its
                // checkpoint and severity.yaml through `bundle_root()` (sys._MEIPASS),
                // never relative to the working directory.
                return (bundled, mode, bundled.deletingLastPathComponent())
            }
            // 🔥 Refuse a frozen worker that predates what this app expects, and fall
            // through to a source checkout instead. This is not defensive
            // programming, it is a fix: a `dist/` built on 2026-08-10 kept serving
            // after the extent model and the video sampler landed. `extent_pct` is
            // optional by design, so Stage 1 silently rendered one number instead of
            // two, and nothing failed until video hit an argparse error three days
            // later. Better to be one tier slower than three days wrong.
            searched.append("\(bundled.path) — kontrak \(staged ?? "tidak ada") "
                            + "\u{2260} \(expectedWorkerContract); jalankan "
                            + "RoadDamage/build_worker.sh untuk memperbaruinya")
        } else if let resources = Bundle.main.resourceURL {
            searched.append(resources
                .appendingPathComponent("roaddamage-worker/roaddamage-worker").path)
        }

        var candidates: [URL] = []
        if let explicit = environment["JALANKITA_ROAD_DAMAGE_PYTHON"] {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if let repo = environment["JALANKITA_ROAD_DAMAGE_REPO"] {
            candidates.append(URL(fileURLWithPath: repo, isDirectory: true)
                .appendingPathComponent(".venv/bin/python3"))
        }
        candidates.append(repoRoot.appendingPathComponent(".venv/bin/python3"))
        candidates.append(siblingDetectorRoot().appendingPathComponent(".venv/bin/python3"))

        for python in candidates {
            if FileManager.default.isExecutableFile(atPath: python.path),
               FileManager.default.fileExists(atPath: script.path) {
                return (python, [script.path] + mode, repoRoot)
            }
            searched.append(python.path)
        }
        throw RoadDamageWorkerError.workerNotFound(searched: searched)
    }

    /// The worker capability set this build of the app requires.
    ///
    /// Must equal `worker_main.WORKER_CONTRACT`. Bump both together whenever the app
    /// starts depending on something the worker gained — a new wire field, a new
    /// entry-point mode. `build_worker.sh` stamps the worker's value into
    /// `WORKER_CONTRACT` beside the frozen binary, and a mismatch demotes that tier
    /// rather than letting it serve stale inference.
    static let expectedWorkerContract = "2026-08-13.extent+video"

    /// The contract stamped beside a frozen worker, or nil for a build that predates
    /// stamping — which is itself a mismatch, and deliberately so.
    private static func stagedWorkerContract(besides binary: URL) -> String? {
        let file = binary.deletingLastPathComponent()
            .appendingPathComponent("WORKER_CONTRACT")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a stem carries `video_frames.py`'s `_f<index>_t<millis>` provenance.
    /// Both fields, not either: a photo the user happened to name `foto_t2.jpg`
    /// must not be relabelled as frame 2 of a clip that does not exist.
    private static func looksSampled(_ stem: String) -> Bool {
        let fields = stem.split(separator: "_")
        let hasFrame = fields.contains { $0.hasPrefix("f") && Int($0.dropFirst()) != nil }
        let hasTime = fields.contains { $0.hasPrefix("t") && Int($0.dropFirst()) != nil }
        return hasFrame && hasTime
    }

    /// `RoadDamage/`, five path components up from this source file — the same
    /// walk `InferenceService` does to find `PythonWorker/`, since both are
    /// subdirectories of the repo root.
    private static func autoDetectedWorkerRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("RoadDamage", isDirectory: true)
    }

    /// One level further out than the repo root — the sibling checkout, same
    /// place `RoadDamageDataset` finds the Stage 0 CSVs.
    private static func siblingDetectorRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("test-road-damage-detection", isDirectory: true)
    }

    // MARK: - Response -> ReviewFrame

    /// Builds the same `ReviewFrame` shape Stage 0 produces.
    ///
    /// The metadata Stage 0 reads from `frames_provenance.csv` has no analogue for
    /// an ad-hoc photo — there is no source clip, no decoder frame index, no
    /// presentation timestamp — so those carry the filename and em-dashes rather
    /// than invented values, and GPS stays nil for the same reason it does in
    /// Stage 0: the footage has none.
    private static func makeFrame(from response: RoadDamageResponse,
                                  imageURL: URL) -> ReviewFrame {
        let score = response.condition ?? 98
        let boxes = response.boxes ?? []
        let stem = imageURL.deletingPathExtension().lastPathComponent

        let findings = boxes.map { box in
            Finding(
                id: "\(stem)#\(box.boxIndex)",
                defectType: defectType(box.cls) ?? .crack,
                areaSqm: nil,                       // needs IPM + a calibration frame
                percentOfSurface: box.areaPct,
                // Nil for Stage 0 rows and for any frame the worker could not measure.
                // Display only — the condition score above is still box-derived.
                extentPercent: box.extentPct,
                vehicleNote: nil,
                confidence: box.conf,
                mappedFromNote: box.cls == "crack"
                    ? "gabungan retak memanjang & melintang" : nil,
                frameRect: CGRect(x: box.cx - box.w / 2, y: box.cy - box.h / 2,
                                  width: box.w, height: box.h)
            )
        }

        // Unrounded, exactly as Stage 0 does — rounding here is what used to make
        // the panel's rows disagree with its own total. Display rounds; this doesn't.
        let deductions = boxes.map { box -> SeverityDeduction in
            var label = (defectType(box.cls) ?? .crack).label
            if box.inWheelpath { label += " · di jalur roda" }
            if box.deductEffective < box.deductRaw - 0.0001 { label += " · pengulangan kelas" }
            return SeverityDeduction(label: label, points: -box.deductEffective)
        }

        return ReviewFrame(
            id: stem,
            // A frame sampled from a clip carries its own provenance in its name —
            // `IMG_0040_f000030_t0001000` — so the same parsers Stage 0 uses fill
            // these in for free, and a video frame is labelled exactly like a
            // dataset one. An ad-hoc photo matches none of that, and its parsers
            // fall back to the filename and em-dashes rather than inventing a clip
            // and a timestamp it does not have.
            sourceClip: Self.looksSampled(stem)
                ? RoadDamageDataset.sourceClip(fromStem: stem) : imageURL.lastPathComponent,
            frameNumber: RoadDamageDataset.frameIndex(fromStem: stem),
            timecode: RoadDamageDataset.timecode(seconds: nil, stem: stem),
            capturedAt: nil,
            severity: Severity(score: score),
            score: score,
            isProvisional: true,
            // Prefer the live sentence over the mirrored constant, so editing
            // worker_main.py's caveat changes what the reviewer reads without a
            // Swift build. The fallback only matters if a worker ever omits it.
            warnings: response.warnings ?? RoadDamageResponse.domainGapCaveat,
            segmentLabel: nil,
            kmMarker: nil,
            coordinate: nil,
            gpsAccuracyM: nil,
            findings: findings,
            startScore: response.startScore ?? 100,
            deductions: deductions,
            imageURL: imageURL,
            imageWidth: response.imageWidth ?? 0,
            imageHeight: response.imageHeight ?? 0
        )
    }

    private static func defectType(_ raw: String) -> DefectType? {
        switch raw {
        case "crack": return .crack
        case "alligator": return .alligator
        case "pothole": return .pothole
        default: return nil
        }
    }
}
