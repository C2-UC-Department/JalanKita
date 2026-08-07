//
//  VehicleCandidatesCanvasView.swift
//  JalanKita Mac
//
//  The middle pane of Tinjauan Parkir: the actual uploaded photo with a
//  tappable, numbered overlay per detected occluder — the native equivalent
//  of app.py's `render_candidates` PNG + radio list, but interactive instead
//  of flat. Dynamic-image loading mirrors FrameCanvasView's original pattern
//  (that view itself reverted to a fixed bundled asset once real results
//  moved off Peninjauan onto this screen).
//

import SwiftUI

struct VehicleCandidatesCanvasView: View {
    let analysis: ParkingAnalysis
    @Binding var selectedVehicleID: Int?

    /// Tinjauan Parkir shows every OFRSNet occluder because a human is
    /// disambiguating which one is the flagged violation. The video pipeline
    /// already knows the answer (v13's own track) before OFRSNet ever runs,
    /// so showing every other car/truck in frame as a numbered, tappable
    /// candidate is just confusing noise there -- set this false to render
    /// only the selected vehicle, with no picker affordance.
    var showAllVehicles: Bool = true

    @State private var loadedImage: NSImage?

    private var aspectRatio: CGFloat {
        guard let size = loadedImage?.size, size.height > 0 else { return 3.0 / 4.0 }
        return size.width / size.height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                ForEach(visibleVehicles, id: \.id) { vehicle in
                    let rect = ParkingMetrics.normalizedRect(for: vehicle, imageWidth: analysis.imageWidth,
                                                             imageHeight: analysis.imageHeight)
                    if rect.width > 0, rect.height > 0 {
                        VehicleOverlay(vehicle: vehicle, isSelected: vehicle.id == selectedVehicleID)
                            .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                            .position(x: (rect.minX + rect.width / 2) * geo.size.width,
                                     y: (rect.minY + rect.height / 2) * geo.size.height)
                            .onTapGesture {
                                guard showAllVehicles, vehicle.selectable else { return }
                                selectedVehicleID = vehicle.id
                            }
                    }
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
        .task(id: analysis.imageURL) {
            loadedImage = NSImage(contentsOf: analysis.imageURL)
        }
    }

    private var visibleVehicles: [VehicleSummary] {
        showAllVehicles ? analysis.summary.vehicles : analysis.summary.vehicles.filter { $0.id == selectedVehicleID }
    }

    private var background: Image {
        if let loadedImage {
            Image(nsImage: loadedImage)
        } else {
            Image(systemName: "photo")
        }
    }
}

private struct VehicleOverlay: View {
    let vehicle: VehicleSummary
    let isSelected: Bool

    /// Matches `render_candidates`'s own color language: red for a
    /// selectable occluder, grey for one that isn't (e.g. a person), magenta
    /// for the current selection.
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
