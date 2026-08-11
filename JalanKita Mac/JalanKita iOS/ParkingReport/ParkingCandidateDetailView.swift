//
//  ParkingCandidateDetailView.swift
//  JalanKita iOS
//
//  Single scrollable column combining what the Mac splits across
//  VehicleCandidatesCanvasView + ParkingMetricsPanel — no room for a 2-pane
//  layout on a phone. Read-only: unlike the Mac, tapping a different
//  vehicle here cannot re-render the BEV (that requires calling back into
//  the Python OFRSNet worker, which only runs on the Mac) — selecting a
//  vehicle only changes which StatTiles/overlay highlight, matching
//  whatever the Mac already rendered the BEV for.
//

import SwiftUI
import JalanKitaKit

struct ParkingCandidateDetailView: View {
    let result: DownloadedParkingResult

    @State private var selectedVehicleID: Int?
    @State private var loadedImage: UIImage?
    @State private var loadedBEV: UIImage?

    private var selectedVehicle: VehicleSummary? {
        result.summary.vehicles.first { $0.id == selectedVehicleID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                candidateImage
                statGrid
                bevSection
                vehicleList
            }
            .padding()
        }
        .navigationTitle(result.carTrackID.map { "Mobil #\($0)" } ?? "Foto diunggah")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadedImage = UIImage(contentsOfFile: result.localImageURL.path)
            loadedBEV = result.localBEVURL.flatMap { UIImage(contentsOfFile: $0.path) }
            // No candidate bbox synced from the Mac (see DownloadedParkingResult),
            // so Dice-matching against v13's own candidate box isn't possible
            // here — default to the largest-area vehicle, same fallback the
            // Mac's own `ParkingAnalysis.bestMatchVehicleID` uses.
            selectedVehicleID = result.rankedVehicles.first?.id
        }
    }

    // MARK: - Candidate image + overlays

    private var candidateImage: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                ForEach(result.summary.vehicles, id: \.id) { vehicle in
                    let rect = ParkingMetrics.normalizedRect(for: vehicle, imageWidth: result.imageWidth, imageHeight: result.imageHeight)
                    if rect.width > 0, rect.height > 0 {
                        VehicleOverlay(vehicle: vehicle, isSelected: vehicle.id == selectedVehicleID)
                            .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                            .position(x: (rect.minX + rect.width / 2) * geo.size.width,
                                     y: (rect.minY + rect.height / 2) * geo.size.height)
                            .onTapGesture {
                                guard vehicle.selectable else { return }
                                selectedVehicleID = vehicle.id
                            }
                    }
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
    }

    private var aspectRatio: CGFloat {
        guard let size = loadedImage?.size, size.height > 0 else { return 3.0 / 4.0 }
        return size.width / size.height
    }

    private var background: Image {
        if let loadedImage {
            Image(uiImage: loadedImage)
        } else {
            Image(systemName: "photo")
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
                    detail: "Jalan yang disembunyikan kendaraan ini.",
                    accent: .accentColor
                )
                StatTile(
                    title: "BAGIAN JALAN AMODAL", value: formatted(percentShare), unit: "%",
                    detail: "Kebal terhadap skala."
                )
                StatTile(
                    title: "SEMUA PENGHALANG", value: formatted(result.summary.total.occludedRoadM2), unit: "m²",
                    detail: "\(formatted(result.summary.total.occludedPct))% dari jalan amodal"
                )
                StatTile(
                    title: "LEBAR MAKS TERBLOKIR", value: formatted(selectedVehicle?.widthMaxPct), unit: "%",
                    detail: "Bagian terlebar jalan yang terblokir."
                )
            }
        }
    }

    private var percentShare: Double? {
        ParkingMetrics.percentOfSurface(area: selectedVehicle?.areaM2, ofTotal: result.summary.total.amodalRoadM2)
    }

    // MARK: - BEV

    private var bevSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "TAMPILAN ATAS (BEV)")
            if let loadedBEV {
                Image(uiImage: loadedBEV)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            } else {
                ContentUnavailableView("BEV tidak tersedia", systemImage: "square.dashed")
                    .frame(height: 160)
            }
            Text("hijau = jalan terlihat · sian = jalan tersembunyi · putih = jejak kontak · magenta = kendaraan terpilih")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ranked list

    private var vehicleList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "SEMUA KENDARAAN")
            ForEach(result.rankedVehicles, id: \.id) { vehicle in
                Button {
                    selectedVehicleID = vehicle.id
                } label: {
                    HStack {
                        Text("#\(vehicle.id) \(ParkingMetrics.label(for: vehicle.label))")
                            .font(.subheadline.weight(vehicle.id == selectedVehicleID ? .bold : .regular))
                        Spacer()
                        Text("\(formatted(vehicle.areaM2)) m²")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    // MARK: - Formatting

    private func formatted(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }
}

private struct VehicleOverlay: View {
    let vehicle: VehicleSummary
    let isSelected: Bool

    private var color: Color {
        if isSelected { return Color(red: 1.0, green: 0, blue: 0.78) }
        return vehicle.selectable ? Color(red: 0.86, green: 0.24, blue: 0.20) : Color(white: 0.6)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: isSelected ? 3 : 1.5)
            Text("#\(vehicle.id) \(ParkingMetrics.label(for: vehicle.label))")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: -20)
        }
        .shadow(color: isSelected ? color.opacity(0.6) : .clear, radius: 8)
        .contentShape(Rectangle())
    }
}
