//
//  RecordingSessionStore.swift
//  JalanKita iOS
//
//  Local-only persistence: a plain JSON index under Application Support,
//  not SwiftData/Core Data. Session counts per surveyor are small, and
//  CloudKit becomes the durable store once sync exists (see the phase
//  plan) — a local database would just be a second source of truth to
//  keep in sync with nothing yet.
//
//  Directory layout per session: `<AppSupport>/Sessions/<sessionID>/`
//  holding `clip_0.mov`, `clip_1.mov`, ... and `gps.csv`.
//

import Foundation
import JalanKitaKit

@MainActor
final class RecordingSessionStore {
    private let fm = FileManager.default

    private var appSupportDir: URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JalanKita iOS", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Exposed so the sync-related stores (`SessionSyncStateStore`,
    /// `CloudKitSyncEngine`'s state file) live alongside `sessions_index.json`
    /// under the same Application Support directory.
    var appSupportDirectory: URL { appSupportDir }

    private var sessionsDir: URL {
        let url = appSupportDir.appendingPathComponent("Sessions", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var indexURL: URL { appSupportDir.appendingPathComponent("sessions_index.json") }
    private var calibrationURL: URL { appSupportDir.appendingPathComponent("calibration.json") }

    /// Creates and returns `<AppSupport>/Sessions/<sessionID>/`.
    func newSessionDirectory(sessionID: String) -> URL {
        let dir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func gpsCSVURL(for sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("gps.csv")
    }

    private func gpsSummaryURL(for sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("gps_summary.json")
    }

    /// Looks up an existing clip file by session + index, for the sync
    /// engine to attach as a CKAsset — nil if that clip doesn't exist
    /// (e.g. index out of range, or the file hasn't finished writing).
    func clipFileURL(sessionID: String, clipIndex: Int) -> URL? {
        let url = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("clip_\(clipIndex).mov")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func gpsCSVFileURL(sessionID: String) -> URL? {
        let url = sessionsDir.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent("gps.csv")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Computed once when a recording finishes (see `ActiveRecordingView`)
    /// and read back by the sync engine whenever it needs to build a
    /// `GPSTrack` CKRecord — cheaper than re-parsing the full CSV (which
    /// can be ~10k rows for a multi-hour session) on every sync attempt.
    func saveGPSSummary(_ summary: SyncedGPSTrack, sessionID: String) {
        let dir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: gpsSummaryURL(for: dir), options: .atomic)
    }

    func loadGPSSummary(sessionID: String) -> SyncedGPSTrack? {
        let dir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        guard let data = try? Data(contentsOf: gpsSummaryURL(for: dir)) else { return nil }
        return try? JSONDecoder().decode(SyncedGPSTrack.self, from: data)
    }

    func loadIndex() -> [Session] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    func saveIndex(_ sessions: [Session]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func appendToIndex(_ session: Session) {
        var sessions = loadIndex()
        sessions.insert(session, at: 0)
        saveIndex(sessions)
    }

    func removeFromIndex(_ sessionID: String) {
        saveIndex(loadIndex().filter { $0.id != sessionID })
    }

    /// `<AppSupport>/Sessions/<sessionID>/` — for the delete flow to remove
    /// a session's clips + gps.csv in one directory removal.
    func sessionDirectory(sessionID: String) -> URL {
        sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
    }

    func loadCalibration() -> CalibrationProfile? {
        guard let data = try? Data(contentsOf: calibrationURL) else { return nil }
        return try? JSONDecoder().decode(CalibrationProfile.self, from: data)
    }

    func saveCalibration(_ profile: CalibrationProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: calibrationURL, options: .atomic)
    }

    func calibrationFrameURL(filename: String) -> URL {
        appSupportDir.appendingPathComponent(filename)
    }

    /// The current calibration profile's frame image, if it exists locally
    /// — for the sync engine to attach as a CKAsset.
    func calibrationFrameFileURL() -> URL? {
        guard let profile = loadCalibration(), !profile.frameFilename.isEmpty else { return nil }
        let url = calibrationFrameURL(filename: profile.frameFilename)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Remaining free space on the device, for the storage-remaining readout.
    func availableStorageBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
