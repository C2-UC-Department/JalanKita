//
//  SyncedSessionIngestor.swift
//  JalanKita Mac
//
//  Session/Clip/GPSTrack records for one session arrive from CloudKit as
//  separate, independently-ordered fetch events — this buffers them per
//  session ID until all of it is present (the Session record itself, plus
//  every clip up to `clipCount`, plus the GPS track), then copies the
//  downloaded assets to a stable local directory and hands off to
//  `AppModel.ingestSyncedSession`.
//
//  Copying is mandatory, not defensive: a fetched CKAsset's `fileURL`
//  points at CloudKit's own temporary copy, which isn't guaranteed to
//  outlive the CKRecord that referenced it.
//

import CloudKit
import Foundation
import JalanKitaKit

@MainActor
final class SyncedSessionIngestor: CloudKitIngestDelegate {
    private struct Buffer {
        var session: Session?
        var zoneID: CKRecordZone.ID?
        var clipLocalURLs: [Int: URL] = [:]
        var gpsLocalURL: URL?
    }

    private var buffers: [String: Buffer] = [:]
    private let workDir: URL
    weak var appModel: AppModel?

    init(workDir: URL) {
        self.workDir = workDir
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    func didFetchSession(_ session: Session, zoneID: CKRecordZone.ID) {
        var buffer = buffers[session.id] ?? Buffer()
        buffer.session = session
        buffer.zoneID = zoneID
        buffers[session.id] = buffer
        checkComplete(session.id)
    }

    func didFetchClip(sessionID: String, clipIndex: Int, localFileURL: URL) {
        guard let stableURL = copyAsset(from: localFileURL, to: sessionDirectory(sessionID).appendingPathComponent("clip_\(clipIndex).mov")) else { return }
        var buffer = buffers[sessionID] ?? Buffer()
        buffer.clipLocalURLs[clipIndex] = stableURL
        buffers[sessionID] = buffer
        checkComplete(sessionID)
    }

    func didFetchGPSTrack(sessionID: String, localFileURL: URL) {
        guard let stableURL = copyAsset(from: localFileURL, to: sessionDirectory(sessionID).appendingPathComponent("gps.csv")) else { return }
        var buffer = buffers[sessionID] ?? Buffer()
        buffer.gpsLocalURL = stableURL
        buffers[sessionID] = buffer
        checkComplete(sessionID)
    }

    func didFetchCalibration(_ profile: CalibrationProfile, localFrameURL: URL?) {
        // Displaying synced calibration profiles is a Phase 3 dashboard
        // concern — not consumed by the pipeline yet (see CalibrationProfile's
        // own doc-comment: the pixel-to-metres math isn't wired in anywhere).
    }

    private func sessionDirectory(_ sessionID: String) -> URL {
        let dir = workDir.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func copyAsset(from sourceURL: URL, to destinationURL: URL) -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        do {
            try fm.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    private func checkComplete(_ sessionID: String) {
        guard let buffer = buffers[sessionID],
              let session = buffer.session,
              let zoneID = buffer.zoneID,
              buffer.gpsLocalURL != nil,
              session.clipCount > 0
        else { return }
        let orderedClipURLs = (0..<session.clipCount).compactMap { buffer.clipLocalURLs[$0] }
        guard orderedClipURLs.count == session.clipCount else { return }

        buffers.removeValue(forKey: sessionID)
        appModel?.ingestSyncedSession(session, clipURLs: orderedClipURLs, zoneID: zoneID)
    }
}
