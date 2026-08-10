//
//  AppModel.swift
//  JalanKita Mac
//
//  Single source of truth for the desk console, using the Observation
//  framework (@Observable) instead of scattering separate `@State private
//  var sessions = SampleData.sessions` copies across every screen. Views
//  read this directly (Observable tracks per-property access), and use
//  `@Bindable` only where they need a two-way Binding into it (e.g. a
//  Toggle or Table selection).
//
//  `queuedSessions` is computed from `sessions`, not stored separately —
//  the previous version kept a second copy of "which sessions are in the
//  queue," which is exactly the kind of dual-source-of-truth bug this
//  refactor removes.
//
//  `uploadImage(url:)` is the entry point for the real parking-disturbance
//  pipeline (InferenceService -> src/disturbance.py's `--serve` worker). It
//  deliberately mirrors SessionInboxView.processBatch()'s existing pattern
//  (flip a Session's status, then set `selection`) rather than inventing a
//  second navigation mechanism. On success it lands on "Tinjauan Parkir"
//  (parkingAnalyses), never Peninjauan (reviewQueue) — the two verticals stay
//  separate all the way down, and the road-damage one is fed by
//  `loadRoadDamageQueue()` / `analyzeRoadDamage(url:)` instead.
//
//  Peninjauan's queue is STATE, not a constant. It starts empty and is filled
//  by a loader, so "0 dari 0" is a real thing the UI must render — the previous
//  version stored a single always-present dummy frame with hardcoded 12/41
//  counters, which meant the empty case had never once been exercised.
//

import Foundation
import Observation

@Observable
final class AppModel {
    var selection: AppSection = .sessionInbox

    var sessions: [Session] = SampleData.sessions
    var segments: [SegmentResult] = SampleData.segments

    /// Peninjauan's review queue — real detector output, loaded from disk by
    /// `RoadDamageDataset`. Empty until `loadRoadDamageQueue()` runs (and stays
    /// empty if the dataset isn't present), so every consumer must handle zero
    /// frames. Position in this array IS the queue counter; nothing stores one.
    var reviewQueue: [ReviewFrame] = []

    /// Which frame the reviewer is on. Held as an id rather than an index so a
    /// reload that changes the queue's length can't silently point at a
    /// different frame than the one that was on screen.
    var reviewSelectionID: ReviewFrame.ID?

    /// Set when the queue includes frames the detector found nothing in. Off by
    /// default: 722 of 958 real frames are clean, and paging through them is not
    /// a review workflow. Toggleable from Peninjauan so the clean-frame render
    /// path stays exercisable at runtime.
    var reviewIncludesCleanFrames: Bool = false

    /// Non-fatal problems from the last queue load — surfaced in the log rather
    /// than thrown away, per the app's "degrade, don't die" rule.
    var reviewLoadWarnings: [String] = []

    var reviewFrame: ReviewFrame? {
        guard let reviewSelectionID else { return reviewQueue.first }
        return reviewQueue.first { $0.id == reviewSelectionID } ?? reviewQueue.first
    }

    /// 1-based position of the current frame, or nil when the queue is empty.
    /// Derived on every read — this is what replaced the hardcoded "12 dari 41".
    var reviewQueuePosition: Int? {
        guard let frame = reviewFrame,
              let index = reviewQueue.firstIndex(where: { $0.id == frame.id }) else { return nil }
        return index + 1
    }

    /// Real parking-disturbance results, keyed by session id — "Tinjauan
    /// Parkir"'s data. A single manual photo upload produces exactly one
    /// element; a video upload (uploadVideo, via v13) can produce zero to
    /// many, one per car v13 found parked. `var` array elements so
    /// `selectParkingVehicle` can update a specific analysis's `bevPNGPath`
    /// in place after each re-render.
    var parkingAnalyses: [Session.ID: [ParkingAnalysis]] = [:]

    /// `var`, not `let` — SampleData.pipelineSteps is the at-rest/default
    /// state; `uploadImage(url:)` resets to it per run and then drives it
    /// live from the worker's stderr progress events (applyProgress).
    var pipelineSteps: [PipelineStep] = SampleData.pipelineSteps
    var logLines: [LogLine] = SampleData.logLines

    /// Findings the reviewer has already accepted/rejected this session,
    /// keyed by Finding.id — drives the review workflow's progress badge.
    var reviewedFindingIDs: Set<String> = []

    private let inferenceService = InferenceService.shared
    private let carDetectionService = CarDetectionService.shared
    private let roadDamageService = RoadDamageService.shared

    /// True while a live road-damage analysis is running, so Peninjauan can
    /// disable its upload action instead of queueing a second request behind the
    /// first (the worker handles one at a time).
    var isAnalyzingRoadDamage: Bool = false

    /// The reason the last live road-damage analysis failed, or nil.
    ///
    /// The log line alone was not enough. `analyzeRoadDamage` deliberately treats
    /// a worker failure as non-fatal and only appended to `logLines` — but the log
    /// console lives on a DIFFERENT screen (Antrean), so from Peninjauan a failed
    /// analysis was indistinguishable from one that never started. The most likely
    /// failure by far is "no `.venv` on this machine", which must be legible where
    /// the reviewer actually is. Set alongside the log line, never instead of it:
    /// the log stays the durable record, this is the transient alert.
    var roadDamageError: String?

    /// The Session currently being analyzed, so worker progress events (which
    /// carry no session id of their own) update only that row's queue
    /// progress — not any of SampleData's unrelated dummy `.segmenting` rows.
    private var activeUploadSessionID: String?

    /// The most recent video uploaded via `uploadVideo` -- VideoDetectionView's
    /// entire "Hasil pemrosesan terbaru" section is keyed off this one id, so
    /// upload action and result read as one self-contained screen instead of
    /// needing a trip through Antrean + a separate Tinjauan Parkir lookup.
    var latestVideoSessionID: Session.ID?

    /// True exactly while the most recent video upload's pipeline (v13, then
    /// OFRSNet per candidate) is still running -- distinct from `activeUploadSessionID`
    /// alone, since a manual PHOTO upload (uploadImage) also sets that same
    /// property and would otherwise read as "video still processing" too.
    var isVideoProcessing: Bool {
        latestVideoSessionID != nil && activeUploadSessionID == latestVideoSessionID
    }

    init() {
        inferenceService.onProgress = { [weak self] line in
            self?.applyProgress(line)
        }
        carDetectionService.onProgress = { [weak self] progress in
            self?.applyCarDetectionProgress(progress)
        }
        roadDamageService.onProgress = { [weak self] line in
            self?.applyRoadDamageProgress(line)
        }
    }

    var queuedSessions: [Session] {
        sessions.filter(\.status.isQueued)
    }

    var batchSelectedCount: Int {
        sessions.filter(\.selectedForBatch).count
    }

    /// Findings across the whole queue that nobody has accepted or rejected yet.
    /// Counted from the queue's actual contents — it used to be `41 - reviewed`,
    /// with 41 being a number no data ever produced.
    var unreviewedFindingsCount: Int {
        reviewQueue.reduce(0) { total, frame in
            total + frame.findings.filter { !reviewedFindingIDs.contains($0.id) }.count
        }
    }

    var surveyorCount: Int {
        Set(sessions.map(\.surveyor.id)).count
    }

    /// Sessions with a real stored analysis — not `status == .done` broadly,
    /// since SampleData's dummy "done" video sessions have no ParkingAnalysis
    /// and would show up as broken empty rows in Tinjauan Parkir otherwise.
    /// A video with zero PARKED-family cars deliberately leaves its session
    /// out of this list too (an empty array is a real, successful "nothing
    /// to review" result, not a broken row, but there's nothing to show).
    var parkingReviewSessions: [Session] {
        sessions.filter { !(parkingAnalyses[$0.id]?.isEmpty ?? true) }
    }

    func toggleBatchSelection(for sessionID: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].selectedForBatch.toggle()
    }

    // MARK: - Peninjauan (road damage)

    /// Fills the review queue from the detector output already on disk.
    ///
    /// Synchronous on purpose: three CSVs totalling well under a megabyte, parsed
    /// once when the screen appears. Wrapping this in a Task would add a window
    /// where the view renders an empty queue that is about to become non-empty —
    /// a flash of the "tidak ada antrean" state for data that was always there.
    ///
    /// A missing dataset is NOT an error state: the queue simply stays empty and
    /// the reason lands in the log. UI-only work must not require the sibling
    /// checkout, same principle as the Python toolchain rule.
    func loadRoadDamageQueue() {
        do {
            let result = try RoadDamageDataset.load(includeClean: reviewIncludesCleanFrames)
            reviewQueue = result.frames
            reviewLoadWarnings = result.warnings

            // Keep the reviewer where they were if that frame survived the reload
            // (toggling clean frames on and off is the common case).
            if let current = reviewSelectionID, result.frames.contains(where: { $0.id == current }) {
                reviewSelectionID = current
            } else {
                reviewSelectionID = result.frames.first?.id
            }

            for warning in result.warnings {
                appendLog(warning, isWarning: true)
            }
            appendLog("Antrean peninjauan dimuat: \(result.frames.count) frame dari "
                      + "\(result.totalFramesInDataset) (\(result.cleanFrameCount) tanpa temuan).",
                      isWarning: false)
        } catch {
            reviewQueue = []
            reviewSelectionID = nil
            reviewLoadWarnings = [error.localizedDescription]
            appendLog(error.localizedDescription, isWarning: true)
        }
    }

    func setReviewIncludesCleanFrames(_ includeClean: Bool) {
        guard includeClean != reviewIncludesCleanFrames else { return }
        reviewIncludesCleanFrames = includeClean
        loadRoadDamageQueue()
    }

    func selectReviewFrame(id: ReviewFrame.ID) {
        guard reviewQueue.contains(where: { $0.id == id }) else { return }
        reviewSelectionID = id
    }

    /// Steps the queue by `offset`, clamped at both ends — no wraparound, so the
    /// reviewer can tell when they've reached the end of the work.
    func stepReviewFrame(by offset: Int) {
        guard !reviewQueue.isEmpty,
              let current = reviewQueuePosition else { return }
        let target = min(max(current - 1 + offset, 0), reviewQueue.count - 1)
        reviewSelectionID = reviewQueue[target].id
    }

    /// Stage 1: run the detector live on a photo and put the result at the FRONT
    /// of the review queue.
    ///
    /// Front, not back, because the reviewer just chose this image and expects to
    /// land on it. Re-analysing the same file replaces its existing entry rather
    /// than adding a duplicate — `ReviewFrame.id` is the filename stem for exactly
    /// that reason.
    ///
    /// A failure is never fatal: the queue keeps whatever it already had, the
    /// reason goes to the log *and* to `roadDamageError` for an alert on the
    /// screen the reviewer is actually looking at, and the screen stays usable.
    /// That matters more here than in the other verticals, because the most likely
    /// failure is "no worker venv on this machine", which must not look like a
    /// broken app — nor, as it did before `roadDamageError` existed, like nothing
    /// happened at all.
    func analyzeRoadDamage(url: URL) {
        guard !isAnalyzingRoadDamage else { return }
        isAnalyzingRoadDamage = true
        roadDamageError = nil
        appendLog("Menganalisis kerusakan jalan: \(url.lastPathComponent)…", isWarning: false)

        Task {
            defer { isAnalyzingRoadDamage = false }
            do {
                let frame = try await roadDamageService.analyze(imageURL: url)
                reviewQueue.removeAll { $0.id == frame.id }
                reviewQueue.insert(frame, at: 0)
                reviewSelectionID = frame.id
                selection = .review
                appendLog("Selesai: \(frame.findings.count) temuan · skor \(frame.score) "
                          + "(\(frame.severity.label)) pada \(url.lastPathComponent).",
                          isWarning: false)
            } catch {
                appendLog(error.localizedDescription, isWarning: true)
                roadDamageError = error.localizedDescription
            }
        }
    }

    /// Worker stderr -> log. Progress events are folded into a single line per
    /// stage rather than replayed verbatim: this pipeline has two stages and
    /// finishes in seconds, so a step-by-step tracker would be more chrome than
    /// information (the video path, which takes minutes, earns one).
    private func applyRoadDamageProgress(_ line: RoadDamageStderrLine) {
        switch line {
        case .event(let event):
            if event.type == "error", let error = event.error {
                appendLog("Worker kerusakan jalan: \(error)", isWarning: true)
            } else if event.type == "progress", event.state == "done", let stage = event.stage {
                appendLog("Tahap \(stage) selesai.", isWarning: false)
            }
        case .raw(let text):
            // Only surface the worker's own tagged lines; Ultralytics chatter and
            // torch warnings would otherwise flood the log.
            if text.hasPrefix("[warn]") || text.hasPrefix("[ok]") || text.hasPrefix("[device]") {
                appendLog(text, isWarning: text.hasPrefix("[warn]"))
            }
        }
    }

    func shutdownServices() async {
        await roadDamageService.shutdown()
    }

    private func appendLog(_ message: String, isWarning: Bool) {
        logLines.insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                message: message,
                                isWarning: isWarning),
                        at: 0)
    }

    /// Called from ProcessingQueueView's "Unggah foto…" toolbar action.
    func uploadImage(url: URL) {
        let sessionID = "upload-\(UUID().uuidString.prefix(8))"
        let session = Session(
            id: sessionID,
            roadName: url.deletingPathExtension().lastPathComponent,
            kmMarker: nil,
            date: Self.uploadDateFormatter.string(from: Date()),
            surveyor: Self.operatorSurveyor,
            clipCount: 1,
            // `Session` is shaped for a recorded drive (duration, distance,
            // GPS track); a single uploaded photo has no real analogue for
            // most of those fields. Honest placeholders, not a hidden
            // approximation — restructuring Session touches SessionInboxView's
            // Table columns and is out of this integration's scope.
            duration: "—",
            distanceKm: 0,
            gpsAccuracyM: nil,
            gpsHz: nil,
            gpsGapNote: nil,
            sizeGB: Self.fileSizeGB(at: url),
            status: .segmenting(progress: 0),
            segmentCount: nil,
            selectedForBatch: false
        )
        sessions.append(session)
        activeUploadSessionID = sessionID
        pipelineSteps = SampleData.pipelineSteps
        selection = .queue

        Task {
            await runAnalysis(sessionID: sessionID, imageURL: url)
        }
    }

    private func runAnalysis(sessionID: String, imageURL: URL) async {
        do {
            // requestID == sessionID: doubles as the worker's result_cache key,
            // so selectParkingVehicle can re-render this analysis's BEV later.
            // Also becomes this ParkingAnalysis's own `id` — a manual photo
            // upload always produces exactly one analysis per session, so
            // reusing the session id here is unambiguous, same as before
            // parkingAnalyses became an array.
            let result = try await inferenceService.analyze(imagePath: imageURL, requestID: sessionID)
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .done)

            parkingAnalyses[sessionID] = [ParkingAnalysis(
                id: sessionID,
                sessionID: sessionID,
                imageURL: imageURL,
                imageWidth: result.imageWidth,
                imageHeight: result.imageHeight,
                summary: result.summary,
                bevPNGPath: result.bevPNGPath,
                carCandidate: nil
            )]
            selection = .parkingReview
        } catch {
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .failed(reason: error.localizedDescription))
            logLines.insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Analisis gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

    /// Called from ProcessingQueueView's "Unggah video…" toolbar action —
    /// the real end-to-end pipeline: v13 finds every car it classifies as
    /// PARKED (any STOP_CLASS in that family, including the depth tiebreak —
    /// not filtered down to only the ones inside a sign's zone, since
    /// OFRSNet measures physical road blockage and doesn't care about signs
    /// at all), then each one's CLEAN screenshot (see CarCandidate.fileClean)
    /// goes through the same OFRSNet analyze() call uploadImage already uses,
    /// one at a time — sequential, not concurrent, since both v13 and OFRSNet
    /// are already heavy single-process workloads and this is a first
    /// integration pass, not a throughput-tuned one.
    func uploadVideo(url: URL) {
        let sessionID = "video-\(UUID().uuidString.prefix(8))"
        let session = Session(
            id: sessionID,
            roadName: url.deletingPathExtension().lastPathComponent,
            kmMarker: nil,
            date: Self.uploadDateFormatter.string(from: Date()),
            surveyor: Self.operatorSurveyor,
            clipCount: 1,
            // Same honest-placeholder reasoning as uploadImage's Session —
            // a v13 run has no GPS track of its own either.
            duration: "—",
            distanceKm: 0,
            gpsAccuracyM: nil,
            gpsHz: nil,
            gpsGapNote: nil,
            sizeGB: Self.fileSizeGB(at: url),
            status: .segmenting(progress: 0),
            segmentCount: nil,
            selectedForBatch: false
        )
        sessions.append(session)
        activeUploadSessionID = sessionID
        latestVideoSessionID = sessionID
        pipelineSteps = Self.videoPipelineSteps
        selection = .videoDetection

        Task {
            await runVideoAnalysis(sessionID: sessionID, videoURL: url)
        }
    }

    private func runVideoAnalysis(sessionID: String, videoURL: URL) async {
        do {
            pipelineSteps[0].state = .active
            let workDir = Self.carDetectionWorkDir(sessionID: sessionID)
            let detection = try await carDetectionService.detect(video: videoURL, workDir: workDir)
            pipelineSteps[0].state = .done
            pipelineSteps[0].detail = "selesai"
            pipelineSteps[0].subProgress = 1.0

            let candidates = detection.summary.carsDetectedParked
            guard !candidates.isEmpty else {
                activeUploadSessionID = nil
                updateSessionStatus(sessionID, .done)
                parkingAnalyses[sessionID] = []
                pipelineSteps[1].detail = "tidak ada"
                logLines.insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                        message: "Tidak ada mobil PARKED terdeteksi di video ini.",
                                        isWarning: false), at: 0)
                return
            }

            pipelineSteps[1].state = .active
            var analyses: [ParkingAnalysis] = []
            for (index, candidate) in candidates.enumerated() {
                let imagePath = detection.screenshotDir.appendingPathComponent(candidate.fileClean)
                // Unique per candidate (not per session) -- each becomes its
                // own OFRSNet result_cache entry, so selectParkingVehicle can
                // later re-render THIS specific car's BEV without colliding
                // with another car from the same video.
                let requestID = "\(sessionID)#\(candidate.trackID)"
                do {
                    let result = try await inferenceService.analyze(imagePath: imagePath, requestID: requestID)
                    analyses.append(ParkingAnalysis(
                        id: requestID, sessionID: sessionID, imageURL: imagePath,
                        imageWidth: result.imageWidth, imageHeight: result.imageHeight,
                        summary: result.summary, bevPNGPath: result.bevPNGPath,
                        carCandidate: candidate
                    ))
                } catch {
                    logLines.insert(LogLine(
                        time: Self.logTimeFormatter.string(from: Date()),
                        message: "OFRSNet gagal untuk mobil #\(candidate.trackID): \(error.localizedDescription)",
                        isWarning: true), at: 0)
                }
                pipelineSteps[1].subProgress = Double(index + 1) / Double(candidates.count)
                pipelineSteps[1].detail = "\(index + 1)/\(candidates.count)"
            }
            pipelineSteps[1].state = .done

            activeUploadSessionID = nil
            updateSessionStatus(sessionID, analyses.isEmpty ? .failed(reason: "Semua analisis OFRSNet gagal.") : .done)
            parkingAnalyses[sessionID] = analyses
            // No forced navigation here (unlike uploadImage's plain-photo path) --
            // VideoDetectionView is already showing this session's progress and
            // will reactively switch to showing `analyses` once `isVideoProcessing`
            // flips false, so the user never leaves the screen they started on.
        } catch {
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .failed(reason: error.localizedDescription))
            logLines.insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Deteksi mobil gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

    /// Called when the user taps a different vehicle overlay in Tinjauan
    /// Parkir: re-renders the BEV highlighting that vehicle's share, for one
    /// specific analysis (a session can hold several since uploadVideo).
    /// Leaves the existing `bevPNGPath` in place on failure (e.g. the worker
    /// evicted this analysis from its cache) rather than breaking the panel.
    func selectParkingVehicle(sessionID: Session.ID, analysisID: ParkingAnalysis.ID, vehicleID: Int?) async {
        guard let index = parkingAnalyses[sessionID]?.firstIndex(where: { $0.id == analysisID }) else { return }
        do {
            let bevPath = try await inferenceService.renderBEV(analysisID: analysisID, vehicleID: vehicleID)
            parkingAnalyses[sessionID]?[index].bevPNGPath = bevPath
        } catch {
            logLines.insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Render ulang BEV gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

    private func applyCarDetectionProgress(_ progress: CarDetectionProgress) {
        guard !pipelineSteps.isEmpty else { return }
        pipelineSteps[0].subProgress = progress.fraction
        pipelineSteps[0].detail = "\(progress.framesDone)/\(progress.framesTotal) frame"
        updateQueueProgress()
    }

    /// `~/Library/Application Support/JalanKita Mac/car-detection/<sessionID>/`
    /// — a real, writable, per-session location, same reasoning as
    /// worker_main.py's own `--out` redirect for the disturbance worker.
    private static func carDetectionWorkDir(sessionID: String) -> URL {
        Self.appSupportDir()
            .appendingPathComponent("car-detection", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    private static func appSupportDir() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    /// v13's own two natural stages, coarser than the disturbance worker's
    /// four — v13 only ever reports whole-video frame progress, and OFRSNet
    /// then runs once per PARKED-family car it found (subProgress here
    /// tracks "N of M candidates scored", not model-internal stages).
    private static let videoPipelineSteps: [PipelineStep] = [
        PipelineStep(id: 1, title: "Deteksi & tracking mobil", state: .waiting,
                     detail: "menunggu",
                     stats: "YOLOv8n-seg+ByteTrack+epipolar/FoE+MiDaS depth tiebreak (lambat, akurat)",
                     subProgress: 0),
        PipelineStep(id: 2, title: "Analisis disturbance per mobil (OFRSNet)", state: .waiting,
                     detail: "menunggu",
                     stats: "satu run OFRSNet per mobil PARKED yang terdeteksi",
                     subProgress: 0),
    ]

    private func applyProgress(_ line: WorkerStderrLine) {
        let update = PipelineProgressParser.handle(line)
        if let log = update.logLine {
            logLines.insert(log, at: 0)
        }
        if let stepID = update.stepID, let state = update.stepState,
           let index = pipelineSteps.firstIndex(where: { $0.id == stepID }) {
            pipelineSteps[index].state = state
            pipelineSteps[index].detail = state == .done ? "selesai" : "berjalan"
            if state == .active, index > 0 {
                pipelineSteps[index - 1].state = .done
            }
        }
        updateQueueProgress()
    }

    private func updateQueueProgress() {
        guard let activeUploadSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeUploadSessionID }),
              case .segmenting = sessions[index].status else { return }
        let doneCount = pipelineSteps.filter { $0.state == .done }.count
        let progress = pipelineSteps.isEmpty ? 0 : Double(doneCount) / Double(pipelineSteps.count)
        sessions[index].status = .segmenting(progress: progress)
    }

    private func updateSessionStatus(_ sessionID: String, _ status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].status = status
    }

    private static func fileSizeGB(at url: URL) -> Double {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        else { return 0 }
        return Double(size ?? 0) / 1_073_741_824
    }

    private static let operatorSurveyor = Surveyor(id: "operator", name: "Operator")

    private static let uploadDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        f.locale = Locale(identifier: "id_ID")
        return f
    }()

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
