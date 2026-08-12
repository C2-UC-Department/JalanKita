//
//  SessionDetailView.swift
//  JalanKita iOS
//
//  Mirrors the Mac's SessionDetailPanel where real data exists, drops what
//  doesn't apply here: no pipeline-preview checklist and no "Proses
//  sekarang"/"Buka video" buttons — running the pipeline is a Mac-operator
//  action, not something this phone does. The route map is real, unlike
//  the Mac's own RouteSampleCoordinates placeholder — this device actually
//  recorded the GPS track being drawn.
//

import MapKit
import SwiftUI
import JalanKitaKit

struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    @State private var coordinates: [CLLocationCoordinate2D] = []

    private var parkingResults: [DownloadedParkingResult] {
        model.parkingResults(sessionID: session.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                SessionRouteMap(coordinates: coordinates)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                    .overlay(alignment: .topLeading) {
                        if !coordinates.isEmpty {
                            Text("JEJAK GPS · \(coordinates.count) TITIK")
                                .font(.caption2.weight(.bold))
                                .tracking(0.5)
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    StatTile(title: "DURASI", value: session.duration)
                    StatTile(title: "JARAK", value: String(format: "%.1f", session.distanceKm), unit: "km")
                    StatTile(title: "KLIP", value: "\(session.clipCount)")
                    StatTile(title: "UKURAN", value: String(format: "%.2f", session.sizeGB), unit: "GB")
                    if let accuracy = session.gpsAccuracyM {
                        StatTile(title: "AKURASI GPS", value: "\(accuracy)", unit: "m")
                    }
                    if let hz = session.gpsHz {
                        StatTile(title: "FREKUENSI GPS", value: String(format: "%.1f", hz), unit: "Hz")
                    }
                }

                if let note = session.gpsGapNote {
                    Label(note, systemImage: "location.slash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                parkingSection
            }
            .padding()
        }
        .navigationTitle(session.roadName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            coordinates = GPSTrackLoader.loadCoordinates(sessionID: session.id, store: model.store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.roadName)
                        .font(.title2.weight(.bold))
                    Text("\(session.date) · \(session.surveyor.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                SessionStatusBadge(status: session.status)
                SyncStatusBadge(status: model.syncStates.state(for: session.id).status)
            }
        }
    }

    @ViewBuilder
    private var parkingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "TINJAUAN PARKIR")

            if parkingResults.isEmpty {
                Text(emptyParkingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink(value: ParkingReportRoute(sessionID: session.id)) {
                    HStack {
                        Label("\(parkingResults.count) kendaraan terdeteksi", systemImage: "car.fill")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyParkingMessage: String {
        switch session.status {
        case .done: "Tidak ada temuan parkir mengganggu untuk sesi ini."
        case .failed: "Pemrosesan gagal — tidak ada hasil untuk sesi ini."
        default: "Menunggu diproses di Mac."
        }
    }
}

/// Navigation value for pushing `ParkingReportView` from Session Detail.
struct ParkingReportRoute: Hashable {
    let sessionID: String
}

/// A read-only route map built on real MapKit — same idiom as the Mac's own
/// `SessionRouteMap` in `SessionDetailPanel.swift`, fed real recorded
/// coordinates here instead of `RouteSampleCoordinates` mock data.
struct SessionRouteMap: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        Map(initialPosition: .region(region)) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.primary, lineWidth: 3)
            }
            if let start = coordinates.first {
                Marker("Mulai", coordinate: start)
                    .tint(.green)
            }
            if let end = coordinates.last {
                Marker("Selesai", coordinate: end)
                    .tint(.red)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
    }

    private var region: MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: -7.2575, longitude: 112.7521),
                latitudinalMeters: 3000, longitudinalMeters: 3000)
        }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.8, first.latitude == 0 ? 0.01 : 0.012),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.8, 0.012))
        return MKCoordinateRegion(center: center, span: span)
    }
}
