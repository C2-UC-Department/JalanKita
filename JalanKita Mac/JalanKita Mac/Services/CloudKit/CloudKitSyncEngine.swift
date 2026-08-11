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
//  Step 1 of Phase 2 (this file): operates against this Mac's own
//  `privateCloudDatabase` — for solo-dev testing, the same Apple ID
//  records on the iPhone and runs the Mac, so the iOS-provisioned zone is
//  already visible here with no CKShare involved. Zones are discovered via
//  `CKDatabase.databaseChanges(since:)`, not hardcoded — that's also
//  exactly the mechanism that'll keep working once step 2 (CKShare)
//  switches this to `sharedCloudDatabase` across every accepted surveyor
//  zone, since new zones showing up via a database-level change fetch is
//  the same shape either way.
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
    private(set) var lastError: String?
    private(set) var isSyncing = false

    weak var ingestDelegate: CloudKitIngestDelegate?

    private let database: CKDatabase
    private let tokenDirectory: URL

    /// Records this Mac owes CloudKit a save for. Built fresh from
    /// `AppModel` state at enqueue time — if the app quits before a send
    /// completes, `AppModel` re-derives what still needs pushing from its
    /// own `sessions`/`parkingAnalyses` state on next launch rather than
    /// this registry needing to survive a relaunch.
    private var outgoingRecords: [CKRecord.ID: CKRecord] = [:]
    private var databaseChangeToken: CKServerChangeToken?
    private var zoneChangeTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]

    init(appSupportDir: URL) {
        tokenDirectory = appSupportDir.appendingPathComponent("CloudKitTokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: tokenDirectory, withIntermediateDirectories: true)
        database = CKContainer(identifier: CloudKitSchema.containerIdentifier).privateCloudDatabase
        databaseChangeToken = Self.loadToken(from: Self.databaseTokenURL(in: tokenDirectory))
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

    private func sendOutgoingRecords() async throws {
        guard !outgoingRecords.isEmpty else { return }
        let records = Array(outgoingRecords.values)
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

    // MARK: - Fetching

    /// Discovers changed/new zones (this is how a surveyor's zone shows up
    /// here the first time, with no hardcoded zone ID anywhere), then
    /// fetches record-level changes for each.
    private func fetchAllChanges() async throws {
        var changedZoneIDs: Set<CKRecordZone.ID> = []
        var moreZonesComing = true
        while moreZonesComing {
            let result = try await database.databaseChanges(since: databaseChangeToken, resultsLimit: nil)
            for modification in result.modifications {
                changedZoneIDs.insert(modification.zoneID)
            }
            databaseChangeToken = result.changeToken
            moreZonesComing = result.moreComing
        }
        Self.saveToken(databaseChangeToken, to: Self.databaseTokenURL(in: tokenDirectory))

        for zoneID in changedZoneIDs {
            try await fetchRecordZoneChanges(zoneID: zoneID)
        }
    }

    private func fetchRecordZoneChanges(zoneID: CKRecordZone.ID) async throws {
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

    private static func databaseTokenURL(in directory: URL) -> URL {
        directory.appendingPathComponent("database.token")
    }

    private static func zoneTokenURL(_ zoneID: CKRecordZone.ID, in directory: URL) -> URL {
        directory.appendingPathComponent("zone-\(zoneID.zoneName).token")
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
