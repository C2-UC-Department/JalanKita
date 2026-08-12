//
//  SessionVideoAssetBuilder.swift
//  JalanKita Mac
//
//  Locates a session's original video file(s) and builds one playable
//  `AVAsset` for Tinjauan Parkir's video player: a plain `AVURLAsset` for a
//  single clip, or an `AVMutableComposition` stitching multiple clips into
//  one continuous timeline for a multi-clip synced session. The stitching
//  order/durations deliberately mirror `AppModel.runSyncedSessionAnalysis`'s
//  own `clipOffsets` computation, so a marker's `sessionRelativeSeconds`
//  lines up with the composition's own timeline.
//

import AVFoundation
import JalanKitaKit

enum SessionVideoAssetBuilder {
    /// Ordered clip file URLs for a session, filtered to what actually
    /// exists on disk — defensive against an older session predating this
    /// feature, or files removed outside the app.
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
        let urls = clipURLs(for: session)
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return AVURLAsset(url: urls[0]) }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        var cursor = CMTime.zero
        var insertedAny = false
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration)
            else { continue }
            do {
                try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: cursor)
                cursor = CMTimeAdd(cursor, duration)
                insertedAny = true
            } catch {
                continue
            }
        }
        // A composition with no successfully-inserted track segments is
        // zero-duration and unplayable — AVKit's `VideoPlayer` handling
        // that is untested territory, safer to report "no video" (the
        // existing empty state) than hand it a broken asset.
        return insertedAny ? composition : nil
    }
}
