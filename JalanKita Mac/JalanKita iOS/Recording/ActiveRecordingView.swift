//
//  ActiveRecordingView.swift
//  JalanKita iOS
//
//  Design brief §6.3 — "the most important screen." Live camera preview
//  fills the background; everything else is glanceable, large-target, and
//  minimal, since the surveyor's attention is on driving. No manual
//  flag/tag buttons — the Mac-side pipeline determines damage/blockage
//  from the video alone, so GPS continuity is what this screen protects.
//

import MapKit
import SwiftUI
import JalanKitaKit

struct ActiveRecordingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var capture = CaptureSessionController()
    @State private var location = LocationTracker()
    @State private var sessionID = UUID().uuidString
    @State private var sessionDirectory: URL?
    @State private var startedAt = Date()
    @State private var roadName: String = ""
    @State private var didFinish = false
    @State private var isFinishing = false
    @State private var cameraError: String?
    @State private var mapCameraPosition: MapCameraPosition = .automatic

    var body: some View {
        ZStack {
            CameraPreviewView(session: capture.session)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomPanel
            }
            .padding()
        }
        .statusBarHidden()
        .task {
            await prepare()
        }
        .onDisappear {
            capture.stopPreview()
            location.stopLogging()
        }
    }

    private var topBar: some View {
        HStack {
            GPSStatusBadge(state: location.state)
            Spacer()
            Label(formattedElapsed, systemImage: "timer")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            if let cameraError {
                Text(cameraError)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.red, in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 12) {
                statTile(title: "JARAK", value: distanceLabel, unit: "km")
                statTile(title: "PENYIMPANAN", value: storageLabel, unit: nil)
                if location.pointCount > 0 {
                    statTile(title: "TITIK GPS", value: "\(location.pointCount)", unit: nil)
                }
            }

            liveMap
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.25), lineWidth: 1))

            if isFinishing {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Menyelesaikan rekaman…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 76)
            } else {
                HStack(spacing: 24) {
                    controlButton(
                        systemImage: capture.state == .recording ? "pause.fill" : "play.fill",
                        label: capture.state == .recording ? "Jeda" : "Lanjut",
                        tint: .white
                    ) {
                        if capture.state == .recording {
                            capture.pause()
                        } else {
                            capture.resume()
                        }
                    }

                    controlButton(systemImage: "stop.fill", label: "Berhenti", tint: .red) {
                        finish()
                    }
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    private var liveMap: some View {
        Map(position: $mapCameraPosition, interactionModes: []) {
            if location.trackCoordinates.count > 1 {
                MapPolyline(coordinates: location.trackCoordinates)
                    .stroke(Color.accentColor, lineWidth: 3)
            }
            if let coordinate = location.lastCoordinate {
                Marker("", coordinate: coordinate)
                    .tint(Color.accentColor)
            }
        }
        .onChange(of: location.pointCount) { _, _ in
            guard let coordinate = location.lastCoordinate else { return }
            mapCameraPosition = .region(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
            )
        }
    }

    private func statTile(title: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlButton(systemImage: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 76, height: 76)
                    .foregroundStyle(.white)
                    .background(tint == .red ? Color.red : Color.white.opacity(0.18), in: Circle())
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var formattedElapsed: String {
        let total = Int(capture.elapsedSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private var distanceLabel: String {
        String(format: "%.1f", location.distanceMeters / 1000)
    }

    private var storageLabel: String {
        guard let bytes = model.store.availableStorageBytes() else { return "—" }
        let gb = Double(bytes) / 1_000_000_000
        return String(format: "%.1f GB", gb)
    }

    private func prepare() async {
        let store = model.store
        let directory = store.newSessionDirectory(sessionID: sessionID)
        sessionDirectory = directory
        startedAt = Date()

        do {
            try capture.configureIfNeeded()
        } catch {
            cameraError = "Kamera tidak tersedia."
            return
        }
        // Recording must not start until the capture session has actually
        // finished starting — see startPreview()'s doc comment for why
        // starting it early is a plausible cause of erratic finalize times.
        await capture.startPreview()

        // GPS logging starts before video recording, and will be stopped
        // after it, so no video frame ever falls outside the track's span.
        location.requestAuthorization()
        try? location.startLogging(to: store.gpsCSVURL(for: directory))
        capture.startRecording(in: directory)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        isFinishing = true
        let tappedAt = Date()
        // No new video frames are captured once stopRecording() is called —
        // the remaining wait is purely disk finalization of already-shot
        // footage, so GPS logging (and the location hardware) can stop now
        // rather than continuing to run through that wait.
        location.stopLogging()
        capture.stop { clipURLs, elapsed in
            print("[ActiveRecordingView] capture.stop() completion fired \(Int(Date().timeIntervalSince(tappedAt) * 1000)) ms after tap")
            let session = Session(
                id: sessionID,
                roadName: roadName.isEmpty ? "Sesi belum diberi nama" : roadName,
                date: startedAt.formatted(date: .abbreviated, time: .shortened),
                surveyor: Surveyor(id: model.surveyorName, name: model.surveyorName),
                clipCount: clipURLs.count,
                duration: formattedDuration(elapsed),
                distanceKm: location.distanceMeters / 1000,
                gpsAccuracyM: location.lastAccuracyMeters.map { Int($0) },
                gpsHz: location.pointCount > 0 && elapsed > 0 ? Double(location.pointCount) / elapsed : nil,
                gpsGapNote: location.gpsGapNote,
                sizeGB: sessionSizeGB(),
                status: location.gpsGapNote == nil ? .readyToProcess : .degraded(reason: location.gpsGapNote ?? ""),
                recordedDate: startedAt,
                durationSeconds: elapsed
            )
            model.recordingFinished(session, gpsSummary: gpsSummary())
            print("[ActiveRecordingView] dismissing \(Int(Date().timeIntervalSince(tappedAt) * 1000)) ms after tap")
            dismiss()
        }
    }

    /// Bounding box + point count off the in-memory track — computed once
    /// here, while `location` is still in scope, rather than re-parsing
    /// `gps.csv` later every time the sync engine needs it.
    private func gpsSummary() -> SyncedGPSTrack {
        let coordinates = location.trackCoordinates
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        return SyncedGPSTrack(
            sessionID: sessionID,
            pointCount: location.pointCount,
            minLatitude: latitudes.min() ?? 0,
            minLongitude: longitudes.min() ?? 0,
            maxLatitude: latitudes.max() ?? 0,
            maxLongitude: longitudes.max() ?? 0
        )
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) j \(m) m" : "\(m) m"
    }

    private func sessionSizeGB() -> Double {
        guard let sessionDirectory else { return 0 }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let totalBytes = contents.reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return partial + size
        }
        return Double(totalBytes) / 1_000_000_000
    }
}

private struct GPSStatusBadge: View {
    let state: LocationTracker.GPSState

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color, in: Capsule())
    }

    private var text: String {
        switch state {
        case .notStarted: "MENCARI GPS"
        case .locked: "GPS TERKUNCI"
        case .degraded: "GPS LEMAH"
        case .lost: "TIDAK ADA GPS"
        }
    }

    private var symbol: String {
        switch state {
        case .notStarted: "location.circle"
        case .locked: "location.fill"
        case .degraded: "location.slash"
        case .lost: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .notStarted: Color(white: 0.3)
        case .locked: Color(red: 0.16, green: 0.62, blue: 0.35)
        case .degraded: Color(red: 0.93, green: 0.60, blue: 0.10)
        case .lost: Color(red: 0.86, green: 0.15, blue: 0.24)
        }
    }
}
