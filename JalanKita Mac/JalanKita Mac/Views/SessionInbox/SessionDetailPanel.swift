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

struct SessionDetailPanel: View {
    let session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel(text: "SESI TERPILIH")

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.roadName)
                        .font(.title3.weight(.bold))
                    Text("\(session.date) · \(session.surveyor.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SessionRouteMap(coordinates: RouteSampleCoordinates.route(for: session.id))
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
                    .overlay(alignment: .topLeading) {
                        Text("JEJAK GPS · 6.412 TITIK")
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                    GridRow {
                        miniStat("FRAME @ 1 FPS", "6.442")
                        miniStat("SETELAH SARINGAN", "5.918")
                    }
                    GridRow {
                        miniStat("KALIBRASI DUDUKAN", "Dudukan A · 3,00 m")
                        miniStat("SEGMEN 10 M", "± 2.460")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "PIPELINE YANG AKAN DIJALANKAN")
                    VStack(alignment: .leading, spacing: 8) {
                        pipelinePreviewRow(1, "Ekstraksi frame · 1 fps")
                        pipelinePreviewRow(2, "Penggabungan jejak GPS")
                        pipelinePreviewRow(3, "Segmentasi kerusakan jalan")
                        pipelinePreviewRow(4, "Deteksi parkir mengganggu")
                        pipelinePreviewRow(5, "Penilaian keparahan & binning")
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    Button("Proses sekarang") {}
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)

                    Button("Buka video") {}
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(24)
        }
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.4)
            Text(value).font(.data(14, weight: .semibold))
        }
    }

    private func pipelinePreviewRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            Text(text).font(.system(size: 12.5))
            Spacer()
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
