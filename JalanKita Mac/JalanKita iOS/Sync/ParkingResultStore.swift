//
//  ParkingResultStore.swift
//  JalanKita iOS
//
//  Persists `DownloadedParkingResult`s the Mac has pushed back, keyed by
//  session ID. Persistence here is load-bearing, not a cache: CloudKit's
//  `recordZoneChanges` only redelivers records that changed since the last
//  server change token, so a result downloaded once would vanish from the
//  UI on next relaunch without this — nothing would ever re-fetch it.
//

import Foundation
import Observation

/// `@Observable` so a Session Detail / Parking Report screen updates live
/// as results arrive mid-sync — same reasoning as `SessionSyncStateStore`.
@MainActor
@Observable
final class ParkingResultStore {
    private let fileURL: URL
    private(set) var resultsBySessionID: [String: [DownloadedParkingResult]] = [:]

    init(appSupportDir: URL) {
        fileURL = appSupportDir.appendingPathComponent("parking_results.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        resultsBySessionID = (try? JSONDecoder().decode([String: [DownloadedParkingResult]].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(resultsBySessionID) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func results(sessionID: String) -> [DownloadedParkingResult] {
        resultsBySessionID[sessionID] ?? []
    }

    /// Inserts or replaces the result with the same `id` — CloudKit can
    /// redeliver an unchanged record (e.g. a full resync after a token
    /// reset), and this must stay idempotent rather than appending a
    /// duplicate.
    func upsert(_ result: DownloadedParkingResult) {
        var results = resultsBySessionID[result.sessionID] ?? []
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            results[index] = result
        } else {
            results.append(result)
        }
        resultsBySessionID[result.sessionID] = results
        save()
    }
}
