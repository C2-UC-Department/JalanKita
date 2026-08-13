//
//  SessionSyncStateStore.swift
//  JalanKita iOS
//
//  Per-session CloudKit upload bookkeeping (not-synced / uploading / synced
//  / failed, which clip indices have already become Clip records). Kept
//  separate from the shared JalanKitaKit `Session` model, and from
//  RecordingSessionStore — the Mac has no use for "which clips has this
//  iPhone uploaded," and CloudKit sync bookkeeping is a distinct, actively
//  growing concern from recording-data persistence.
//
//  Also the real migration path for sessions recorded during Phase 1
//  testing, before sync existed: any session missing from this map
//  defaults to `.notSynced` on load (see AppModel's reconciliation).
//

import Foundation
import Observation

enum SessionSyncStatus: String, Codable {
    case notSynced, uploading, synced, failed
}

struct SessionSyncState: Codable {
    var status: SessionSyncStatus
    var uploadedClipIndices: Set<Int>
    var gpsTrackUploaded: Bool
    var lastError: String?

    static let initial = SessionSyncState(status: .notSynced, uploadedClipIndices: [], gpsTrackUploaded: false, lastError: nil)
}

/// `@Observable` so a sync-status badge in the UI (SessionRowView) updates
/// live as `markUploading`/`markSynced`/etc. run during an in-flight sync,
/// not just on the next full view rebuild.
@MainActor
@Observable
final class SessionSyncStateStore {
    private let fileURL: URL
    private(set) var states: [String: SessionSyncState] = [:]

    init(appSupportDir: URL) {
        fileURL = appSupportDir.appendingPathComponent("sync_state.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        states = (try? JSONDecoder().decode([String: SessionSyncState].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func state(for sessionID: String) -> SessionSyncState {
        states[sessionID] ?? .initial
    }

    /// Registers any session IDs this store hasn't seen before as
    /// `.notSynced` — the Phase-1-session migration path.
    func ensureTracked(sessionIDs: [String]) {
        var changed = false
        for id in sessionIDs where states[id] == nil {
            states[id] = .initial
            changed = true
        }
        if changed { save() }
    }

    func markUploading(_ sessionID: String) {
        var s = state(for: sessionID)
        guard s.status != .uploading else { return }
        s.status = .uploading
        states[sessionID] = s
        save()
    }

    func markClipUploaded(_ sessionID: String, clipIndex: Int) {
        var s = state(for: sessionID)
        s.uploadedClipIndices.insert(clipIndex)
        states[sessionID] = s
        save()
    }

    func markGPSTrackUploaded(_ sessionID: String) {
        var s = state(for: sessionID)
        s.gpsTrackUploaded = true
        states[sessionID] = s
        save()
    }

    func markSynced(_ sessionID: String) {
        var s = state(for: sessionID)
        s.status = .synced
        s.lastError = nil
        states[sessionID] = s
        save()
    }

    func markFailed(_ sessionID: String, error: String) {
        var s = state(for: sessionID)
        s.status = .failed
        s.lastError = error
        states[sessionID] = s
        save()
    }

    /// True once every clip and the GPS track for a session have been
    /// acknowledged saved by CloudKit.
    func isFullyUploaded(sessionID: String, clipCount: Int) -> Bool {
        let s = state(for: sessionID)
        return s.uploadedClipIndices.count >= clipCount && s.gpsTrackUploaded
    }

    func remove(_ sessionID: String) {
        guard states.removeValue(forKey: sessionID) != nil else { return }
        save()
    }
}
