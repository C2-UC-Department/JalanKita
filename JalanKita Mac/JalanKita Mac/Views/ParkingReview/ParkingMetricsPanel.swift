//
//  ParkingMetricsPanel.swift
//  JalanKita Mac
//
//  Right pane of Tinjauan Parkir: the "2 · Measured disturbance" stage of
//  app.py's Streamlit workflow, ported almost directly — 5 StatTiles (the
//  same component SessionInboxView's statRow already uses), the re-rendered
//  BEV image (magenta highlight follows `selectedVehicleID` via
//  AppModel.selectParkingVehicle), and a ranked Table of every vehicle
//  mirroring app.py's `st.dataframe`.
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

    private var zeroAreaCount: Int {
        analysis.summary.vehicles.count - analysis.rankedVehicles.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statGrid
                bevSection
                tableSection

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

    // MARK: - Stat tiles

    private var statGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "TERUKUR")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                StatTile(
                    title: selectedVehicle == nil ? "TERPILIH" : "#\(selectedVehicle!.id) JALAN TERTUTUP",
                    value: formatted(selectedVehicle?.areaM2), unit: "m²",
                    detail: "Jalan yang disembunyikan kendaraan ini, dikalibrasi dengan prior tinggi kamera.",
                    accent: .accentColor
                )
                StatTile(
                    title: "BAGIAN JALAN AMODAL", value: formatted(percentShare), unit: "%",
                    detail: "Kebal terhadap skala — angka paling bisa dipercaya."
                )
                StatTile(
                    title: "SEMUA PENGHALANG", value: formatted(analysis.summary.total.occludedRoadM2), unit: "m²",
                    detail: "\(formatted(analysis.summary.total.occludedPct))% dari jalan amodal"
                )
                StatTile(
                    title: "TANPA KALIBRASI", value: formatted(selectedVehicle?.areaM2Raw), unit: "m²",
                    detail: "Skala depth monokuler mentah, belum dikoreksi tinggi kamera."
                )
                StatTile(
                    title: "LEBAR MAKS TERBLOKIR", value: formatted(selectedVehicle?.widthMaxPct), unit: "%",
                    detail: "Bagian terlebar jalan yang terblokir di satu potongan melintang terburuknya."
                )
            }
        }
    }

    private var percentShare: Double? {
        ParkingMetrics.percentOfSurface(area: selectedVehicle?.areaM2,
                                        ofTotal: analysis.summary.total.amodalRoadM2)
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

    // MARK: - Ranked table

    private struct VehicleRow: Identifiable {
        let id: Int
        let label: String
        let score: String
        let source: String
        let areaM2: String
        let areaM2Raw: String
        let widthMaxPct: String
    }

    private var tableRows: [VehicleRow] {
        analysis.rankedVehicles.map { v in
            VehicleRow(
                id: v.id, label: ParkingMetrics.label(for: v.label),
                score: v.score.map { String(format: "%.2f", $0) } ?? "blob",
                source: v.source,
                areaM2: formatted(v.areaM2), areaM2Raw: formatted(v.areaM2Raw),
                widthMaxPct: formatted(v.widthMaxPct)
            )
        }
    }

    private var tableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "SEMUA KENDARAAN")
            Table(tableRows) {
                TableColumn("#") { row in Text("\(row.id)").font(.data(12)) }.width(28)
                TableColumn("Label") { row in Text(row.label).font(.system(size: 12)) }.width(72)
                TableColumn("Skor") { row in Text(row.score).font(.data(12)).foregroundStyle(.secondary) }.width(48)
                TableColumn("Jalan m²") { row in Text(row.areaM2).font(.data(12, weight: .semibold)) }.width(70)
                TableColumn("Tanpa kalibrasi") { row in Text(row.areaM2Raw).font(.data(12)).foregroundStyle(.secondary) }.width(96)
                TableColumn("Lebar maks %") { row in Text(row.widthMaxPct).font(.data(12)) }.width(88)
            }
            .frame(minHeight: 200, idealHeight: 260)

            VStack(alignment: .leading, spacing: 2) {
                if zeroAreaCount > 0 {
                    Text("+ \(zeroAreaCount) penghalang lain tanpa jalan terukur")
                }
                Text("tak teratribusi: \(formatted(analysis.summary.unattributed.areaM2)) m²")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
