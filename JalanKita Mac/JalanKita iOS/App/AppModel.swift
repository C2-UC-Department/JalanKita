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

    /// Manual/foreground sync trigger — no push infrastructure in this
    /// phase, so this is the only way changes actually move.
    func syncNow() async {
        await syncEngine.syncNow()
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

    /// A Session record came back from CloudKit with Mac-owned fields
    /// (status, segmentCount) changed — merge them into local state without
    /// clobbering the iOS-owned fields this device is authoritative for.
    func applyIncomingSession(_ incoming: Session) {
        guard let index = localSessions.firstIndex(where: { $0.id == incoming.id }) else { return }
        localSessions[index].status = incoming.status
        localSessions[index].segmentCount = incoming.segmentCount
        store.saveIndex(localSessions)
    }
}
