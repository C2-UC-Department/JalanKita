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
//  (parkingAnalyses).
//
//  A session lives in exactly one screen at a time, decided by its `status`:
//  Sesi masuk holds everything not yet finished (including `.failed` /
//  `.degraded`, which still need the operator to act), Antrean holds what is
//  actively running (`status.isQueued`), and Laporan holds `.done`. That is
//  why none of the three screens filter on anything but status — there is no
//  second source of truth for "where does this session belong."
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

    /// Real road-damage findings, keyed by session id — stage 3's output, one
    /// element per sampled frame that the detector answered for.
    ///
    /// A separate dictionary from `parkingAnalyses` rather than a field on it,
    /// because the two stages are genuinely independent: they sample different
    /// frames (v13's per-car stills vs a fixed-interval walk of the whole clip),
    /// either can be empty while the other is full, and a clip with no parked cars
    /// still has a road surface worth scoring. They meet only on the timeline, via
    /// `sessionRelativeSeconds`.
    ///
    /// Persisted alongside `parkingAnalyses`, for the same reason: a ~6-minute run
    /// that vanishes on relaunch is not a result.
    var roadDamageFrames: [Session.ID: [ReviewFrame]] = AppModel.loadRoadDamageFrames() {
        didSet { Self.saveRoadDamageFrames(roadDamageFrames) }
    }

    /// Seconds between sampled frames for stage 3, as chosen in the review UI.
    ///
    /// Not persisted — it is a per-run choice, not a preference. The default is 5 s
    /// rather than `video_frames.py`'s own 3 s because the cost is measured and
    /// linear: ~2,7 s of CPU per frame against `duration / interval` frames means
    /// 3 s costs 0,9× the clip's duration and 5 s costs 0,54×. See
    /// `RoadDamageService.analyzeVideo`.
    var roadDamageIntervalSeconds: Double = 5.0

    /// Drop frames that are near-identical to one already kept, before they cost an
    /// analysis. Off by default.
    ///
    /// The cheapest real lever on stage 3's cost — a survey vehicle stopped at a
    /// light otherwise pays ~2,7 s of CPU per near-duplicate of the same asphalt —
    /// and strictly better than raising the interval, which drops frames on the
    /// moving stretches too. ⚠️ Off by default because the right dHash threshold
    /// depends on the footage and none has been measured against Surabaya clips;
    /// the log reports how many frames it actually dropped so it can be tuned on
    /// evidence.
    var roadDamageSkipDuplicates: Bool = false

    /// Hamming distance over a 64-bit dHash. 5 is the conventional "visually
    /// identical" point; see `roadDamageSkipDuplicates`.
    private static let duplicateHashThreshold = 5

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

    /// Live timing for the sessions currently running, keyed by session id.
    ///
    /// Deliberately NOT persisted, unlike `pipelineSteps`/`logLines`: a clock
    /// restored from disk after a relaunch would describe a worker process that
    /// no longer exists, and would report a multi-hour "elapsed" for a run that
    /// died with the app. An entry exists only while the session is queued —
    /// `updateSessionStatus` creates it on entry and drops it on exit.
    var processingClocks: [Session.ID: ProcessingClock] = [:]

    /// How long the worker may go silent before Antrean calls it stuck.
    ///
    /// Grounded in the worker's measured behaviour, not picked round: v13 prints
    /// progress only every 50 frames (`pipeline_v13.py`), and at the ~0.78 s per
    /// frame the profiled `--deterministic` CPU path actually runs at, that is a
    /// normal gap of ~39 s between lines. Startup is quieter still — loading
    /// YOLO, the sign detector, YOLOP and MiDaS takes ~80 s during which the
    /// worker says nothing at all. Anything under ~2 minutes would therefore
    /// flag healthy runs; 3 minutes clears both with margin while still
    /// noticing a real hang within one screen-refresh of it mattering.
    static let stallThreshold: TimeInterval = 180

    /// Timing for one in-flight session, assembled from worker progress events.
    struct ProcessingClock: Equatable {
        /// When the operator started it. Includes worker startup, so this is
        /// what "sudah berjalan berapa lama" should show.
        var startedAt: Date

        /// Last time the worker produced *any* output. Stall detection reads
        /// only this — a worker that is loading models is silent but healthy,
        /// which is exactly why the threshold above is measured, not guessed.
        var lastProgressAt: Date

        /// The first frame-level progress event, and the fraction it reported.
        ///
        /// ETA is measured from here rather than from `startedAt` on purpose:
        /// the ~80 s of model loading that precedes the first frame is a fixed
        /// startup cost, not something proportional to the frames that follow.
        /// Averaging it into the rate makes every early estimate wildly
        /// pessimistic — at 10% done it would roughly double the projection.
        var firstFrameAt: Date?
        var firstFraction: Double = 0

        /// Most recent frame-level fraction in 0...1.
        var fraction: Double = 0
    }

    private let inferenceService = InferenceService.shared
    private let carDetectionService = CarDetectionService.shared
    private let roadDamageService = RoadDamageService.shared

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
        // Only the worker's own error/warn events — the frame counters that drive
        // step 3's detail come back through `analyzeVideo`'s closures instead,
        // because those know the total and a stderr line does not.
        roadDamageService.onProgress = { [weak self] line in
            self?.applyRoadDamageStderr(line)
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

    /// What Sesi masuk shows: everything that still needs the operator, which is
    /// every session that isn't `.done`.
    ///
    /// `.failed` and `.degraded` deliberately stay here rather than moving to
    /// Laporan with the finished work. They have been through the pipeline, but
    /// the thing the operator has to do next — start them again — only exists on
    /// this screen, so filing them under "finished" would leave a session with a
    /// pending action in a screen that has no way to act on it.
    var inboxSessions: [Session] {
        sessions.filter { $0.status != .done }
    }

    /// What Laporan shows: finished work only. Ordering is the view's business
    /// (ReportsView sorts by its own `sortOrder`), not fixed here.
    var reportSessions: [Session] {
        sessions.filter { $0.status == .done }
    }

    var batchSelectedCount: Int {
        sessions.filter(\.selectedForBatch).count
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

    /// Reap both warm workers on app quit — called from ContentView's
    /// `willTerminate` hook.
    ///
    /// `InferenceService.shutdown()` had existed since that worker was made warm
    /// but never had a caller. Road damage is warm too now that it is stage 3, so
    /// both are reaped here; a quit mid-run otherwise leaves two Python
    /// interpreters holding their models resident.
    ///
    /// ⚠️ `CarDetectionService` is still not reaped — it has no shutdown API at all
    /// and keeps no reference to its running process, so a ~6-minute v13 run cannot
    /// be cancelled on quit. That gap is unchanged by this work.
    func shutdownServices() async {
        await inferenceService.shutdown()
        await roadDamageService.shutdown()
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
                parkingAnalyses[sessionID] = []
                pipelineSteps[sessionID]?[1].detail = "tidak ada"
                logLines[sessionID, default: []].insert(LogLine(time: Self.logTimeFormatter.string(from: Date()),
                                        message: "Tidak ada mobil PARKED terdeteksi di video ini.",
                                        isWarning: false), at: 0)
                // No parked cars is not a reason to skip the road surface — stage 3
                // shares the clip with v13 and nothing else.
                await runRoadDamageStage(sessionID: sessionID, clipURLs: [videoURL], clipOffsets: [0])
                activeUploadSessionID = nil
                updateSessionStatus(sessionID, .done)
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
            parkingAnalyses[sessionID] = analyses

            let damageFrames = await runRoadDamageStage(
                sessionID: sessionID, clipURLs: [videoURL], clipOffsets: [0])

            activeUploadSessionID = nil
            // Only a total loss fails the session. OFRSNet failing on every car
            // still leaves real road-damage findings worth opening, and vice versa
            // — degrading to the half that worked is the rule everywhere else in
            // this app.
            updateSessionStatus(sessionID, analyses.isEmpty && damageFrames.isEmpty
                                ? .failed(reason: "Semua analisis OFRSNet dan deteksi kerusakan jalan gagal.")
                                : .done)
            if !analyses.isEmpty || !damageFrames.isEmpty {
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
    func deleteSession(_ sessionID: Session.ID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        sessions.removeAll { $0.id == sessionID }
        parkingAnalyses.removeValue(forKey: sessionID)
        roadDamageFrames.removeValue(forKey: sessionID)
        pipelineSteps.removeValue(forKey: sessionID)
        logLines.removeValue(forKey: sessionID)
        manualUploadsPushed.remove(sessionID)

        let fm = FileManager.default
        try? fm.removeItem(at: Self.syncedSessionsDir().appendingPathComponent(sessionID, isDirectory: true))
        try? fm.removeItem(at: Self.manualUploadsDir(sessionID: sessionID))
        try? fm.removeItem(at: Self.carDetectionWorkDir(sessionID: sessionID))
        try? fm.removeItem(at: Self.roadDamageWorkDir(sessionID: sessionID))
        for clipIndex in 0..<session.clipCount {
            try? fm.removeItem(at: Self.carDetectionWorkDir(sessionID: "\(sessionID)-clip\(clipIndex)"))
            try? fm.removeItem(at: Self.roadDamageWorkDir(sessionID: "\(sessionID)-clip\(clipIndex)"))
        }
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
            parkingAnalyses[sessionID] = []
            pipelineSteps[sessionID]?[1].detail = "tidak ada"
            // Same reasoning as the manual path: stage 3 does not depend on v13.
            await runRoadDamageStage(sessionID: sessionID, clipURLs: clipURLs, clipOffsets: clipOffsets)
            activeUploadSessionID = nil
            updateSessionStatus(sessionID, .done)
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
        parkingAnalyses[sessionID] = analyses

        let damageFrames = await runRoadDamageStage(
            sessionID: sessionID, clipURLs: clipURLs, clipOffsets: clipOffsets)

        activeUploadSessionID = nil
        updateSessionStatus(sessionID, analyses.isEmpty && damageFrames.isEmpty
                            ? .failed(reason: "Semua analisis OFRSNet dan deteksi kerusakan jalan gagal.")
                            : .done)
        pushSessionStatus(sessionID: sessionID, zoneID: zoneID)
        // pushSessionStatus/pushParkingResult only stage records in
        // CloudKitSyncEngine.outgoingRecords — nothing actually reaches the
        // server until a syncNow() runs, and this Mac otherwise only syncs
        // on launch or when it regains focus. Without this, results sit
        // queued in memory indefinitely whenever the Mac stays frontmost
        // through the whole analysis run (the common case).
        await syncNow()
    }

    /// Stage 3 for both video drivers: sample each clip on a fixed interval and
    /// score every frame for road damage.
    ///
    /// Deliberately takes the clips rather than anything v13 produced — this stage
    /// shares only the footage with stages 1 and 2. It therefore runs even when v13
    /// found no parked cars at all, which is the case that would otherwise return
    /// early and skip it.
    ///
    /// `clipOffsets` must line up index-for-index with `clipURLs`, the same running
    /// total `runSyncedSessionAnalysis` builds for the parking vertical, so both
    /// verticals' timestamps land on one axis. A single-clip manual upload passes
    /// `[0]`.
    ///
    /// Never throws. A clip that fails is logged and skipped; the session's fate is
    /// decided by its callers, which treat "no damage frames" as a success as long
    /// as the parking stage produced something.
    @discardableResult
    private func runRoadDamageStage(sessionID: String,
                                    clipURLs: [URL],
                                    clipOffsets: [Double]) async -> [ReviewFrame] {
        pipelineSteps[sessionID]?[2].state = .active
        logLines[sessionID, default: []].insert(LogLine(
            time: Self.logTimeFormatter.string(from: Date()),
            message: "Memulai deteksi kerusakan jalan (interval \(Self.intervalFormatter.string(from: NSNumber(value: roadDamageIntervalSeconds)) ?? "5") detik)…",
            isWarning: false), at: 0)

        var frames: [ReviewFrame] = []
        for (clipIndex, clipURL) in clipURLs.enumerated() {
            // One work dir per clip, matching how v13's own output is laid out, so a
            // multi-clip session's frames cannot collide on filename.
            let workDir = clipURLs.count > 1
                ? Self.roadDamageWorkDir(sessionID: "\(sessionID)-clip\(clipIndex)")
                : Self.roadDamageWorkDir(sessionID: sessionID)
            do {
                frames += try await roadDamageService.analyzeVideo(
                    videoURL: clipURL,
                    sessionID: clipURLs.count > 1 ? "\(sessionID)#clip\(clipIndex)" : sessionID,
                    intervalSec: roadDamageIntervalSeconds,
                    hashThreshold: roadDamageSkipDuplicates ? Self.duplicateHashThreshold : 0,
                    clipOffset: clipOffsets.indices.contains(clipIndex) ? clipOffsets[clipIndex] : 0,
                    workDir: workDir,
                    onExtract: { [weak self] progress in
                        self?.pipelineSteps[sessionID]?[2].detail =
                            "mengambil frame \(progress.framesDone)/\(progress.framesTotal)"
                    },
                    onManifest: { [weak self] manifest in
                        guard manifest.rejectedDup > 0 || manifest.rejectedBlur > 0 else { return }
                        self?.logLines[sessionID, default: []].insert(LogLine(
                            time: Self.logTimeFormatter.string(from: Date()),
                            message: "Frame dilewati: \(manifest.rejectedDup) nyaris identik, \(manifest.rejectedBlur) terlalu buram — \(manifest.kept) dianalisis.",
                            isWarning: false), at: 0)
                    },
                    onFrame: { [weak self] done, total in
                        self?.pipelineSteps[sessionID]?[2].detail = "\(done)/\(total)"
                        self?.pipelineSteps[sessionID]?[2].subProgress = Double(done) / Double(total)
                    })
            } catch {
                logLines[sessionID, default: []].insert(LogLine(
                    time: Self.logTimeFormatter.string(from: Date()),
                    message: "Deteksi kerusakan jalan gagal\(clipURLs.count > 1 ? " (klip \(clipIndex))" : ""): \(error.localizedDescription)",
                    isWarning: true), at: 0)
            }
        }

        pipelineSteps[sessionID]?[2].state = .done
        pipelineSteps[sessionID]?[2].subProgress = 1.0
        if frames.isEmpty {
            pipelineSteps[sessionID]?[2].detail = "tidak ada"
        } else {
            pipelineSteps[sessionID]?[2].detail = "selesai"
            let damaged = frames.filter { !$0.findings.isEmpty }.count
            logLines[sessionID, default: []].insert(LogLine(
                time: Self.logTimeFormatter.string(from: Date()),
                message: "Deteksi kerusakan jalan selesai — \(frames.count) frame, \(damaged) berisi temuan.",
                isWarning: false), at: 0)
        }
        roadDamageFrames[sessionID] = frames
        return frames
    }

    /// The worker's own stderr. Only the failure events reach the log — the frame
    /// counters that matter come back through `analyzeVideo`'s closures, which know
    /// the denominator.
    private func applyRoadDamageStderr(_ line: RoadDamageStderrLine) {
        guard case .event(let event) = line,
              event.type == "error" || event.type == "warn",
              let message = event.error,
              let sessionID = activeUploadSessionID else { return }
        logLines[sessionID, default: []].insert(LogLine(
            time: Self.logTimeFormatter.string(from: Date()),
            message: "Kerusakan jalan: \(message)", isWarning: true), at: 0)
    }

    /// `id_ID` throughout, so a 2,5 s interval reads with a comma like every other
    /// number in this app.
    private static let intervalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

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

        // Frame-level progress is the only signal fine-grained enough to project
        // an ETA from; the step-count progress `updateQueueProgress` computes
        // moves a handful of times per run. The first such event also marks the
        // end of model loading, which is where ETA measurement starts.
        if var clock = processingClocks[activeUploadSessionID] {
            if clock.firstFrameAt == nil {
                clock.firstFrameAt = Date()
                clock.firstFraction = progress.fraction
            }
            clock.fraction = progress.fraction
            processingClocks[activeUploadSessionID] = clock
        }

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

    /// `~/Library/Application Support/JalanKita Mac/road-damage/<sessionID>/` —
    /// where `video_frames.py` writes its sampled JPEGs and `frames_provenance.csv`.
    ///
    /// ⚠️ These accumulate and nothing prunes them beyond `deleteSession`. A sampled
    /// frame is a full-resolution JPEG at quality 95, so an hour of footage at the
    /// 5 s default is ~720 of them.
    private static func roadDamageWorkDir(sessionID: String) -> URL {
        Self.appSupportDir()
            .appendingPathComponent("road-damage", isDirectory: true)
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

    private static var roadDamageFramesFileURL: URL { appSupportDir().appendingPathComponent("road_damage_frames.json") }

    private static func loadRoadDamageFrames() -> [Session.ID: [ReviewFrame]] {
        guard let data = try? Data(contentsOf: roadDamageFramesFileURL),
              let frames = try? JSONDecoder().decode([Session.ID: [ReviewFrame]].self, from: data)
        else { return [:] }
        return frames
    }

    private static func saveRoadDamageFrames(_ frames: [Session.ID: [ReviewFrame]]) {
        guard let data = try? JSONEncoder().encode(frames) else { return }
        try? data.write(to: roadDamageFramesFileURL, options: .atomic)
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
    /// tracks "N of M candidates scored", not model-internal stages) — plus
    /// road damage, which shares the clip but nothing else.
    ///
    /// ⚠️ Both video drivers index this array **positionally** (`?[0]`, `?[1]`,
    /// `?[2]`), not by `id`, at roughly a dozen sites. Appending is safe because it
    /// leaves the existing indices alone; inserting or reordering is not, and would
    /// silently drive the wrong row's progress bar.
    private static let videoPipelineSteps: [PipelineStep] = [
        PipelineStep(id: 1, title: "Deteksi & tracking mobil", state: .waiting,
                     detail: "menunggu",
                     stats: "YOLOv8n-seg+ByteTrack+epipolar/FoE+MiDaS depth tiebreak (lambat, akurat)",
                     subProgress: 0),
        PipelineStep(id: 2, title: "Analisis disturbance per mobil (OFRSNet)", state: .waiting,
                     detail: "menunggu",
                     stats: "satu run OFRSNet per mobil PARKED yang terdeteksi",
                     subProgress: 0),
        PipelineStep(id: 3, title: "Deteksi kerusakan jalan", state: .waiting,
                     detail: "menunggu",
                     stats: "sampling frame per interval · YOLO11s + U-Net extent · skor kondisi dari severity.yaml",
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
        guard let activeUploadSessionID else { return }
        // Any worker output at all counts as a heartbeat — both progress paths
        // (`applyProgress` for the disturbance worker, `applyCarDetectionProgress`
        // for v13) funnel through here, so this is the one place stall detection
        // has to be wired into.
        processingClocks[activeUploadSessionID]?.lastProgressAt = Date()

        guard let index = sessions.firstIndex(where: { $0.id == activeUploadSessionID }),
              case .segmenting = sessions[index].status,
              let steps = pipelineSteps[activeUploadSessionID]
        else { return }
        let doneCount = steps.filter { $0.state == .done }.count
        let progress = steps.isEmpty ? 0 : Double(doneCount) / Double(steps.count)
        sessions[index].status = .segmenting(progress: progress)
    }

    /// The single funnel for session status changes — which is why the
    /// processing clock's whole lifecycle hangs off it rather than being
    /// started and stopped by hand at each call site.
    private func updateSessionStatus(_ sessionID: String, _ status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].status = status

        if status.isQueued {
            if processingClocks[sessionID] == nil {
                let now = Date()
                processingClocks[sessionID] = ProcessingClock(startedAt: now, lastProgressAt: now)
            }
        } else {
            processingClocks[sessionID] = nil
        }
    }

    // MARK: - Antrean timing

    /// How long this session has been running, or nil if it isn't.
    func elapsed(for sessionID: Session.ID, now: Date = Date()) -> TimeInterval? {
        guard let clock = processingClocks[sessionID] else { return nil }
        return now.timeIntervalSince(clock.startedAt)
    }

    /// Projected time left, or nil while there isn't yet enough to project from.
    ///
    /// Returns nil rather than a guess in three cases: no clock, no frame-level
    /// progress yet (still loading models), or no measurable forward movement
    /// since the first frame event. A missing ETA reads honestly as "not known
    /// yet"; a fabricated one reads as information.
    func estimatedRemaining(for sessionID: Session.ID, now: Date = Date()) -> TimeInterval? {
        guard let clock = processingClocks[sessionID],
              let firstFrameAt = clock.firstFrameAt else { return nil }
        let progressed = clock.fraction - clock.firstFraction
        let span = now.timeIntervalSince(firstFrameAt)
        guard progressed > 0.001, span > 0 else { return nil }
        let rate = progressed / span
        let remaining = (1 - clock.fraction) / rate
        return remaining.isFinite && remaining >= 0 ? remaining : nil
    }

    /// True when the worker has said nothing for longer than `stallThreshold`.
    func isStalled(_ sessionID: Session.ID, now: Date = Date()) -> Bool {
        guard let clock = processingClocks[sessionID] else { return false }
        return now.timeIntervalSince(clock.lastProgressAt) > Self.stallThreshold
    }

    /// Seconds since the last sign of life — what the stall warning shows.
    func silentFor(_ sessionID: Session.ID, now: Date = Date()) -> TimeInterval? {
        guard let clock = processingClocks[sessionID] else { return nil }
        return now.timeIntervalSince(clock.lastProgressAt)
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
