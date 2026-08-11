//
//  ParkingTimelineView.swift
//  JalanKita Mac
//
//  Compact horizontal timeline for Tinjauan Parkir: one tick per candidate,
//  positioned by `ParkingAnalysis.sessionRelativeSeconds` along the
//  session's total duration — lets a reviewer see at a glance which
//  timestamps in the video have a parked-vehicle detection, instead of
//  clicking through every candidate in the strip one at a time to find out.
//

import SwiftUI
import JalanKitaKit

struct ParkingTimelineView: View {
    let analyses: [ParkingAnalysis]
    let totalSeconds: Double
    @Binding var selectedAnalysisID: ParkingAnalysis.ID?

    private var ticked: [ParkingAnalysis] {
        analyses.filter { $0.sessionRelativeSeconds != nil }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: geo.size.width, height: 4)

                ForEach(ticked) { analysis in
                    tick(for: analysis, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: 28)
        }
        .frame(height: 28)
    }

    private func tick(for analysis: ParkingAnalysis, width: CGFloat) -> some View {
        let seconds = analysis.sessionRelativeSeconds ?? 0
        let fraction = totalSeconds > 0 ? min(max(seconds / totalSeconds, 0), 1) : 0
        let isSelected = analysis.id == selectedAnalysisID
        return Button {
            selectedAnalysisID = analysis.id
        } label: {
            Circle()
                .fill(analysis.carCandidate?.disturbance == true ? Color.red : Color.accentColor)
                .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2 : 0))
                .shadow(radius: isSelected ? 2 : 0)
        }
        .buttonStyle(.plain)
        .position(x: fraction * width, y: 14)
        .help(Self.formattedTimestamp(seconds))
    }

    static func formattedTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
