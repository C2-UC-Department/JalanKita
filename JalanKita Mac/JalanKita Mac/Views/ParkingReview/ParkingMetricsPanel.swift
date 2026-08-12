//
//  ParkingMetricsPanel.swift
//  JalanKita Mac
//
//  Right pane of Tinjauan Parkir: just the three stats that matter for a
//  human reviewer, sitting above the re-rendered BEV image (magenta
//  highlight follows `selectedVehicleID` via AppModel.selectParkingVehicle).
//  The detected-vehicle frame itself now draws directly on the video player
//  (`ParkingVideoReviewView`), not here. The full ranked-vehicle table and
//  the raw/uncalibrated stats were dropped: with the pipeline (not a
//  manual tap) already deciding which vehicle is the flagged one, a table
//  of every OFRSNet occluder had nothing left to do.
//
//  A vehicle's own physical width in meters isn't one of these three —
//  the Python worker (src/disturbance.py) never computes it at all, only
//  road width (`width_road_m_at_max`, "LEBAR JALAN" below) and the road's
//  blocked-width percentage. Adding a real vehicle-width figure would be a
//  pipeline change, not a UI one.
//

import SwiftUI
import JalanKitaKit

struct ParkingMetricsPanel: View {
    let analysis: ParkingAnalysis
    let selectedVehicleID: Int?

    @State private var bevImage: NSImage?

    private var selectedVehicle: VehicleSummary? {
        analysis.summary.vehicles.first { $0.id == selectedVehicleID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statGrid
                bevSection

                Text(scaleCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 380, idealWidth: 460, maxWidth: 540)
        .task(id: analysis.bevPNGPath) {
            bevImage = analysis.bevPNGPath.flatMap { NSImage(contentsOfFile: $0) }
        }
    }

    // MARK: - BEV

    private var bevSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "TAMPILAN ATAS (BEV)")
            if let bevImage {
                Image(nsImage: bevImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            } else {
                ContentUnavailableView("BEV tidak tersedia", systemImage: "square.dashed")
                    .frame(height: 160)
            }
            Text("hijau = jalan terlihat · sian = jalan tersembunyi · putih = jejak kontak tiap kendaraan · magenta = bagian kendaraan terpilih")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stat tiles

    private var statGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "TERUKUR")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                StatTile(
                    title: "JALAN TERTUTUP OLEH MOBIL", value: formatted(selectedVehicle?.areaM2), unit: "m²",
                    detail: "Jalan yang disembunyikan kendaraan ini, dikalibrasi dengan prior tinggi kamera.",
                    accent: .accentColor
                )
                StatTile(
                    title: "LEBAR JALAN TERBLOKIR", value: formatted(selectedVehicle?.widthMaxPct), unit: "%",
                    detail: "Bagian terlebar jalan yang terblokir di satu potongan melintang terburuknya."
                )
                StatTile(
                    title: "LEBAR JALAN", value: formatted(selectedVehicle?.roadWidthM, decimals: 2), unit: "m",
                    detail: "Lebar jalan sebenarnya di potongan melintang terburuk kendaraan ini."
                )
            }
        }
    }

    // MARK: - Formatting

    private var scaleCaption: String {
        let s = analysis.summary.scale
        var note = "tinggi kamera \(formatted(s.cameraHeightM, decimals: 2)) m (\(s.mode)"
        if s.mode == "auto_vehicle_height", let n = s.nSamples {
            note += ", \(n) mobil"
        }
        note += ")"
        return "Jalan amodal \(formatted(analysis.summary.total.amodalRoadM2)) m² · "
             + "terlihat \(formatted(analysis.summary.total.visibleRoadM2)) m² · "
             + "terukur sampai \(formatted(analysis.summary.resolution.measurableRangeM)) m · \(note)"
    }

    private func formatted(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
    }
}
