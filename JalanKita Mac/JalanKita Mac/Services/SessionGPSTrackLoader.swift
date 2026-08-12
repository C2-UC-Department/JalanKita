//
//  SessionGPSTrackLoader.swift
//  JalanKita Mac
//
//  Decodes a synced session's real gps.csv (downloaded by
//  SyncedSessionIngestor.didFetchGPSTrack, same `time,lat,lon` format the
//  iOS app itself writes and reads back for its own route map) into
//  coordinates for Sesi Masuk's route map — replacing the fake
//  RouteSampleCoordinates polyline that stood in for this before real GPS
//  sync existed. Only meaningful for a synced session; a manual upload has
//  no GPS track of its own.
//

import CoreLocation
import Foundation

enum SessionGPSTrackLoader {
    static func loadCoordinates(sessionID: String) -> [CLLocationCoordinate2D] {
        let url = AppModel.syncedSessionsDir()
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("gps.csv")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var coordinates: [CLLocationCoordinate2D] = []
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)[...]
        _ = lines.popFirst() // header: time,lat,lon

        for line in lines {
            let fields = line.split(separator: ",")
            guard fields.count == 3,
                  let lat = Double(fields[1]),
                  let lon = Double(fields[2])
            else { continue }
            coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return coordinates
    }
}
