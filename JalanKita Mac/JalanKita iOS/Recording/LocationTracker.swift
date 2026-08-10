//
//  LocationTracker.swift
//  JalanKita iOS
//
//  Logs a continuous GPS track to a CSV file at >=1Hz while recording.
//  This is the single most important artifact this app produces: with no
//  manual "damage"/"blocked" flagging (the Mac-side ML pipeline determines
//  those from the video alone), the GPS track is the only thing that lets
//  the desk pipeline attach a location to whatever it detects. Columns
//  match the desk pipeline's existing accepted schema (time/lat/lon) so
//  this file is drop-in compatible with extract_frames.py --gps-csv.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationTracker: NSObject {
    enum GPSState {
        case notStarted, locked, degraded, lost
    }

    private(set) var state: GPSState = .notStarted
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var lastAccuracyMeters: Double?
    private(set) var pointCount: Int = 0
    private(set) var distanceMeters: Double = 0
    private(set) var degradedEpisodeCount: Int = 0
    private(set) var lastCoordinate: CLLocationCoordinate2D?
    /// Full route so far, for the live map trace (§6.3). At 1Hz over a
    /// 3-hour shift this is ~10k points / ~170KB — trivial to hold in
    /// memory; the durable, full-resolution record is the CSV on disk.
    private(set) var trackCoordinates: [CLLocationCoordinate2D] = []

    private let manager = CLLocationManager()
    private var csvHandle: FileHandle?
    private var lastLocation: CLLocation?
    private var lastFixDate: Date?
    private var staleCheckTimer: Timer?

    private static let isoFormatter = ISO8601DateFormatter()

    override init() {
        authorizationStatus = .notDetermined
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        authorizationStatus = manager.authorizationStatus
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Starts logging to `csvURL`, writing a header row first. Callers
    /// should start this BEFORE video recording begins and call
    /// `stopLogging()` AFTER it ends, so no video frame ever falls outside
    /// the GPS track's timestamp span.
    func startLogging(to csvURL: URL) throws {
        FileManager.default.createFile(atPath: csvURL.path, contents: Data("time,lat,lon\n".utf8))
        csvHandle = try FileHandle(forWritingTo: csvURL)
        csvHandle?.seekToEndOfFile()
        pointCount = 0
        distanceMeters = 0
        degradedEpisodeCount = 0
        lastLocation = nil
        lastFixDate = nil
        trackCoordinates = []
        state = .notStarted
        manager.startUpdatingLocation()
        startStaleCheckTimer()
    }

    func stopLogging() {
        manager.stopUpdatingLocation()
        try? csvHandle?.close()
        csvHandle = nil
        staleCheckTimer?.invalidate()
        staleCheckTimer = nil
        state = .notStarted
    }

    private func startStaleCheckTimer() {
        staleCheckTimer?.invalidate()
        staleCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateStaleness() }
        }
    }

    private func evaluateStaleness() {
        guard let lastFixDate else { return }
        let age = Date().timeIntervalSince(lastFixDate)
        let previousState = state
        if age > 8 {
            state = .lost
        } else if age > 3 {
            state = .degraded
        }
        if previousState == .locked, state != .locked {
            degradedEpisodeCount += 1
        }
    }

    private func append(_ location: CLLocation) {
        pointCount += 1
        if let lastLocation {
            distanceMeters += location.distance(from: lastLocation)
        }
        lastLocation = location
        lastCoordinate = location.coordinate
        trackCoordinates.append(location.coordinate)
        lastAccuracyMeters = location.horizontalAccuracy
        lastFixDate = location.timestamp

        let previousState = state
        let isGoodFix = location.horizontalAccuracy > 0 && location.horizontalAccuracy < 30
        state = isGoodFix ? .locked : .degraded
        if previousState == .locked, state != .locked {
            degradedEpisodeCount += 1
        }

        let iso = Self.isoFormatter.string(from: location.timestamp)
        let row = "\(iso),\(location.coordinate.latitude),\(location.coordinate.longitude)\n"
        csvHandle?.write(Data(row.utf8))
    }

    /// Summary for `Session.gpsGapNote` — nil when the track never degraded.
    var gpsGapNote: String? {
        guard degradedEpisodeCount > 0 else { return nil }
        return "\(degradedEpisodeCount) interupsi GPS terdeteksi"
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in append(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in authorizationStatus = status }
    }
}
