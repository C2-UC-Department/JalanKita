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
//  second navigation mechanism — see the integration plan's "Concrete UI
//  wiring" section.
//

import Foundation
import Observation

@Observable
final class AppModel {
    var selection: AppSection = .sessionInbox

    var sessions: [Session] = SampleData.sessions
    var segments: [SegmentResult] = SampleData.segments

    /// Randomized each launch — see DummySegmentation.swift. Stands in
    /// for real model output until a real photo has been analyzed; after
    /// `uploadImage(url:)` completes, this holds the real result instead.
    var reviewFrame: ReviewFrame = DummySegmentation.makeReviewFrame()

    /// `var`, not `let` — SampleData.pipelineSteps is the at-rest/default
    /// state; `uploadImage(url:)` resets to it per run and then drives it
    /// live from the worker's stderr progress events (applyProgress).
    var pipelineSteps: [PipelineStep] = SampleData.pipelineSteps
    var logLines: [LogLine] = SampleData.logLines

    /// Findings the reviewer has already accepted/rejected this session,
    /// keyed by Finding.id — drives the review workflow's progress badge.
    var reviewedFindingIDs: Set<String> = []

    private let inferenceService = InferenceService.shared

    /// The Session currently being analyzed, so worker progress events (which
    /// carry no session id of their own) update only that row's queue
    /// progress — not any of SampleData's unrelated dummy `.segmenting` rows.
    private var activeUploadSessionID: String?

    init() {
        inferenceService.onProgress = { [weak self] line in
            self?.applyProgress(line)
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
            let result = try await inferenceService.analyze(imagePath: imageURL)
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .done)

            // The other defect system (potholes/cracking) stays fully dummy —
            // only blockedPark findings come from the real pipeline. This is
            // the concrete form of "two systems coexist by defect type."
            let realFindings = FindingMapper.findings(from: result)
            let dummyFindings = DummySegmentation.randomFindings()
                .filter { $0.defectType != .blockedPark }
            let allFindings = realFindings + dummyFindings
            let (score, deductions) = DummySegmentation.severityBreakdown(for: allFindings)

            reviewFrame = ReviewFrame(
                id: sessionID,
                roadName: imageURL.deletingPathExtension().lastPathComponent,
                indexInQueue: 1,
                totalInQueue: 1,
                frameNumber: "000001",
                timecode: "00:00:00",
                severity: Severity(score: score),
                score: score,
                isProvisional: true,
                segmentLabel: "Unggahan",
                kmMarker: "—",
                coordinate: "—",
                gpsAccuracyM: 0,
                findings: allFindings,
                startScore: 100,
                deductions: deductions,
                imageURL: imageURL
            )
            selection = .review
        } catch {
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .failed(reason: error.localizedDescription))
            logLines.insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Analisis gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

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
