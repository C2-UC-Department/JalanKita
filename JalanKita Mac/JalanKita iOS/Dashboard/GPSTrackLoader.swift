//
//  GPSTrackLoader.swift
//  JalanKita iOS
//
//  Decodes a session's recorded `gps.csv` (written row-by-row by
//  LocationTracker as `time,lat,lon`) back into coordinates for the Session
//  Detail / Coverage Map route maps. Nothing parses this file back after
//  recording ends anywhere else today — `SyncedGPSTrack` only carries a
//  cheap bounding-box summary, not per-point data.
//

import CoreLocation
import Foundation

enum GPSTrackLoader {
    static func loadCoordinates(sessionID: String, store: RecordingSessionStore) -> [CLLocationCoordinate2D] {
        guard let url = store.gpsCSVFileURL(sessionID: sessionID),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

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
