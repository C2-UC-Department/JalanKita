//
//  AppModel.swift
//  JalanKita iOS
//
//  Single source of truth for the recording app — NOT shared with the
//  Mac's AppModel. The two apps have very different shapes: the Mac is a
//  desk console orchestrating Process()-based ML workers; this is a
//  recording+GPS-logging app with no inference of its own. Both consume
//  the same JalanKitaKit model/design-system types so the vocabulary
//  (Session, Severity, SessionStatus, ...) stays identical.
//

import AVFoundation
import Foundation
import Observation
import JalanKitaKit

@MainActor
@Observable
final class AppModel {
    var hasCompletedOnboarding: Bool
    var surveyorName: String
    var calibration: CalibrationProfile?
    var localSessions: [Session] = []

    let store: RecordingSessionStore
    let syncStates: SessionSyncStateStore
    let syncEngine: CloudKitSyncEngine
    let parkingResultStore: ParkingResultStore

    private enum DefaultsKey {
        static let onboarded = "hasCompletedOnboarding"
        static let surveyorName = "surveyorName"
    }

    init() {
        let defaults = UserDefaults.standard
        hasCompletedOnboarding = defaults.bool(forKey: DefaultsKey.onboarded)
        let surveyorName = defaults.string(forKey: DefaultsKey.surveyorName) ?? ""
        self.surveyorName = surveyorName
        calibration = nil
        localSessions = []

        let store = RecordingSessionStore()
        self.store = store
        localSessions = store.loadIndex()
        calibration = store.loadCalibration()

        let syncStates = SessionSyncStateStore(appSupportDir: store.appSupportDirectory)
        self.syncStates = syncStates
        parkingResultStore = ParkingResultStore(appSupportDir: store.appSupportDirectory)
        // `surveyorName` doubles as a placeholder surveyor identifier until
        // there's real account/login infrastructure — Session.surveyor.id
        // already uses the same value (see ActiveRecordingView).
        self.syncEngine = CloudKitSyncEngine(
            surveyorID: surveyorName.isEmpty ? "unknown" : surveyorName,
            appSupportDir: store.appSupportDirectory,
            syncStates: syncStates
        )
        syncStates.ensureTracked(sessionIDs: localSessions.map(\.id))
        syncEngine.dataSource = self

        // The pending-upload queue lives in memory only (see
        // CloudKitSyncEngine's doc-comment) — re-derive it from
        // SessionSyncStateStore on launch so a session that finished
        // recording but never fully synced (app killed mid-upload, or
        // network was down) resumes instead of being silently dropped.
        for session in localSessions
        where !syncStates.isFullyUploaded(sessionID: session.id, clipCount: session.clipCount) {
            syncEngine.enqueueFullSessionUpload(session)
        }
        if calibration != nil {
            syncEngine.enqueueCalibrationUpload()
        }
    }

    func setSurveyorName(_ name: String) {
        surveyorName = name
        UserDefaults.standard.set(name, forKey: DefaultsKey.surveyorName)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboarded)
    }

    func saveCalibration(_ profile: CalibrationProfile) {
        calibration = profile
        store.saveCalibration(profile)
        syncEngine.enqueueCalibrationUpload()
    }

    func recordingFinished(_ session: Session, gpsSummary: SyncedGPSTrack) {
        localSessions.insert(session, at: 0)
        store.appendToIndex(session)
        store.saveGPSSummary(gpsSummary, sessionID: session.id)
        syncStates.ensureTracked(sessionIDs: [session.id])
        syncEngine.enqueueFullSessionUpload(session)
        // Enqueuing only stages the record locally — it does NOT send
        // anything by itself. The scenePhase-based foreground trigger in
        // HomeDashboardView doesn't fire here either (dismissing a
        // fullScreenCover isn't a scenePhase change), so without this, a
        // finished recording would sit unsent until the user manually
        // tapped "Sinkronkan" or backgrounded/re-foregrounded the app.
        Task { await syncEngine.syncNow() }
    }

    /// Fallback for footage that didn't come from this app's own recorder —
    /// existing dashcam/handheld video with no GPS track of its own. Reuses
    /// `recordingFinished`'s exact upload path (a real Session + an empty
    /// GPS track, same field shapes the sync engine already expects) rather
    /// than a separate code path, so this exercises the identical pipeline
    /// a real recording does.
    func importVideo(from sourceURL: URL) async throws {
        let sessionID = UUID().uuidString
        let directory = store.newSessionDirectory(sessionID: sessionID)
        let destinationURL = directory.appendingPathComponent("clip_0.mov")

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let durationSeconds = (try? await AVURLAsset(url: destinationURL).load(.duration).seconds) ?? 0
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int) ?? 0

        // Header-only, no rows — this video wasn't recorded with the app,
        // so there's no real geotagged track. Still needs to exist so the
        // sync engine's "gpsTrackUploaded" bookkeeping completes normally,
        // same as a real recording's gps.csv.
        FileManager.default.createFile(atPath: store.gpsCSVURL(for: directory).path, contents: Data("time,lat,lon\n".utf8))

        let session = Session(
            id: sessionID,
            roadName: sourceURL.deletingPathExtension().lastPathComponent,
            date: Date().formatted(date: .abbreviated, time: .shortened),
            surveyor: Surveyor(id: surveyorName, name: surveyorName),
            clipCount: 1,
            duration: Self.formattedDuration(durationSeconds),
            distanceKm: 0,
            gpsAccuracyM: nil,
            gpsHz: nil,
            gpsGapNote: "Tidak ada data GPS — video diimpor",
            sizeGB: Double(sizeBytes ?? 0) / 1_000_000_000,
            status: .readyToProcess,
            recordedDate: Date(),
            durationSeconds: durationSeconds
        )
        let gpsSummary = SyncedGPSTrack(sessionID: sessionID, pointCount: 0, minLatitude: 0, minLongitude: 0, maxLatitude: 0, maxLongitude: 0)
        recordingFinished(session, gpsSummary: gpsSummary)
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) j \(m) m" : "\(m) m"
    }

    /// Manual/foreground sync trigger — no push infrastructure in this
    /// phase, so this is the only way changes actually move.
    func syncNow() async {
        await syncEngine.syncNow()
    }

    func parkingResults(sessionID: String) -> [DownloadedParkingResult] {
        parkingResultStore.results(sessionID: sessionID)
    }
}

extension AppModel: CloudKitSyncDataSource {
    var calibrationProfile: CalibrationProfile? { calibration }

    func session(withID id: String) -> Session? {
        localSessions.first { $0.id == id }
    }

    func clipFileURL(sessionID: String, clipIndex: Int) -> URL? {
        store.clipFileURL(sessionID: sessionID, clipIndex: clipIndex)
    }

    func gpsCSVFileURL(sessionID: String) -> URL? {
        store.gpsCSVFileURL(sessionID: sessionID)
    }

    func gpsSummary(sessionID: String) -> SyncedGPSTrack? {
        store.loadGPSSummary(sessionID: sessionID)
    }

    func calibrationFrameFileURL() -> URL? {
        store.calibrationFrameFileURL()
    }

    /// A Session record came back from CloudKit. Usually this is the Mac
    /// updating fields it owns (status, segmentCount) on a session this
    /// device itself recorded — merge those in without clobbering the
    /// iOS-owned fields. But it can also be a session that originated
    /// elsewhere in this zone entirely (e.g. the Mac operator manually
    /// uploaded a video with no GPS and pushed it here for testing) — in
    /// that case there's nothing local to merge into, so it's inserted as
    /// new instead of silently dropped.
    func applyIncomingSession(_ incoming: Session) {
        if let index = localSessions.firstIndex(where: { $0.id == incoming.id }) {
            localSessions[index].status = incoming.status
            localSessions[index].segmentCount = incoming.segmentCount
        } else {
            localSessions.insert(incoming, at: 0)
            syncStates.ensureTracked(sessionIDs: [incoming.id])
            syncStates.markSynced(incoming.id)
        }
        store.saveIndex(localSessions)
    }

    func applyIncomingParkingResult(_ result: DownloadedParkingResult) {
        parkingResultStore.upsert(result)
    }
}
