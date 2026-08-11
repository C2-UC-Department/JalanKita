//
//  CloudKitSyncEngine.swift
//  JalanKita Mac
//
//  Fetches Session/Clip/GPSTrack/CalibrationProfile records synced up by
//  the iOS app, and pushes ParkingResult records + Session status updates
//  back.
//
//  Built directly on `CKDatabase`'s save/fetch operations, NOT
//  `CKSyncEngine` — see the iOS side's identical engine for why:
//  `CKSyncEngine`'s delegate never fired under any tested condition
//  (clean install, fresh zone, confirmed-available account), while a raw
//  `CKDatabase.save(_:)` against the same container succeeded immediately.
//  This hand-rolled version uses the same directly-observable APIs.
//
//  Step 2 of Phase 2 (this file): operates against BOTH this Mac's own
//  `privateCloudDatabase` (the step-1 solo-dev-testing path, kept working
//  so nothing regresses) AND `sharedCloudDatabase` (every surveyor zone
//  this Mac has accepted a CKShare invite for). Zones are discovered via
//  `CKDatabase.databaseChanges(since:)` on each database independently —
//  no zone ID is ever hardcoded, so a newly accepted surveyor's zone just
//  shows up on the next `syncNow()` with no other code change. A record's
//  target database for both reads and writes is derived from its
//  `recordID.zoneID.ownerName`: `CKCurrentUserDefaultName` means "a zone
//  this Mac owns" (private), anything else means "a zone owned by a
//  surveyor who shared it" (shared).
//

import CloudKit
import Foundation
import JalanKitaKit
import Observation

@MainActor
protocol CloudKitIngestDelegate: AnyObject {
    func didFetchSession(_ session: Session, zoneID: CKRecordZone.ID)
    func didFetchClip(sessionID: String, clipIndex: Int, localFileURL: URL)
    func didFetchGPSTrack(sessionID: String, localFileURL: URL)
    func didFetchCalibration(_ profile: CalibrationProfile, localFrameURL: URL?)
}

@MainActor
@Observable
final class CloudKitSyncEngine {
    /// Posted by `AppDelegate.application(_:userDidAcceptCloudKitShareWith:)`
    /// when the user clicks a share link locally on the Mac — carries the
    /// `CKShare.Metadata` under this key. `CloudKitSyncEngine` listens for
    /// this itself (registered in `init`) since `AppDelegate` is created
    /// before `AppModel`/this engine exist (see `JalanKita_MacApp.swift`),
    /// so a direct reference isn't available at delegate-callback time.
    static let shareAcceptedNotification = Notification.Name("CloudKitSyncEngine.shareAccepted")
    static let shareMetadataUserInfoKey = "metadata"

    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var isAcceptingShare = false

    weak var ingestDelegate: CloudKitIngestDelegate?

    private let container: CKContainer
    private let privateDatabase: CKDatabase
    private let sharedDatabase: CKDatabase
    private let tokenDirectory: URL

    /// Records this Mac owes CloudKit a save for. Built fresh from
    /// `AppModel` state at enqueue time — if the app quits before a send
    /// completes, `AppModel` re-derives what still needs pushing from its
    /// own `sessions`/`parkingAnalyses` state on next launch rather than
    /// this registry needing to survive a relaunch.
    private var outgoingRecords: [CKRecord.ID: CKRecord] = [:]
    private var databaseChangeTokens: [String: CKServerChangeToken] = [:]
    private var zoneChangeTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]

    init(appSupportDir: URL) {
        tokenDirectory = appSupportDir.appendingPathComponent("CloudKitTokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: tokenDirectory, withIntermediateDirectories: true)
        container = CKContainer(identifier: CloudKitSchema.containerIdentifier)
        privateDatabase = container.privateCloudDatabase
        sharedDatabase = container.sharedCloudDatabase
        databaseChangeTokens["private"] = Self.loadToken(from: Self.databaseTokenURL("private", in: tokenDirectory))
        databaseChangeTokens["shared"] = Self.loadToken(from: Self.databaseTokenURL("shared", in: tokenDirectory))

        // No corresponding `removeObserver` — this engine is owned by
        // `AppModel` for the entire app lifetime (see `JalanKita Mac`'s
        // `AppModel.init`), so the observer never needs early teardown.
        NotificationCenter.default.addObserver(
            forName: Self.shareAcceptedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let metadata = note.userInfo?[Self.shareMetadataUserInfoKey] as? CKShare.Metadata else { return }
            Task { await self?.acceptShare(metadata: metadata) }
        }
    }

    func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await fetchAllChanges()
            try await sendOutgoingRecords()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[CloudKitSyncEngine/Mac] syncNow() FAILED: \(error)")
        }
    }

    // MARK: - Accepting a surveyor's share

    /// The "paste invite link" fallback — the primary, relied-upon accept
    /// path for v1, since macOS's automatic link-routing to
    /// `userDidAcceptCloudKitShareWith` is an undocumented OS heuristic
    /// with no reliable way to test it deterministically.
    func acceptShare(url: URL) async {
        isAcceptingShare = true
        defer { isAcceptingShare = false }
        do {
            let results = try await container.shareMetadatas(for: [url])
            guard let result = results[url] else {
                lastError = "Tidak ada metadata untuk tautan ini."
                return
            }
            switch result {
            case .success(let metadata):
                await acceptShare(metadata: metadata)
            case .failure(let error):
                lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Shared by both the paste-link path and `AppDelegate`'s automatic
    /// `userDidAcceptCloudKitShareWith` callback.
    func acceptShare(metadata: CKShare.Metadata) async {
        isAcceptingShare = true
        defer { isAcceptingShare = false }
        do {
            let results = try await container.accept([metadata])
            for (_, result) in results {
                if case .failure(let error) = result {
                    lastError = error.localizedDescription
                    return
                }
            }
            lastError = nil
            // The newly accepted zone won't show up until the next
            // database-level change fetch — trigger one immediately
            // rather than waiting for the next foreground/manual sync.
            await syncNow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pushes a Session record back into the zone it came from — used
    /// after this Mac transitions `statusCase`/`statusProgress`/
    /// `statusReason`/`segmentCount`, the fields it's sole writer of.
    func enqueueSessionUpdate(_ session: Session, zoneID: CKRecordZone.ID) {
        let recordID = CKRecord.ID(recordName: session.id, zoneID: zoneID)
        outgoingRecords[recordID] = session.makeRecord(recordID: recordID)
    }

    func enqueueParkingResult(_ result: SyncedParkingResult, zoneID: CKRecordZone.ID, imageFileURL: URL?, bevFileURL: URL?) {
        let recordID = result.recordID(zoneID: zoneID)
        let record = result.makeRecord(recordID: recordID)
        if let imageFileURL {
            record[CloudKitSchema.ParkingResultField.imageAsset] = CKAsset(fileURL: imageFileURL)
        }
        if let bevFileURL {
            record[CloudKitSchema.ParkingResultField.bevAsset] = CKAsset(fileURL: bevFileURL)
        }
        outgoingRecords[recordID] = record
    }

    // MARK: - Sending

    /// A zone owned by `CKCurrentUserDefaultName` is one this Mac created
    /// itself (step-1 solo-testing path) and lives in the private
    /// database; anything else is a surveyor's zone reached through an
    /// accepted share, in the shared database.
    private func targetDatabase(for zoneID: CKRecordZone.ID) -> CKDatabase {
        zoneID.ownerName == CKCurrentUserDefaultName ? privateDatabase : sharedDatabase
    }

    private func sendOutgoingRecords() async throws {
        guard !outgoingRecords.isEmpty else { return }
        let grouped = Dictionary(grouping: outgoingRecords.values) { $0.recordID.zoneID.ownerName == CKCurrentUserDefaultName }
        for (isPrivate, records) in grouped {
            let database = isPrivate ? privateDatabase : sharedDatabase
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys, atomically: false)
            for (recordID, saveResult) in result.saveResults {
                switch saveResult {
                case .success:
                    outgoingRecords.removeValue(forKey: recordID)
                case .failure(let error):
                    print("[CloudKitSyncEngine/Mac] FAILED to save \(recordID.recordName): \(error)")
                    lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Fetching

    private func fetchAllChanges() async throws {
        try await fetchDatabaseChanges(database: privateDatabase, tokenKey: "private")
        try await fetchDatabaseChanges(database: sharedDatabase, tokenKey: "shared")
    }

    /// Discovers changed/new zones in `database` (this is how a
    /// surveyor's shared zone shows up here the first time, with no
    /// hardcoded zone ID anywhere), then fetches record-level changes for
    /// each.
    private func fetchDatabaseChanges(database: CKDatabase, tokenKey: String) async throws {
        var changedZoneIDs: Set<CKRecordZone.ID> = []
        var token = databaseChangeTokens[tokenKey]
        var moreZonesComing = true
        while moreZonesComing {
            let result = try await database.databaseChanges(since: token, resultsLimit: nil)
            for modification in result.modifications {
                changedZoneIDs.insert(modification.zoneID)
            }
            token = result.changeToken
            moreZonesComing = result.moreComing
        }
        databaseChangeTokens[tokenKey] = token
        Self.saveToken(token, to: Self.databaseTokenURL(tokenKey, in: tokenDirectory))

        for zoneID in changedZoneIDs {
            try await fetchRecordZoneChanges(database: database, zoneID: zoneID)
        }
    }

    private func fetchRecordZoneChanges(database: CKDatabase, zoneID: CKRecordZone.ID) async throws {
        var token = zoneChangeTokens[zoneID] ?? Self.loadToken(from: Self.zoneTokenURL(zoneID, in: tokenDirectory))
        var moreComing = true
        while moreComing {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: nil, resultsLimit: nil)
            for (_, modificationResult) in result.modificationResultsByID {
                switch modificationResult {
                case .success(let modification):
                    applyFetchedRecord(modification.record)
                case .failure(let error):
                    print("[CloudKitSyncEngine/Mac] fetch modification failed in zone \(zoneID.zoneName): \(error)")
                }
            }
            token = result.changeToken
            moreComing = result.moreComing
        }
        zoneChangeTokens[zoneID] = token
        Self.saveToken(token, to: Self.zoneTokenURL(zoneID, in: tokenDirectory))
    }

    private func applyFetchedRecord(_ record: CKRecord) {
        switch record.recordType {
        case CloudKitSchema.RecordType.session:
            guard let session = Session(record: record) else { return }
            ingestDelegate?.didFetchSession(session, zoneID: record.recordID.zoneID)

        case CloudKitSchema.RecordType.clip:
            guard let clip = SyncedClip(record: record),
                  let asset = record[CloudKitSchema.ClipField.videoAsset] as? CKAsset,
                  let assetURL = asset.fileURL else { return }
            ingestDelegate?.didFetchClip(sessionID: clip.sessionID, clipIndex: clip.clipIndex, localFileURL: assetURL)

        case CloudKitSchema.RecordType.gpsTrack:
            guard let track = SyncedGPSTrack(record: record),
                  let asset = record[CloudKitSchema.GPSTrackField.csvAsset] as? CKAsset,
                  let assetURL = asset.fileURL else { return }
            ingestDelegate?.didFetchGPSTrack(sessionID: track.sessionID, localFileURL: assetURL)

        case CloudKitSchema.RecordType.calibrationProfile:
            guard let profile = CalibrationProfile(record: record) else { return }
            let asset = record[CloudKitSchema.CalibrationField.frameAsset] as? CKAsset
            ingestDelegate?.didFetchCalibration(profile, localFrameURL: asset?.fileURL)

        default:
            break
        }
    }

    // MARK: - Change token persistence

    private static func databaseTokenURL(_ key: String, in directory: URL) -> URL {
        directory.appendingPathComponent("database-\(key).token")
    }

    private static func zoneTokenURL(_ zoneID: CKRecordZone.ID, in directory: URL) -> URL {
        directory.appendingPathComponent("zone-\(zoneID.zoneName)-\(zoneID.ownerName).token")
    }

    private static func loadToken(from url: URL) -> CKServerChangeToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func saveToken(_ token: CKServerChangeToken?, to url: URL) {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
