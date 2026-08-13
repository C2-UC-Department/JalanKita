//
//  RoadDamageFrameStripView.swift
//  JalanKita Mac
//
//  Stage 3's counterpart to `ParkingCandidateStripView` — the same sidebar-styled
//  selectable list, over sampled frames instead of tracked cars.
//
//  Sorted by timestamp rather than by severity on purpose. A reviewer works down a
//  road in the order they drove it, and re-ordering by score would break the
//  correspondence with both the timeline above and the video's own playhead.
//  Severity is carried by the badge instead, where it can be scanned without
//  moving anything.
//

import SwiftUI
import JalanKitaKit

struct RoadDamageFrameStripView: View {
    let frames: [ReviewFrame]
    @Binding var selectedFrameID: ReviewFrame.ID?

    private var sortedFrames: [ReviewFrame] {
        frames.sorted { ($0.sessionRelativeSeconds ?? 0) < ($1.sessionRelativeSeconds ?? 0) }
    }

    var body: some View {
        List(sortedFrames, selection: $selectedFrameID) { frame in
            FrameRow(frame: frame)
                .tag(frame.id)
        }
        .listStyle(.sidebar)
        .frame(height: 132)
    }
}

private struct FrameRow: View {
    let frame: ReviewFrame

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(frame.timecode)
                        .font(.data(12, weight: .medium))
                    if frame.findings.isEmpty {
                        Text("bersih")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        SeverityBadge(severity: frame.severity, size: .compact)
                    }
                }
                Text(secondaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !frame.findings.isEmpty {
                Text("\(frame.score)")
                    .font(.data(13, weight: .semibold))
                    .foregroundStyle(frame.severity.literalColor)
            }
        }
        .padding(.vertical, 2)
    }

    /// The defect mix, deduplicated and in a stable order — "2 lubang · 1 retak
    /// garis" rather than a bare count, because which defect it is changes what the
    /// reviewer does about it.
    private var secondaryLine: String {
        guard !frame.findings.isEmpty else { return "frame \(frame.frameNumber)" }
        let grouped: [DefectType: [Finding]] = Dictionary(grouping: frame.findings, by: \.defectType)
        var counts: [(type: DefectType, count: Int)] = []
        for (type, findings) in grouped {
            counts.append((type: type, count: findings.count))
        }
        counts.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.type.label < rhs.type.label : lhs.count > rhs.count
        }
        let parts: [String] = counts.map { "\($0.count) \($0.type.label.lowercased())" }
        return parts.joined(separator: " · ")
    }
}
