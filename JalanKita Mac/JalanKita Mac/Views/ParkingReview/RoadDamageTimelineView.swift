//
//  RoadDamageTimelineView.swift
//  JalanKita Mac
//
//  Stage 3's row of the session timeline: one tick per sampled frame, positioned
//  by `ReviewFrame.sessionRelativeSeconds` against the same total duration
//  `ParkingTimelineView` uses. Stacked directly under it so both verticals read
//  against one axis — which is the whole reason `sessionRelativeSeconds` exists on
//  both types.
//
//  Deliberately a sibling view rather than a second `ForEach` inside
//  `ParkingTimelineView`: that view is typed to `ParkingAnalysis` throughout, and
//  making it generic over "things with a timestamp" would cost more in indirection
//  than the twenty lines it would save.
//
//  Colour carries severity, not detection: a frame the detector answered for with
//  no findings at all is still a tick (the road WAS looked at there), drawn hollow
//  so a clean stretch is visibly surveyed rather than visibly absent. That
//  distinction matters to a reviewer deciding where the coverage gaps are.
//

import SwiftUI
import JalanKitaKit

struct RoadDamageTimelineView: View {
    let frames: [ReviewFrame]
    let totalSeconds: Double
    @Binding var selectedFrameID: ReviewFrame.ID?

    private var ticked: [ReviewFrame] {
        frames.filter { $0.sessionRelativeSeconds != nil }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: geo.size.width, height: 4)

                ForEach(ticked) { frame in
                    tick(for: frame, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: 28)
        }
        .frame(height: 28)
    }

    private func tick(for frame: ReviewFrame, width: CGFloat) -> some View {
        let seconds = frame.sessionRelativeSeconds ?? 0
        let fraction = totalSeconds > 0 ? min(max(seconds / totalSeconds, 0), 1) : 0
        let isSelected = frame.id == selectedFrameID
        let hasFindings = !frame.findings.isEmpty
        return Button {
            selectedFrameID = frame.id
        } label: {
            Circle()
                .fill(hasFindings ? frame.severity.literalColor : Color.clear)
                .overlay(Circle().stroke(hasFindings ? Color.clear : Color.secondary, lineWidth: 1.5))
                .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2 : 0))
                .shadow(radius: isSelected ? 2 : 0)
        }
        .buttonStyle(.plain)
        .position(x: fraction * width, y: 14)
        .help(helpText(for: frame, seconds: seconds))
    }

    private func helpText(for frame: ReviewFrame, seconds: Double) -> String {
        let stamp = ParkingTimelineView.formattedTimestamp(seconds)
        guard !frame.findings.isEmpty else { return "\(stamp) · tidak ada temuan" }
        return "\(stamp) · \(frame.findings.count) temuan · skor \(frame.score)"
    }
}
