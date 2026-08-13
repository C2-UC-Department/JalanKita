//
//  SessionDetailPanel.swift
//  JalanKita Mac
//
//  The route trace now renders with real MapKit (`Map` + `MapPolyline`)
//  instead of a hand-drawn Path over normalized 0...1 points. That was a
//  custom view standing in for something SwiftUI already ships natively,
//  and it bought nothing — real Map gives pan/zoom and correct aspect
//  ratio for free.
//

import SwiftUI
import MapKit
import JalanKitaKit

struct SessionDetailPanel: View {
    let session: Session
    var model: AppModel

    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var editedRoadName: String = ""

    private var hasParkingResults: Bool {
        !(model.parkingAnalyses[session.id]?.isEmpty ?? true)
    }

    /// Only a real synced session has a GPS track to show — a manual
    /// upload (`uploadImage`/`uploadVideo`) has none.
    private var isSyncedSession: Bool { session.recordedDate != nil }

    private var isReadyToProcess: Bool {
        if case .readyToProcess = session.status { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel(text: "SESI TERPILIH")

                VStack(alignment: .leading, spacing: 3) {
                    // Only a manually-uploaded session's name is editable —
                    // an iPhone recording's name comes from reverse
                    // geocoding at recording time and isn't renamable here.
                    if isSyncedSession {
                        Text(session.roadName)
                            .font(.title3.weight(.bold))
                    } else {
                        TextField("Nama sesi", text: $editedRoadName)
                            .font(.title3.weight(.bold))
                            .textFieldStyle(.plain)
                            .onSubmit {
                                model.renameSession(session.id, to: editedRoadName)
                            }
                            .task(id: session.id) {
                                editedRoadName = session.roadName
                            }
                    }
                    Text("\(session.date) · \(session.surveyor.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if isSyncedSession {
                    SessionRouteMap(coordinates: coordinates)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
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
                        .task(id: session.id) {
                            coordinates = SessionGPSTrackLoader.loadCoordinates(sessionID: session.id)
                        }
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    if isSyncedSession, isReadyToProcess {
                        Button("Proses sekarang") {
                            model.startProcessing(sessionID: session.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }

                    NavigationLink(value: session) {
                        Text("Buka video")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasParkingResults)
                }
                .controlSize(.large)
            }
            .padding(24)
        }
    }
}

/// A read-only route thumbnail built on real MapKit rather than a custom
/// normalized-coordinate Path drawing.
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
