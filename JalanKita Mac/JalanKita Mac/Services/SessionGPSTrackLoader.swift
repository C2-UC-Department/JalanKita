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
        return loadTimedTrack(url: url).map(\.coordinate)
    }

    struct TimedFix {
        let time: Date
        let coordinate: CLLocationCoordinate2D
    }

    /// Same file/format `loadCoordinates` reads, with the `time` column kept
    /// instead of discarded — what `nearestCoordinate` needs to place a parking
    /// candidate (`ParkingAnalysis.sessionRelativeSeconds`, converted to an
    /// absolute timestamp by the caller) on this same track.
    ///
    /// Takes the CSV's URL directly rather than a session id, unlike
    /// `loadCoordinates` — `nearestCoordinate` calls this with
    /// `AppModel.gpsCSVURL(sessionID:)`, which resolves EITHER a synced
    /// session's track OR a manual upload's demo companion CSV, whichever
    /// exists. `loadCoordinates` intentionally keeps its own synced-only path:
    /// its one caller (the route map) has never drawn a route for a manual
    /// upload, and widening that is a separate decision from this one.
    private static func loadTimedTrack(url: URL) -> [TimedFix] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var fixes: [TimedFix] = []
        // `whereSeparator: \.isNewline`, not `separator: "\n"` — see
        // RoadDamageFrameProvenance's own comment on this exact split. A synced
        // session's track is iOS-written and has not shown CRLF in practice, but
        // a manual upload's demo companion CSV goes through the same naive
        // parser as `frames_provenance.csv` and CAN be CRLF (Python's `csv`
        // module default) — the failure mode (every row silently vanishes, no
        // error) is bad enough to guard unconditionally.
        var lines = contents.split(whereSeparator: \.isNewline)[...]
        _ = lines.popFirst() // header: time,lat,lon

        for line in lines {
            let fields = line.split(separator: ",")
            guard fields.count == 3,
                  let time = Self.isoFormatter.date(from: String(fields[0])),
                  let lat = Double(fields[1]),
                  let lon = Double(fields[2])
            else { continue }
            fixes.append(TimedFix(time: time, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        }
        return fixes.sorted { $0.time < $1.time }
    }

    /// The GPS fix closest in time to `date` on `sessionID`'s track — synced or
    /// manual, whichever `AppModel.gpsCSVURL` finds — gated by `maxGapSeconds` so
    /// a candidate from a stretch the log doesn't cover (dropout, or well outside
    /// the recording) gets no coordinate rather than a misleadingly distant one —
    /// same gating `video_frames.py`'s `_nearest_gps` uses for road-damage frames.
    static func nearestCoordinate(sessionID: String, at date: Date,
                                  maxGapSeconds: Double = 5.0) -> CLLocationCoordinate2D? {
        guard let url = AppModel.gpsCSVURL(sessionID: sessionID) else { return nil }
        let track = loadTimedTrack(url: url)
        guard let nearest = track.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }),
              abs(nearest.time.timeIntervalSince(date)) <= maxGapSeconds
        else { return nil }
        return nearest.coordinate
    }

    private static let isoFormatter = ISO8601DateFormatter()
}
