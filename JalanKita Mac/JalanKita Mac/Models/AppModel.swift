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
//  (parkingAnalyses), never Peninjauan (reviewFrame) — that screen stays
//  purely DummySegmentation-driven, untouched by real uploads.
//

import Foundation
import Observation

@Observable
final class AppModel {
    var selection: AppSection = .sessionInbox

    var sessions: [Session] = SampleData.sessions
    var segments: [SegmentResult] = SampleData.segments

    /// Randomized each launch — see DummySegmentation.swift. Peninjauan's
    /// road-damage findings are entirely dummy; real uploads never touch this.
    var reviewFrame: ReviewFrame = DummySegmentation.makeReviewFrame()

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
    }

    var queuedSessions: [Session] {
        sessions.filter(\.status.isQueued)
    }

    var batchSelectedCount: Int {
        sessions.filter(\.selectedForBatch).count
    }

    var unreviewedFindingsCount: Int {
        max(41 - reviewedFindingIDs.count, 0)
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
