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

    /// Remaining free space on the device, for the storage-remaining readout.
    func availableStorageBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
