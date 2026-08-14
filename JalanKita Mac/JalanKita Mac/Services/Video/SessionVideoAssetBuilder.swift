//
//  SessionVideoAssetBuilder.swift
//  JalanKita Mac
//
//  Locates a session's original video file and builds a playable
//  `AVAsset` for Tinjauan Parkir's video player. Every session — synced
//  from an iPhone or manually uploaded — is exactly one continuous file
//  (no pause/resume on the recording side, see `CaptureSessionController`),
//  so this is always a plain `AVURLAsset`, never a multi-clip composition.
//

import AVFoundation
import JalanKitaKit

enum SessionVideoAssetBuilder {
    /// Ordered clip file URLs for a session, filtered to what actually
    /// exists on disk — defensive against an older session predating this
    /// feature, or files removed outside the app. In practice always
    /// zero-or-one elements; `session.clipCount` is retained for an old
    /// synced session that predates the removal of multi-clip recording.
    static func clipURLs(for session: Session) -> [URL] {
        let fm = FileManager.default
        if session.recordedDate != nil {
            // A real iPhone recording, synced via CloudKit — clips already
            // live at SyncedSessionIngestor's stable path.
            let dir = AppModel.syncedSessionsDir().appendingPathComponent(session.id, isDirectory: true)
            return (0..<session.clipCount)
                .map { dir.appendingPathComponent("clip_\($0).mov") }
                .filter { fm.fileExists(atPath: $0.path) }
        } else {
            // A manual upload (uploadImage/uploadVideo) — single durable
            // copy, extension preserved from the original file so
            // AVFoundation's own content-type detection stays accurate.
            let dir = AppModel.manualUploadsDir(sessionID: session.id)
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return contents.filter { $0.deletingPathExtension().lastPathComponent == "video" }
        }
    }

    static func buildPlayableAsset(for session: Session) async -> AVAsset? {
        guard let url = clipURLs(for: session).first else { return nil }
        return AVURLAsset(url: url)
    }
}
