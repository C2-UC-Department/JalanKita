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

import AppKit
import AVFoundation
import CloudKit
import Foundation
import Observation
import JalanKitaKit

@Observable
final class AppModel {
    var selection: AppSection = .sessionInbox

    /// Persisted to disk once any real session exists (upload or sync).
    /// Starts empty, not sample data — a genuinely first launch should show
    /// a real empty state, not 7 fake Surabaya sessions that look real but
    /// aren't. Previously in-memory only, which meant a crash or relaunch
    /// silently erased every uploaded/synced session with no way back to
    /// it — not just an inconvenience, but the thing that made a "Buka
    /// Video" crash unreproducible after the app quit.
    var sessions: [Session] = AppModel.loadSessions() ?? [] {
        didSet { Self.saveSessions(sessions) }
    }
    var segments: [SegmentResult] = SampleData.segments

    /// Randomized each launch — see DummySegmentation.swift. Peninjauan's
    /// road-damage findings are entirely dummy; real uploads never touch this.
    var reviewFrame: ReviewFrame = DummySegmentation.makeReviewFrame()

    /// Real parking-disturbance results, keyed by session id — "Tinjauan
    /// Parkir"'s data. A single manual photo upload produces exactly one
    /// element; a video upload (uploadVideo, via v13) can produce zero to
    /// many, one per car v13 found parked. `var` array elements so
    /// `selectParkingVehicle` can update a specific analysis's `bevPNGPath`
    /// in place after each re-render. Persisted alongside `sessions`, for
    /// the same reason.
    var parkingAnalyses: [Session.ID: [ParkingAnalysis]] = AppModel.loadParkingAnalyses() {
        didSet { Self.saveParkingAnalyses(parkingAnalyses) }
    }

    /// Per session, not one shared array — a session's own steps are seeded
    /// when its processing starts (`Self.photoPipelineSteps`/
    /// `Self.videoPipelineSteps`) and then driven live from the worker's
    /// stderr/progress events (`applyProgress`/`applyCarDetectionProgress`).
    /// Persisted like `parkingAnalyses`, so a session's history survives a
    /// relaunch and clicking any past session in Antrean shows its own real
    /// data, not whatever a single shared array last happened to hold.
    var pipelineSteps: [Session.ID: [PipelineStep]] = AppModel.loadPipelineSteps() {
        didSet { Self.savePipelineSteps(pipelineSteps) }
    }
    var logLines: [Session.ID: [LogLine]] = AppModel.loadLogLines() {
        didSet { Self.saveLogLines(logLines) }
    }

    /// Findings the reviewer has already accepted/rejected this session,
    /// keyed by Finding.id — drives the review workflow's progress badge.
    var reviewedFindingIDs: Set<String> = []

    private let inferenceService = InferenceService.shared
    private let carDetectionService = CarDetectionService.shared

    let cloudKitSyncEngine: CloudKitSyncEngine
    private let syncedSessionIngestor: SyncedSessionIngestor

    /// Zones for surveyors this Mac has ingested at least one real synced
    /// session from — lets a manually-uploaded video (`uploadVideo`, no GPS
    /// of its own) still automatically reach an iPhone afterward (see
    /// `pushCompletedManualUploads`), for testing the iOS Parking Report
    /// screen against real street footage without needing to drive around
    /// with the phone. Keyed by surveyor display name. Only populated once
    /// a real session has synced from that surveyor — that's how this Mac
    /// learns the zone exists.
    ///
    /// Persisted to disk (unlike `sessions`, which is not): CloudKit's
    /// change feed only ever redelivers a record once, so on a fresh
    /// launch a previously-ingested surveyor's zone would otherwise be
    /// unrecoverable — the sync engine's change token has already moved
    /// past that Session record, and nothing will ever refetch it just to
    /// repopulate this map.
    var surveyorZones: [String: CKRecordZone.ID] = [:] {
        didSet { Self.saveSurveyorZones(surveyorZones) }
    }

    /// The Session currently being analyzed, so worker progress events (which
    /// carry no session id of their own) update only that row's queue
    /// progress — not any of SampleData's unrelated dummy `.segmenting` rows.
    private var activeUploadSessionID: String?

    init() {
        surveyorZones = Self.loadSurveyorZones()
        cloudKitSyncEngine = CloudKitSyncEngine(appSupportDir: Self.appSupportDir())
        syncedSessionIngestor = SyncedSessionIngestor(workDir: Self.syncedSessionsDir())

        inferenceService.onProgress = { [weak self] line in
            self?.applyProgress(line)
        }
        carDetectionService.onProgress = { [weak self] progress in
            self?.applyCarDetectionProgress(progress)
        }
        syncedSessionIngestor.appModel = self
        cloudKitSyncEngine.ingestDelegate = syncedSessionIngestor

        // Launch-time sync, plus a re-sync every time the app regains
        // focus — the closest Mac equivalent of iOS's scenePhase-based
        // foreground trigger. Without this, nothing would fetch until the
        // user manually opened "Sinkronisasi iCloud" and tapped the button.
        Task { await self.syncNow() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.syncNow() }
        }
    }

    /// Manual/foreground sync trigger — no push infrastructure in this
    /// phase (see the phase plan), so this is the only way changes
    /// actually move between the Mac and CloudKit.
    func syncNow() async {
        pushCompletedManualUploads()
        await cloudKitSyncEngine.syncNow()
    }

    /// Session IDs from a manual upload (uploadImage/uploadVideo) already
    /// pushed to iCloud this run — avoids re-pushing identical records on
    /// every syncNow(). Persisted, now that `sessions` is too: without this,
    /// every relaunch would re-upload the same images/BEV assets for every
    /// already-pushed session on its first sync.
    private var manualUploadsPushed: Set<Session.ID> = AppModel.loadManualUploadsPushed() {
        didSet { Self.saveManualUploadsPushed(manualUploadsPushed) }
    }

    /// Any manually-uploaded (not iPhone-recorded) session that's finished
    /// processing gets pushed to every surveyor zone this Mac knows about —
    /// no picking who to send it to. `recordedDate == nil` is the existing,
    /// already-reliable signal that a session came from `uploadImage`/
    /// `uploadVideo` rather than a real iPhone recording (those always set
    /// it). With today's single-surveyor testing this broadcast is
    /// equivalent to "the" zone; multi-surveyor semantics may need
    /// revisiting once that's actually exercised.
    private func pushCompletedManualUploads() {
        guard !surveyorZones.isEmpty else { return }
        for session in sessions
        where session.recordedDate == nil && session.status == .done && !manualUploadsPushed.contains(session.id) {
            for zoneID in surveyorZones.values {
                cloudKitSyncEngine.enqueueSessionUpdate(session, zoneID: zoneID)
                for analysis in parkingAnalyses[session.id] ?? [] {
                    pushParkingResult(analysis, zoneID: zoneID)
                }
            }
            manualUploadsPushed.insert(session.id)
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

    /// Sessions synced from an iPhone that haven't been started yet — see
    /// `startProcessing`. A manual upload never sits in this state (it
    /// starts immediately), so this is effectively "how many synced
    /// sessions are waiting for a batch-process click."
    var newSessionsCount: Int {
        sessions.filter { if case .readyToProcess = $0.status { return true }; return false }.count
    }

    var totalDistanceKm: Double {
        sessions.reduce(0) { $0 + $1.distanceKm }
    }

    var totalSizeGB: Double {
        sessions.reduce(0) { $0 + $1.sizeGB }
    }

    var doneSessionsCount: Int {
        sessions.filter { $0.status == .done }.count
    }

    /// Finished sessions — the population `ReportsView` ("Laporan") lists.
    var doneSessions: [Session] {
        sessions.filter { $0.status == .done }
    }

    var pendingSessionsCount: Int {
        sessions.count - doneSessionsCount
    }

    var attentionNeededCount: Int {
        sessions.filter {
            switch $0.status {
            case .degraded, .failed: return true
            default: return false
            }
        }.count
    }

    var pendingSizeGB: Double {
        sessions.filter { $0.status != .done }.reduce(0) { $0 + $1.sizeGB }
    }

    var totalVehiclesAnalyzed: Int {
        parkingAnalyses.values.reduce(0) { $0 + $1.count }
    }

    /// Real parking-violation count across every session's results — the
    /// pipeline that actually works today, replacing the old fake
    /// "segments ready to report" tile (segments have no real producer yet).
    var disturbanceCount: Int {
        parkingAnalyses.values.reduce(0) { count, analyses in
            count + analyses.filter { $0.carCandidate?.disturbance == true }.count
        }
    }

    func toggleBatchSelection(for sessionID: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].selectedForBatch.toggle()
    }

    /// Called from Session Inbox's "Unggah…" toolbar menu.
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
        pipelineSteps[sessionID] = Self.photoPipelineSteps
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
            selection = .sessionInbox
        } catch {
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .failed(reason: error.localizedDescription))
            logLines[sessionID, default: []].insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Analisis gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

    /// Called from Session Inbox's "Unggah…" toolbar menu —
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
        // Copies out of the OS temp directory `SessionInboxView`'s
        // `.fileImporter` staged it into — that directory can be purged by
        // macOS at any time, so anything that wants this video later
        // (Tinjauan Parkir's player) needs it somewhere durable. Falls back
        // to the original staged URL if the copy fails; the pipeline can
        // still run against it this once, it just won't be replayable later.
        let durableURL = Self.copyToManualUploadsDir(sourceURL: url, sessionID: sessionID) ?? url
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
            sizeGB: Self.fileSizeGB(at: durableURL),
            status: .segmenting(progress: 0),
            segmentCount: nil,
            selectedForBatch: false
        )
        sessions.append(session)
        activeUploadSessionID = sessionID
        pipelineSteps[sessionID] = Self.videoPipelineSteps
        selection = .queue

        Task {
            await runVideoAnalysis(sessionID: sessionID, videoURL: durableURL)
        }
    }

    private func runVideoAnalysis(sessionID: String, videoURL: URL) async {
        // Needed so the Tinjauan Parkir timeline has a real total width to
        // render against — `uploadVideo`'s placeholder Session otherwise
        // leaves `durationSeconds` nil (it has no GPS-derived duration the
        // way a synced session does).
        if let duration = await Self.probeDurationSeconds(url: videoURL),
           let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].durationSeconds = duration
        }
        do {
            pipelineSteps[sessionID]?[0].state = .active
            // v13 only ever reports frame-progress numbers (no structured
            // log events the way the disturbance worker does), so without
            // this the log console stays completely silent through the
            // entire car-detection stage — easy to mistake for "not
            // running" during model load, before the first progress line.
            logLines[sessionID, default: []].insert(LogLine(
                time: Self.logTimeFormatter.string(from: Date()),
                message: "Memulai deteksi mobil (v13)…", isWarning: false), at: 0)
            let workDir = Self.carDetectionWorkDir(sessionID: sessionID)
            let detection = try await carDetectionService.detect(video: videoURL, workDir: workDir)
            pipelineSteps[sessionID]?[0].state = .done
            pipelineSteps[sessionID]?[0].detail = "selesai"
            pipelineSteps[sessionID]?[0].subProgress = 1.0

            let candidates = detection.summary.carsDetectedParked
            logLines[sessionID, default: []].insert(LogLine(
                time: Self.logTimeFormatter.string(from: Date()),
                message: "Deteksi mobil selesai — \(candidates.count) kandidat terparkir.", isWarning: false), at: 0)
            guard !candidates.isEmpty else {
                activeUploadSessionID = nil
                updateSessionStatus(sessionID, .done)
                parkingAnalyses[sessionID] = []
                pipelineSteps[sessionID]?[1].detail = "tidak ada"
                logLines[sessionID, default: []].insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                        message: "Tidak ada mobil PARKED terdeteksi di video ini.",
                                        isWarning: false), at: 0)
                return
            }

            pipelineSteps[sessionID]?[1].state = .active
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
                        carCandidate: candidate, sessionRelativeSeconds: candidate.midSeconds
                    ))
                } catch {
                    logLines[sessionID, default: []].insert(LogLine(
                        time: Self.logTimeFormatter.string(from: Date()),
                        message: "OFRSNet gagal untuk mobil #\(candidate.trackID): \(error.localizedDescription)",
                        isWarning: true), at: 0)
                }
                pipelineSteps[sessionID]?[1].subProgress = Double(index + 1) / Double(candidates.count)
                pipelineSteps[sessionID]?[1].detail = "\(index + 1)/\(candidates.count)"
            }
            pipelineSteps[sessionID]?[1].state = .done

            activeUploadSessionID = nil
            updateSessionStatus(sessionID, analyses.isEmpty ? .failed(reason: "Semua analisis OFRSNet gagal.") : .done)
            parkingAnalyses[sessionID] = analyses
            if !analyses.isEmpty {
                selection = .sessionInbox
            }
        } catch {
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .failed(reason: error.localizedDescription))
            logLines[sessionID, default: []].insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Deteksi mobil gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

    /// Entry point for a session that arrived via CloudKit (see
    /// `SyncedSessionIngestor`) — deliberately NOT a call into `uploadVideo`,
    /// which synthesizes a brand-new placeholder `Session` with fabricated
    /// fields. A synced session already carries real GPS/duration/surveyor
    /// data from the iPhone that must be preserved, so this inserts/updates
    /// that real `Session` instead.
    ///
    /// Deliberately does NOT start processing — unlike a manual upload
    /// (which starts immediately, since a human just explicitly chose to
    /// upload it), a synced session lands in Sesi Masuk at whatever status
    /// iOS gave it (`.readyToProcess`/`.degraded`) and waits for a real
    /// batch-select + "Proses" click (see `startProcessing`). `clipURLs` is
    /// intentionally unused here — `startProcessing` reconstructs them
    /// later via `SessionVideoAssetBuilder`, from the same stable path
    /// `SyncedSessionIngestor` already wrote them to.
    func ingestSyncedSession(_ session: Session, clipURLs: [URL], zoneID: CKRecordZone.ID) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        surveyorZones[session.surveyor.name] = zoneID
    }

    /// Real trigger for a synced session sitting at `.readyToProcess` —
    /// called from Session Inbox's batch "Proses" action and
    /// `SessionDetailPanel`'s "Proses sekarang" button. Multi-clip sessions
    /// run car detection PER CLIP and merge candidate lists — concatenating
    /// clips first would reintroduce the lossy re-encode step the iOS
    /// side's per-clip finalization (`movieFragmentInterval`) was chosen to
    /// avoid.
    func startProcessing(sessionID: Session.ID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let clipURLs = SessionVideoAssetBuilder.clipURLs(for: session)
        guard !clipURLs.isEmpty else {
            logLines[sessionID, default: []].insert(LogLine(
                time: Self.logTimeFormatter.string(from: Date()),
                message: "Tidak menemukan berkas klip untuk sesi ini.",
                isWarning: true), at: 0)
            return
        }
        guard let zoneID = surveyorZones[session.surveyor.name] else {
            logLines[sessionID, default: []].insert(LogLine(
                time: Self.logTimeFormatter.string(from: Date()),
                message: "Zona iCloud surveyor ini tidak diketahui — tidak bisa memproses.",
                isWarning: true), at: 0)
            return
        }
        activeUploadSessionID = sessionID
        pipelineSteps[sessionID] = Self.videoPipelineSteps
        updateSessionStatus(sessionID, .segmenting(progress: 0))
        Task {
            await runSyncedSessionAnalysis(sessionID: sessionID, clipURLs: clipURLs, zoneID: zoneID)
        }
    }

    /// Removes a session and everything derived from it — the metadata
    /// (`parkingAnalyses`/`pipelineSteps`/`logLines`), and its on-disk video
    /// files, so a deleted session doesn't leave orphaned footage behind.
    /// Also deletes the session's CloudKit record, which CloudKit cascades
    /// to its Clip/GPSTrack/ParkingResult children server-side (they
    /// reference the Session via a `.deleteSelf` `CKRecord.Reference`), so
    /// the deletion propagates to every other device synced to this
    /// surveyor's zone rather than staying local-only.
    func deleteSession(_ sessionID: Session.ID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let zoneID = surveyorZones[session.surveyor.name]
        performLocalSessionCleanup(sessionID: sessionID, session: session)

        if let zoneID {
            cloudKitSyncEngine.enqueueSessionDeletion(sessionID: sessionID, zoneID: zoneID)
            Task { await syncNow() }
        }
    }

    /// The Session record for `sessionID` was deleted on another device —
    /// clean up locally without re-deleting it from CloudKit (it's already
    /// gone there). Called by `SyncedSessionIngestor.didDeleteSession`.
    func applyIncomingSessionDeletion(_ sessionID: Session.ID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        performLocalSessionCleanup(sessionID: sessionID, session: session)
    }

    private func performLocalSessionCleanup(sessionID: Session.ID, session: Session) {
        sessions.removeAll { $0.id == sessionID }
        parkingAnalyses.removeValue(forKey: sessionID)
        pipelineSteps.removeValue(forKey: sessionID)
        logLines.removeValue(forKey: sessionID)
        manualUploadsPushed.remove(sessionID)

        let fm = FileManager.default
        try? fm.removeItem(at: Self.syncedSessionsDir().appendingPathComponent(sessionID, isDirectory: true))
        try? fm.removeItem(at: Self.manualUploadsDir(sessionID: sessionID))
        try? fm.removeItem(at: Self.carDetectionWorkDir(sessionID: sessionID))
        for clipIndex in 0..<session.clipCount {
            try? fm.removeItem(at: Self.carDetectionWorkDir(sessionID: "\(sessionID)-clip\(clipIndex)"))
        }
    }

    /// Renames a manually-uploaded session (one with no `recordedDate` —
    /// i.e. added via "Unggah…", not recorded on an iPhone; real-recording
    /// sessions aren't renamable here). Pushes the rename to every known
    /// surveyor zone if the session was already synced, mirroring
    /// `pushCompletedManualUploads`'s broadcast pattern — a manual upload
    /// has no single "owning" zone of its own, so it's copied into every
    /// zone this Mac knows about, same as its initial push.
    func renameSession(_ sessionID: Session.ID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].recordedDate == nil,
              sessions[index].roadName != trimmed
        else { return }
        sessions[index].roadName = trimmed

        guard manualUploadsPushed.contains(sessionID), !surveyorZones.isEmpty else { return }
        let session = sessions[index]
        for zoneID in surveyorZones.values {
            cloudKitSyncEngine.enqueueSessionUpdate(session, zoneID: zoneID)
        }
        Task { await syncNow() }
    }

    private func runSyncedSessionAnalysis(sessionID: String, clipURLs: [URL], zoneID: CKRecordZone.ID) async {
        // Each clip's own v13 tracking run reports frame/second numbers
        // relative to that clip alone (starting at 0:00) — this cumulative
        // offset array is what turns those clip-relative numbers into one
        // consistent session timeline for Tinjauan Parkir.
        var clipOffsets: [Double] = []
        var cumulativeOffset: Double = 0
        for clipURL in clipURLs {
            clipOffsets.append(cumulativeOffset)
            cumulativeOffset += await Self.probeDurationSeconds(url: clipURL) ?? 0
        }

        pipelineSteps[sessionID]?[0].state = .active
        logLines[sessionID, default: []].insert(LogLine(
            time: Self.logTimeFormatter.string(from: Date()),
            message: "Memulai deteksi mobil (v13) untuk \(clipURLs.count) klip…", isWarning: false), at: 0)
        var candidatePairs: [(candidate: CarCandidate, screenshotDir: URL, clipIndex: Int)] = []
        for (clipIndex, clipURL) in clipURLs.enumerated() {
            let workDir = Self.carDetectionWorkDir(sessionID: "\(sessionID)-clip\(clipIndex)")
            do {
                let detection = try await carDetectionService.detect(video: clipURL, workDir: workDir)
                candidatePairs += detection.summary.carsDetectedParked.map { ($0, detection.screenshotDir, clipIndex) }
            } catch {
                logLines[sessionID, default: []].insert(LogLine(
                    time: Self.logTimeFormatter.string(from: Date()),
                    message: "Deteksi mobil gagal (klip \(clipIndex), sesi tersinkron): \(error.localizedDescription)",
                    isWarning: true), at: 0)
            }
            updateSessionStatus(sessionID, .segmenting(progress: Double(clipIndex + 1) / Double(clipURLs.count) / 2))
        }
        pipelineSteps[sessionID]?[0].state = .done
        pipelineSteps[sessionID]?[0].detail = "selesai"
        pipelineSteps[sessionID]?[0].subProgress = 1.0
        logLines[sessionID, default: []].insert(LogLine(
            time: Self.logTimeFormatter.string(from: Date()),
            message: "Deteksi mobil selesai — \(candidatePairs.count) kandidat terparkir.", isWarning: false), at: 0)

        guard !candidatePairs.isEmpty else {
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .done)
            parkingAnalyses[sessionID] = []
            pipelineSteps[sessionID]?[1].detail = "tidak ada"
            pushSessionStatus(sessionID: sessionID, zoneID: zoneID)
            await syncNow()
            return
        }

        pipelineSteps[sessionID]?[1].state = .active
        var analyses: [ParkingAnalysis] = []
        for (index, pair) in candidatePairs.enumerated() {
            let imagePath = pair.screenshotDir.appendingPathComponent(pair.candidate.fileClean)
            let requestID = "\(sessionID)#\(pair.candidate.trackID)"
            do {
                let result = try await inferenceService.analyze(imagePath: imagePath, requestID: requestID)
                let analysis = ParkingAnalysis(
                    id: requestID, sessionID: sessionID, imageURL: imagePath,
                    imageWidth: result.imageWidth, imageHeight: result.imageHeight,
                    summary: result.summary, bevPNGPath: result.bevPNGPath, carCandidate: pair.candidate,
                    sessionRelativeSeconds: clipOffsets[pair.clipIndex] + pair.candidate.midSeconds
                )
                analyses.append(analysis)
                pushParkingResult(analysis, zoneID: zoneID)
            } catch {
                logLines[sessionID, default: []].insert(LogLine(
                    time: Self.logTimeFormatter.string(from: Date()),
                    message: "OFRSNet gagal untuk mobil #\(pair.candidate.trackID) (sesi tersinkron): \(error.localizedDescription)",
                    isWarning: true), at: 0)
            }
            pipelineSteps[sessionID]?[1].subProgress = Double(index + 1) / Double(candidatePairs.count)
            pipelineSteps[sessionID]?[1].detail = "\(index + 1)/\(candidatePairs.count)"
            updateSessionStatus(sessionID, .segmenting(progress: 0.5 + Double(index + 1) / Double(candidatePairs.count) / 2))
        }
        pipelineSteps[sessionID]?[1].state = .done

        activeUploadSessionID = nil
        updateSessionStatus(sessionID, analyses.isEmpty ? .failed(reason: "Semua analisis OFRSNet gagal.") : .done)
        parkingAnalyses[sessionID] = analyses
        pushSessionStatus(sessionID: sessionID, zoneID: zoneID)
        // pushSessionStatus/pushParkingResult only stage records in
        // CloudKitSyncEngine.outgoingRecords — nothing actually reaches the
        // server until a syncNow() runs, and this Mac otherwise only syncs
        // on launch or when it regains focus. Without this, results sit
        // queued in memory indefinitely whenever the Mac stays frontmost
        // through the whole analysis run (the common case).
        await syncNow()
    }

    private func pushSessionStatus(sessionID: String, zoneID: CKRecordZone.ID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        cloudKitSyncEngine.enqueueSessionUpdate(session, zoneID: zoneID)
    }

    private func pushParkingResult(_ analysis: ParkingAnalysis, zoneID: CKRecordZone.ID) {
        guard let summaryData = try? JSONEncoder().encode(analysis.summary),
              let summaryJSON = String(data: summaryData, encoding: .utf8) else { return }
        let result = SyncedParkingResult(
            sessionID: analysis.sessionID,
            candidateID: analysis.carCandidate.map { String($0.trackID) } ?? analysis.id,
            sourceKind: analysis.carCandidate != nil ? "videoCandidate" : "manual",
            carTrackID: analysis.carCandidate?.trackID,
            disturbance: analysis.carCandidate?.disturbance,
            imageWidth: analysis.imageWidth,
            imageHeight: analysis.imageHeight,
            summaryJSON: summaryJSON
        )
        let bevURL = analysis.bevPNGPath.map { URL(fileURLWithPath: $0) }
        cloudKitSyncEngine.enqueueParkingResult(result, zoneID: zoneID, imageFileURL: analysis.imageURL, bevFileURL: bevURL)
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
            logLines[sessionID, default: []].insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                    message: "Render ulang BEV gagal: \(error.localizedDescription)",
                                    isWarning: true), at: 0)
        }
    }

    private func applyCarDetectionProgress(_ progress: CarDetectionProgress) {
        guard let activeUploadSessionID, pipelineSteps[activeUploadSessionID]?.isEmpty == false else { return }
        pipelineSteps[activeUploadSessionID]?[0].subProgress = progress.fraction
        pipelineSteps[activeUploadSessionID]?[0].detail = "\(progress.framesDone)/\(progress.framesTotal) frame"
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

    /// `~/Library/Application Support/JalanKita Mac/synced-sessions/` — where
    /// `SyncedSessionIngestor` copies each synced session's clip files to.
    /// Exposed (not private) so `SessionVideoAssetBuilder` can look those
    /// same clips back up for Tinjauan Parkir's video player, without
    /// duplicating this path as a second magic string.
    static func syncedSessionsDir() -> URL {
        appSupportDir().appendingPathComponent("synced-sessions", isDirectory: true)
    }

    /// `~/Library/Application Support/JalanKita Mac/manual-uploads/<sessionID>/`
    /// — durable home for a manually-uploaded video, mirroring
    /// `syncedSessionsDir()`'s reasoning for synced clips.
    static func manualUploadsDir(sessionID: String) -> URL {
        appSupportDir()
            .appendingPathComponent("manual-uploads", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    private static func copyToManualUploadsDir(sourceURL: URL, sessionID: String) -> URL? {
        let dir = manualUploadsDir(sessionID: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = dir.appendingPathComponent("video").appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// `CKRecordZone.ID` isn't `Codable` — persisted as its two constituent
    /// strings instead.
    private struct PersistedZone: Codable {
        let zoneName: String
        let ownerName: String
    }

    private static var surveyorZonesFileURL: URL {
        appSupportDir().appendingPathComponent("surveyor_zones.json")
    }

    private static func loadSurveyorZones() -> [String: CKRecordZone.ID] {
        guard let data = try? Data(contentsOf: surveyorZonesFileURL),
              let persisted = try? JSONDecoder().decode([String: PersistedZone].self, from: data)
        else { return [:] }
        return persisted.mapValues { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName) }
    }

    private static func saveSurveyorZones(_ zones: [String: CKRecordZone.ID]) {
        let persisted = zones.mapValues { PersistedZone(zoneName: $0.zoneName, ownerName: $0.ownerName) }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: surveyorZonesFileURL, options: .atomic)
    }

    private static var sessionsFileURL: URL { appSupportDir().appendingPathComponent("sessions.json") }

    private static func loadSessions() -> [Session]? {
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return nil }
        return sessions
    }

    private static func saveSessions(_ sessions: [Session]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: sessionsFileURL, options: .atomic)
    }

    private static var parkingAnalysesFileURL: URL { appSupportDir().appendingPathComponent("parking_analyses.json") }

    private static func loadParkingAnalyses() -> [Session.ID: [ParkingAnalysis]] {
        guard let data = try? Data(contentsOf: parkingAnalysesFileURL),
              let analyses = try? JSONDecoder().decode([Session.ID: [ParkingAnalysis]].self, from: data)
        else { return [:] }
        return analyses
    }

    private static func saveParkingAnalyses(_ analyses: [Session.ID: [ParkingAnalysis]]) {
        guard let data = try? JSONEncoder().encode(analyses) else { return }
        try? data.write(to: parkingAnalysesFileURL, options: .atomic)
    }

    private static var manualUploadsPushedFileURL: URL { appSupportDir().appendingPathComponent("manual_uploads_pushed.json") }

    private static func loadManualUploadsPushed() -> Set<Session.ID> {
        guard let data = try? Data(contentsOf: manualUploadsPushedFileURL),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return ids
    }

    private static func saveManualUploadsPushed(_ ids: Set<Session.ID>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: manualUploadsPushedFileURL, options: .atomic)
    }

    private static var pipelineStepsFileURL: URL { appSupportDir().appendingPathComponent("pipeline_steps.json") }

    private static func loadPipelineSteps() -> [Session.ID: [PipelineStep]] {
        guard let data = try? Data(contentsOf: pipelineStepsFileURL),
              let steps = try? JSONDecoder().decode([Session.ID: [PipelineStep]].self, from: data)
        else { return [:] }
        return steps
    }

    private static func savePipelineSteps(_ steps: [Session.ID: [PipelineStep]]) {
        guard let data = try? JSONEncoder().encode(steps) else { return }
        try? data.write(to: pipelineStepsFileURL, options: .atomic)
    }

    private static var logLinesFileURL: URL { appSupportDir().appendingPathComponent("log_lines.json") }

    private static func loadLogLines() -> [Session.ID: [LogLine]] {
        guard let data = try? Data(contentsOf: logLinesFileURL),
              let lines = try? JSONDecoder().decode([Session.ID: [LogLine]].self, from: data)
        else { return [:] }
        return lines
    }

    private static func saveLogLines(_ lines: [Session.ID: [LogLine]]) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: logLinesFileURL, options: .atomic)
    }

    /// The parking-disturbance pipeline's own stages (`src/disturbance.py`
    /// `analyze()`) — real pipeline metadata describing what the worker
    /// actually does, not sample/placeholder content; moved out of
    /// `SampleData.swift` since it's accurate for every photo, not just a
    /// mock one. `.waiting` at rest; `applyProgress` drives state/detail
    /// live from the worker's stderr events during `uploadImage(url:)`.
    private static let photoPipelineSteps: [PipelineStep] = [
        PipelineStep(id: 1, title: "Segmentasi semantik jalan", state: .waiting,
                     detail: "menunggu",
                     stats: "Mask2Former (jalan terlihat) + OFRSNet (patch jalan amodal)"),
        PipelineStep(id: 2, title: "Deteksi instans kendaraan", state: .waiting,
                     detail: "menunggu",
                     stats: "model instans kendaraan, dengan fallback komponen-terhubung (blob) untuk dukungan yang tak terdeteksi"),
        PipelineStep(id: 3, title: "Estimasi bidang tanah & tinggi kamera", state: .waiting,
                     detail: "menunggu",
                     stats: "RANSAC pada depth monokuler · skala metrik otomatis dari tinggi atap kendaraan terdeteksi"),
        PipelineStep(id: 4, title: "Rasterisasi BEV & atribusi", state: .waiting,
                     detail: "menunggu",
                     stats: "proyeksi top-down · jejak kontak-tanah tiap kendaraan · atribusi area jalan tersembunyi per kendaraan"),
    ]

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
        guard let activeUploadSessionID else { return }
        if let log = update.logLine {
            logLines[activeUploadSessionID, default: []].insert(log, at: 0)
        }
        if let stepID = update.stepID, let state = update.stepState,
           let index = pipelineSteps[activeUploadSessionID]?.firstIndex(where: { $0.id == stepID }) {
            pipelineSteps[activeUploadSessionID]?[index].state = state
            pipelineSteps[activeUploadSessionID]?[index].detail = state == .done ? "selesai" : "berjalan"
            if state == .active, index > 0 {
                pipelineSteps[activeUploadSessionID]?[index - 1].state = .done
            }
        }
        updateQueueProgress()
    }

    private func updateQueueProgress() {
        guard let activeUploadSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeUploadSessionID }),
              case .segmenting = sessions[index].status,
              let steps = pipelineSteps[activeUploadSessionID]
        else { return }
        let doneCount = steps.filter { $0.state == .done }.count
        let progress = steps.isEmpty ? 0 : Double(doneCount) / Double(steps.count)
        sessions[index].status = .segmenting(progress: progress)
    }

    private func updateSessionStatus(_ sessionID: String, _ status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].status = status
    }

    private static func probeDurationSeconds(url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        return duration.seconds
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
