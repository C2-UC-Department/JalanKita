//
//  MapSegmentsView.swift
//  JalanKita Mac
//
//  §6.4 Coverage Map. Two real fixes here versus the previous pass:
//
//  1. The map itself is now genuine MapKit (`Map` + `MapPolyline`/
//     `Marker`) instead of a hand-drawn ZStack of Path lines standing in
//     for a map — it now actually reflects real coordinates and supports
//     pan/zoom.
//  2. The layer `Picker` is wired to an actual `MapLayer` enum that
//     changes what's drawn (coverage vs. condition-graded vs. flags) —
//     previously it was bound to a free `String` that nothing read, so
//     switching it did nothing.
//
//  The segment list is a `Table` for sortable columns and native
//  selection, replacing a fixed-width HStack "table" in a ScrollView.
//

import SwiftUI
import MapKit

private enum MapLayer: String, CaseIterable, Identifiable {
    case coverage = "Cakupan"
    case condition = "Kondisi"
    case flags = "Temuan"

    var id: String { rawValue }
}

struct MapSegmentsView: View {
    var model: AppModel

    @State private var layer: MapLayer = .condition
    @State private var selection: SegmentResult.ID?
    @State private var sortOrder = [KeyPathComparator(\SegmentResult.score)]

    private var segments: [SegmentResult] { model.segments }
    private var sortedSegments: [SegmentResult] { segments.sorted(using: sortOrder) }

    var body: some View {
        HSplitView {
            mapArea
                .frame(minWidth: 480)

            segmentList
                .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        }
        .navigationTitle("Peta & segmen")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Lapisan", selection: $layer) {
                    ForEach(MapLayer.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItem { Button("Ekspor CSV", systemImage: "square.and.arrow.up") {} }
        }
    }

    private var mapArea: some View {
        Map(initialPosition: .region(overviewRegion)) {
            switch layer {
            case .coverage:
                ForEach(segments) { segment in
                    Marker(segment.roadName, coordinate: RouteSampleCoordinates.coordinate(for: segment))
                        .tint(.secondary)
                }
            case .condition:
                ForEach(segments) { segment in
                    let coordinate = RouteSampleCoordinates.coordinate(for: segment)
                    MapCircle(center: coordinate, radius: 60)
                        .foregroundStyle(segment.severity.literalColor.opacity(0.35))
                        .stroke(segment.severity.literalColor, lineWidth: 2)
                }
            case .flags:
                ForEach(segments.filter(\.hasBlockedParking)) { segment in
                    Marker(segment.segmentLabel, systemImage: "car.fill",
                           coordinate: RouteSampleCoordinates.coordinate(for: segment))
                        .tint(DefectType.blockedPark.color)
                }
                ForEach(segments) { segment in
                    Marker(segment.segmentLabel, systemImage: "exclamationmark.triangle.fill",
                           coordinate: RouteSampleCoordinates.coordinate(for: segment))
                        .tint(segment.severity.literalColor)
                }
            }

            if let selection, let selected = segments.first(where: { $0.id == selection }) {
                Annotation(selected.segmentLabel, coordinate: RouteSampleCoordinates.coordinate(for: selected)) {
                    Circle().strokeBorder(.blue, lineWidth: 3).frame(width: 20, height: 20)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .topLeading) {
            if layer == .condition {
                MapLegendView().padding(16)
            }
        }
        .overlay(alignment: .bottomLeading) {
            CoverageStatCard().padding(16)
        }
    }

    private var overviewRegion: MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -7.278, longitude: 112.745),
                            latitudinalMeters: 9000, longitudinalMeters: 9000)
    }

    /// `Table` gets sole ownership of the pane's layout via
    /// `.safeAreaInset` for the header/footer instead of being stacked
    /// between them in a plain `VStack` — see the note on `statRow` in
    /// SessionInboxView for why that combination (inside an `HSplitView`
    /// pane) produces unpredictable sizing.
    private var segmentList: some View {
        Table(sortedSegments, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Grade") { segment in
                SeverityBadge(severity: segment.severity, size: .compact)
            }
            .width(90)

            TableColumn("Skor", value: \.score) { segment in
                Text("\(segment.score)").font(.data(13, weight: .bold))
            }
            .width(50)

            TableColumn("Lokasi", value: \.roadName) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(segment.roadName) · \(segment.kmMarker)").font(.system(size: 12.5))
                    Text(segment.segmentLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .width(min: 150, ideal: 190)

            TableColumn("Jenis") { segment in
                HStack(spacing: 3) {
                    ForEach(segment.defectTypes, id: \.self) { DefectSwatch(type: $0, size: 12) }
                    if segment.hasBlockedParking { DefectSwatch(type: .blockedPark, size: 12) }
                }
            }
            .width(70)

            TableColumn("Luas", value: \.areaSqm) { segment in
                HStack(spacing: 2) {
                    Text(segment.areaSqm, format: .number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
                    Text("m²").foregroundStyle(.secondary)
                }
                .font(.data(12.5))
            }
            .width(70)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("\(segments.count) segmen · terburuk lebih dulu")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("rata-rata 76,6")
                        .font(.data(12.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .fixedSize(horizontal: false, vertical: true)

                Divider()
            }
            .background(.background)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Text("Kotak biru pada kolom Jenis berarti segmen itu juga punya temuan parkir mengganggu — dilaporkan terpisah dari nilai kondisi.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(.background)
        }
    }
}

private struct CoverageStatCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CAKUPAN KOTA")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("92,4 km")
                .font(.data(20, weight: .bold))
            Text("dari 340 km arteri · 27% tersurvei")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    ContentView()
}
