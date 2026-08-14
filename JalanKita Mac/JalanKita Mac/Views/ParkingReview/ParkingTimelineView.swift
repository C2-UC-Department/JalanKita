//
//  ParkingTimelineView.swift
//  JalanKita Mac
//
//  The session's one shared timeline: parking-disturbance ticks (magenta) and
//  road-damage ticks (red) on the same line, positioned by
//  `sessionRelativeSeconds` against one total duration — a reviewer sees both
//  verticals' timestamps at a glance, including when they coincide, without
//  scanning two stacked rows or switching a tab to see the other one.
//
//  Was parking-only (hence the name); road damage's own `RoadDamageTimelineView`
//  merged in here since both drew an identical Capsule-track/GeometryReader/tick
//  pattern and putting them on one physical line was the whole point of merging.
//

import SwiftUI
import JalanKitaKit

struct ParkingTimelineView: View {
    let analyses: [ParkingAnalysis]
    let damageFrames: [ReviewFrame]
    let totalSeconds: Double
    @Binding var selectedAnalysisID: ParkingAnalysis.ID?
    @Binding var selectedFrameID: ReviewFrame.ID?

    /// Fired on every tap, even one that reselects the already-selected tick —
    /// `selectedAnalysisID`/`selectedFrameID` alone can't drive the seek and the
    /// strip/pane switch, because a tap that doesn't change the ID (the common
    /// case right after load, when the first candidate of each kind is already
    /// selected) produces no `onChange`, so re-tapping it would silently do
    /// nothing.
    var onSelectAnalysis: (ParkingAnalysis) -> Void = { _ in }
    var onSelectFrame: (ReviewFrame) -> Void = { _ in }

    private var tickedAnalyses: [ParkingAnalysis] {
        analyses.filter { $0.sessionRelativeSeconds != nil }
    }

    private var tickedFrames: [ReviewFrame] {
        damageFrames.filter { $0.sessionRelativeSeconds != nil }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: geo.size.width, height: 4)

                ForEach(tickedAnalyses) { analysis in
                    analysisTick(for: analysis, width: geo.size.width)
                }
                ForEach(tickedFrames) { frame in
                    damageTick(for: frame, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: 28)
        }
        .frame(height: 28)
    }

    private func analysisTick(for analysis: ParkingAnalysis, width: CGFloat) -> some View {
        let seconds = analysis.sessionRelativeSeconds ?? 0
        let fraction = totalSeconds > 0 ? min(max(seconds / totalSeconds, 0), 1) : 0
        let isSelected = analysis.id == selectedAnalysisID
        return Button {
            selectedAnalysisID = analysis.id
            onSelectAnalysis(analysis)
        } label: {
            // The dot itself is only 10-14pt — too small a target to reliably hit
            // with a mouse, especially now that a magenta and a red tick can sit
            // right next to each other. `.contentShape` grows the tappable area
            // to a comfortable column around the dot without changing how big it
            // looks.
            Color.clear
                .frame(width: 20, height: 28)
                .overlay(
                    Circle()
                        .fill(Color.parkingMarker)
                        .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                        .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2 : 0))
                        .shadow(radius: isSelected ? 2 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: fraction * width, y: 14)
        .help(Self.formattedTimestamp(seconds))
    }

    /// Colour carries severity, not detection: a frame the detector answered for
    /// with no findings at all is still a tick (the road WAS looked at there),
    /// drawn hollow so a clean stretch is visibly surveyed rather than visibly
    /// absent — that distinction matters to a reviewer deciding where the
    /// coverage gaps are, so it survives the flat-red recolor below it.
    private func damageTick(for frame: ReviewFrame, width: CGFloat) -> some View {
        let seconds = frame.sessionRelativeSeconds ?? 0
        let fraction = totalSeconds > 0 ? min(max(seconds / totalSeconds, 0), 1) : 0
        let isSelected = frame.id == selectedFrameID
        let hasFindings = !frame.findings.isEmpty
        return Button {
            selectedFrameID = frame.id
            onSelectFrame(frame)
        } label: {
            // Same enlarged hit area as `analysisTick`, see comment there.
            Color.clear
                .frame(width: 20, height: 28)
                .overlay(
                    Circle()
                        .fill(hasFindings ? Color.roadDamageMarker : Color.clear)
                        .overlay(Circle().stroke(hasFindings ? Color.clear : Color.secondary, lineWidth: 1.5))
                        .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                        .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2 : 0))
                        .shadow(radius: isSelected ? 2 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: fraction * width, y: 14)
        .help(damageHelpText(for: frame, seconds: seconds))
    }

    private func damageHelpText(for frame: ReviewFrame, seconds: Double) -> String {
        let stamp = Self.formattedTimestamp(seconds)
        guard !frame.findings.isEmpty else { return "\(stamp) · tidak ada temuan" }
        return "\(stamp) · \(frame.findings.count) temuan · skor \(frame.score)"
    }

    static func formattedTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

extension Color {
    /// Parking-disturbance marker color, shared with `DetectedVehicleOverlay`'s
    /// on-video box in `ParkingVideoReviewView` — one hue, one meaning, wherever
    /// this vertical shows up on screen.
    static let parkingMarker = Color(red: 1.0, green: 0, blue: 0.78)

    /// Road-damage marker color, for the same reason.
    static let roadDamageMarker = Color.red
}
