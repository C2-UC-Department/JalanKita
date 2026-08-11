//
//  CloudKitSyncEngine.swift
//  JalanKita iOS
//
//  Uploads recorded sessions (Session + Clip + GPSTrack records) and the
//  calibration profile to CloudKit, and applies status updates the Mac
//  writes back onto synced Session records.
//
//  Built directly on `CKDatabase`'s save/fetch operations, NOT
//  `CKSyncEngine` — its delegate never fired under any tested condition
//  (clean install, fresh zone, confirmed-available account), while a raw
//  `CKDatabase.save(_:)` against the same container succeeded immediately.
//  This uses the same well-established, directly observable APIs.
//
//  Step 1 of Phase 2 (this file): a single custom zone in the developer's
//  own private database, no CKShare yet — that's layered in step 2, once
//  the schema and ingestion pipeline are proven end to end. Manual/
//  foreground-triggered sync only; no push/CKQuerySubscription yet.
//

import CloudKit
import Foundation
import JalanKitaKit
import Observation

@MainActor
protocol CloudKitSyncDataSource: AnyObject {
    func session(withID id: String) -> Session?
    func clipFileURL(sessionID: String, clipIndex: Int) -> URL?
    func gpsCSVFileURL(sessionID: String) -> URL?
    func gpsSummary(sessionID: String) -> SyncedGPSTrack?
    var calibrationProfile: CalibrationProfile? { get }
    func calibrationFrameFileURL() -> URL?
    /// A Session record came back from the cloud with fields the Mac owns
    /// (status, segmentCount) changed — apply it to local state.
    func applyIncomingSession(_ session: Session)
    /// The Mac finished analyzing a parking candidate and pushed the result
    /// back — image/BEV already copied to a stable local file by the sync
    /// engine, ready to persist and display.
    func applyIncomingParkingResult(_ result: DownloadedParkingResult)
}

@MainActor
@Observable
final class CloudKitSyncEngine {
    private(set) var lastError: String?
    private(set) var isSyncing = false

    weak var dataSource: CloudKitSyncDataSource?

    private let zoneID: CKRecordZone.ID
    private let database: CKDatabase
    private let zoneProvisionedKey: String
    private let changeTokenFileURL: URL
    private let syncStates: SessionSyncStateStore
    private let appSupportDir: URL

    /// Records waiting for the next `syncNow()` to actually push them.
    /// Rebuilt from current local state at `enqueue*` time, not persisted
    /// as an opaque blob — `AppModel` re-enqueues anything not yet
    /// `.synced` on launch (see its `init`), so a killed app before sync
    /// completes just re-queues next time rather than needing this set
    /// itself to survive a relaunch.
    private var pendingRecordIDs: Set<CKRecord.ID> = []
    private var changeToken: CKServerChangeToken?

    init(surveyorID: String, appSupportDir: URL, syncStates: SessionSyncStateStore) {
        let zoneName = CloudKitSchema.zoneName(surveyorID: surveyorID)
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        zoneProvisionedKey = "cloudkit_zone_provisioned_\(zoneName)"
        changeTokenFileURL = appSupportDir.appendingPathComponent("cloudkit_change_token_\(zoneName).data")
        self.syncStates = syncStates
        self.appSupportDir = appSupportDir
        database = CKContainer(identifier: CloudKitSchema.containerIdentifier).privateCloudDatabase
        changeToken = Self.loadChangeToken(from: changeTokenFileURL)
    }

    // MARK: - Enqueuing local changes

    func enqueueFullSessionUpload(_ session: Session) {
        syncStates.markUploading(session.id)
        pendingRecordIDs.insert(CKRecord.ID(recordName: session.id, zoneID: zoneID))
        for clipIndex in 0..<session.clipCount {
            pendingRecordIDs.insert(SyncedClip(sessionID: session.id, clipIndex: clipIndex).recordID(zoneID: zoneID))
        }
        pendingRecordIDs.insert(CKRecord.ID(recordName: "\(session.id)#gps", zoneID: zoneID))
    }

    func enqueueCalibrationUpload() {
        guard let profile = dataSource?.calibrationProfile else { return }
        pendingRecordIDs.insert(profile.recordID(zoneID: zoneID))
    }

    func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await ensureZoneProvisioned()
            try await sendPendingRecords()
            try await fetchRemoteChanges()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[CloudKitSyncEngine/iOS] syncNow() FAILED: \(error)")
        }
    }

    private func ensureZoneProvisioned() async throws {
        guard !UserDefaults.standard.bool(forKey: zoneProvisionedKey) else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        UserDefaults.standard.set(true, forKey: zoneProvisionedKey)
    }

    // MARK: - Sending

    private func sendPendingRecords() async throws {
        guard !pendingRecordIDs.isEmpty else { return }
        var recordsToSave: [CKRecord] = []
        for recordID in pendingRecordIDs {
            if let record = await buildRecord(for: recordID) {
                recordsToSave.append(record)
            }
        }
        guard !recordsToSave.isEmpty else { return }

        let result = try await database.modifyRecords(saving: recordsToSave, deleting: [], savePolicy: .changedKeys, atomically: false)
        for (recordID, saveResult) in result.saveResults {
            switch saveResult {
            case .success:
                pendingRecordIDs.remove(recordID)
                recordSaveSucceeded(recordID)
            case .failure(let error):
                print("[CloudKitSyncEngine/iOS] FAILED to save \(recordID.recordName): \(error)")
                if let ckError = error as? CKError {
                    recordSaveFailed(recordID, error: ckError)
                }
            }
        }
    }

    // MARK: - Fetching

    private func fetchRemoteChanges() async throws {
        var moreComing = true
        while moreComing {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken, desiredKeys: nil, resultsLimit: nil)
            for (_, modificationResult) in result.modificationResultsByID {
                switch modificationResult {
                case .success(let modification):
                    applyFetchedRecord(modification.record)
                case .failure(let error):
                    print("[CloudKitSyncEngine/iOS] fetch modification failed: \(error)")
                }
            }
            changeToken = result.changeToken
            Self.saveChangeToken(changeToken, to: changeTokenFileURL)
            moreComing = result.moreComing
        }
    }

    private func applyFetchedRecord(_ record: CKRecord) {
        switch record.recordType {
        case CloudKitSchema.RecordType.session:
            guard let session = Session(record: record) else { return }
            dataSource?.applyIncomingSession(session)
        case CloudKitSchema.RecordType.parkingResult:
            guard let synced = SyncedParkingResult(record: record),
                  let downloaded = downloadParkingResult(synced, record: record) else { return }
            dataSource?.applyIncomingParkingResult(downloaded)
        default:
            // Clip/GPSTrack/CalibrationProfile records the iOS side wrote
            // itself, and the schema-only SegmentResult stub — nothing to
            // apply locally for either today.
            break
        }
    }

    /// Copies `imageAsset`/`bevAsset` off the fetched `CKRecord` to a stable
    /// local file — a fetched `CKAsset`'s `fileURL` points at CloudKit's own
    /// temporary copy, not guaranteed to outlive the record that referenced
    /// it (same reasoning as the Mac's `SyncedSessionIngestor.copyAsset`).
    private func downloadParkingResult(_ synced: SyncedParkingResult, record: CKRecord) -> DownloadedParkingResult? {
        guard let imageAsset = record[CloudKitSchema.ParkingResultField.imageAsset] as? CKAsset,
              let imageSourceURL = imageAsset.fileURL,
              let summaryData = synced.summaryJSON.data(using: .utf8),
              let summary = try? JSONDecoder().decode(DisturbanceSummary.self, from: summaryData)
        else { return nil }

        let dir = appSupportDir
            .appendingPathComponent("ParkingResults", isDirectory: true)
            .appendingPathComponent(synced.sessionID, isDirectory: true)
            .appendingPathComponent(synced.candidateID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let localImageURL = Self.copyAsset(from: imageSourceURL, to: dir.appendingPathComponent("image.jpg")) else { return nil }
        var localBEVURL: URL?
        if let bevAsset = record[CloudKitSchema.ParkingResultField.bevAsset] as? CKAsset,
           let bevSourceURL = bevAsset.fileURL {
            localBEVURL = Self.copyAsset(from: bevSourceURL, to: dir.appendingPathComponent("bev.png"))
        }

        return DownloadedParkingResult(
            sessionID: synced.sessionID,
            candidateID: synced.candidateID,
            sourceKind: synced.sourceKind,
            carTrackID: synced.carTrackID,
            disturbance: synced.disturbance,
            imageWidth: synced.imageWidth,
            imageHeight: synced.imageHeight,
            createdAt: synced.createdAt,
            localImageURL: localImageURL,
            localBEVURL: localBEVURL,
            summary: summary
        )
    }

    private static func copyAsset(from sourceURL: URL, to destinationURL: URL) -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        do {
            try fm.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    // MARK: - Building records to send

    private func buildRecord(for recordID: CKRecord.ID) async -> CKRecord? {
        let name = recordID.recordName
        guard let dataSource else {
            print("[CloudKitSyncEngine/iOS] buildRecord(\(name)): dataSource is nil")
            return nil
        }

        if let session = dataSource.session(withID: name) {
            return session.makeRecord(recordID: recordID)
        }

        if name.hasPrefix("calibration-") {
            guard let profile = dataSource.calibrationProfile else {
                print("[CloudKitSyncEngine/iOS] buildRecord(\(name)): no calibrationProfile in data source")
                return nil
            }
            let record = profile.makeRecord(recordID: recordID)
            if let frameURL = dataSource.calibrationFrameFileURL() {
                record[CloudKitSchema.CalibrationField.frameAsset] = CKAsset(fileURL: frameURL)
            }
            return record
        }

        if name.hasSuffix("#gps") {
            let sessionID = String(name.dropLast(4))
            guard let summary = dataSource.gpsSummary(sessionID: sessionID) else {
                print("[CloudKitSyncEngine/iOS] buildRecord(\(name)): no gpsSummary for session \(sessionID)")
                return nil
            }
            guard let csvURL = dataSource.gpsCSVFileURL(sessionID: sessionID) else {
                print("[CloudKitSyncEngine/iOS] buildRecord(\(name)): gps.csv not found for session \(sessionID)")
                return nil
            }
            let record = summary.makeRecord(recordID: recordID)
            record[CloudKitSchema.GPSTrackField.csvAsset] = CKAsset(fileURL: csvURL)
            return record
        }

        let parts = name.split(separator: "#")
        if parts.count == 2, let clipIndex = Int(parts[1]) {
            let sessionID = String(parts[0])
            guard let fileURL = dataSource.clipFileURL(sessionID: sessionID, clipIndex: clipIndex) else {
                print("[CloudKitSyncEngine/iOS] buildRecord(\(name)): clip_\(clipIndex).mov not found for session \(sessionID)")
                return nil
            }
            let clip = SyncedClip(sessionID: sessionID, clipIndex: clipIndex)
            let record = clip.makeRecord(recordID: recordID)
            record[CloudKitSchema.ClipField.videoAsset] = CKAsset(fileURL: fileURL)
            return record
        }

        print("[CloudKitSyncEngine/iOS] buildRecord(\(name)): matched no known record shape")
        return nil
    }

    // MARK: - Bookkeeping sent changes

    private func recordSaveSucceeded(_ recordID: CKRecord.ID) {
        let name = recordID.recordName
        guard !name.hasPrefix("calibration-") else { return }

        if name.hasSuffix("#gps") {
            let sessionID = String(name.dropLast(4))
            syncStates.markGPSTrackUploaded(sessionID)
            checkFullyUploaded(sessionID: sessionID)
            return
        }
        let parts = name.split(separator: "#")
        if parts.count == 2, let clipIndex = Int(parts[1]) {
            let sessionID = String(parts[0])
            syncStates.markClipUploaded(sessionID, clipIndex: clipIndex)
            checkFullyUploaded(sessionID: sessionID)
            return
        }
        // Bare session ID.
        checkFullyUploaded(sessionID: name)
    }

    private func recordSaveFailed(_ recordID: CKRecord.ID, error: CKError) {
        let name = recordID.recordName
        let sessionID = name.hasSuffix("#gps") ? String(name.dropLast(4)) : (name.split(separator: "#").first.map(String.init) ?? name)
        syncStates.markFailed(sessionID, error: error.localizedDescription)
    }

    private func checkFullyUploaded(sessionID: String) {
        guard let session = dataSource?.session(withID: sessionID) else { return }
        if syncStates.isFullyUploaded(sessionID: sessionID, clipCount: session.clipCount) {
            syncStates.markSynced(sessionID)
        }
    }

    // MARK: - CKShare (invite the Mac desk operator)

    /// The container `UICloudSharingController` needs alongside a share.
    var containerForSharing: CKContainer {
        CKContainer(identifier: CloudKitSchema.containerIdentifier)
    }

    /// Fetches this surveyor's existing zone-wide share, creating one if
    /// it doesn't exist yet. Because the share is zone-wide (not
    /// per-record), every Session/Clip/GPSTrack/CalibrationProfile record
    /// created in this zone — past or future — is automatically covered
    /// once accepted; the surveyor never re-invites for a new session.
    func fetchOrCreateShare() async throws -> CKShare {
        try await ensureZoneProvisioned()

        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let fetchResults = try? await database.records(for: [shareRecordID]),
           case .success(let record) = fetchResults[shareRecordID],
           let existingShare = record as? CKShare {
            return existingShare
        }

        let share = CKShare(recordZoneID: zoneID)
        // Anyone with the link can join as a read/write participant — this
        // app has no contacts/participant-lookup UI, so "copy the link,
        // send it any way you like" is the right fit for v1.
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = "Sesi survei JalanKita" as CKRecordValue
        _ = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys, atomically: true)
        return share
    }

    // MARK: - Change token persistence

    private static func loadChangeToken(from url: URL) -> CKServerChangeToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func saveChangeToken(_ token: CKServerChangeToken?, to url: URL) {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
