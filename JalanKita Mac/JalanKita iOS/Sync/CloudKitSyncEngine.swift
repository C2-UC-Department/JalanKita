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
        guard record.recordType == CloudKitSchema.RecordType.session,
              let session = Session(record: record) else { return }
        dataSource?.applyIncomingSession(session)
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
