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

    /// The file's own recording timestamp (QuickTime `com.apple.quicktime.creationdate`
    /// / `mvhd`), read via AVFoundation rather than `RoadDamage/video_frames.py`'s raw
    /// atom parser — this needs to run from Swift, at upload time, before anything else
    /// touches the file.
    ///
    /// ⚠️ That timing matters and is the whole reason this exists as a separate read
    /// instead of just trusting `RoadDamageVideoManifest.createdUtc` (stage 3's own read
    /// of the same atom): **`rotateVideo` below destroys this timestamp**. Confirmed by
    /// export/re-read — `AVAssetExportSession` with `.passthrough` does not carry the
    /// source's creation date forward; the output's `mvhd` gets stamped with the moment
    /// of export instead. A user who rotates a tilted upload before "Proses sekarang"
    /// (the button exists in Sesi Masuk's preview specifically for this) silently loses
    /// the one value `FindingsMapView`'s manual-upload GPS join depends on if that join
    /// reads the atom AFTER rotation. Reading it here, at upload — before any rotation
    /// can happen — and having `AppModel` cache the result is what keeps the join correct
    /// through a rotate. It cannot help a file that was ALREADY re-exported by something
    /// outside this app before it ever reached "Video + GPS (demo)…": that timestamp is
    /// gone before this function ever sees the file, and no read here or anywhere else
    /// recovers it.
    static func creationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.value) as? Date
    }

    enum RotationError: LocalizedError {
        case noVideo
        case noVideoTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "Video sumber untuk sesi ini tidak ditemukan."
            case .noVideoTrack: "Berkas ini tidak berisi trek video."
            case .exportFailed(let reason): "Gagal memutar orientasi video: \(reason)"
            }
        }
    }

    /// Rotates the session's source video file in place, losslessly —
    /// combines `degrees` with the track's existing `preferredTransform` and
    /// remuxes with the `.passthrough` preset (metadata only, no pixel
    /// re-encode), so this stays fast regardless of file size and never
    /// touches picture quality. Every downstream reader of this file — the
    /// Python pipelines' own orientation handling, this same preview,
    /// "Simpan video…" — sees the corrected orientation with no separate
    /// plumbing, because there's only ever the one file on disk.
    static func rotateVideo(for session: Session, clockwiseDegrees degrees: Double) async throws {
        guard let sourceURL = clipURLs(for: session).first else { throw RotationError.noVideo }
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RotationError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let existingTransform = try await videoTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RotationError.exportFailed("tidak bisa membuat trek video") }
        try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        let rotation = CGAffineTransform(rotationAngle: degrees * .pi / 180)
        compVideoTrack.preferredTransform = existingTransform.concatenating(rotation)

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RotationError.exportFailed("tidak bisa membuat sesi ekspor")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try await exportSession.export(to: tempURL, as: .mov)
        } catch {
            throw RotationError.exportFailed(error.localizedDescription)
        }

        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: tempURL)
    }
}
