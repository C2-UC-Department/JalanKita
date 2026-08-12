//
//  ParkingCandidateStripView.swift
//  JalanKita Mac
//
//  Candidate list under Tinjauan Parkir's video player/timeline — only
//  meaningful once a session can hold several ParkingAnalyses (v13's
//  uploadVideo, one per PARKED car it found). A manual photo upload still
//  produces exactly one, so this pane is a single unselectable-looking row
//  in that case rather than an extra click most users of that path will
//  ever need. `carCandidate` is nil for that case (see Models.swift) so the
//  extra v13 context (STOP_CLASS, depth, in-zone) simply doesn't render.
//

import SwiftUI
import JalanKitaKit

struct ParkingCandidateStripView: View {
    let analyses: [ParkingAnalysis]
    @Binding var selectedAnalysisID: ParkingAnalysis.ID?

    /// Chronological, not upload order — the whole point of surfacing a
    /// timestamp per candidate is to make "which timestamps have a
    /// detection" easy to scan top to bottom, not just left to right on the
    /// timeline above.
    private var sortedAnalyses: [ParkingAnalysis] {
        analyses.sorted { ($0.sessionRelativeSeconds ?? .infinity) < ($1.sessionRelativeSeconds ?? .infinity) }
    }

    var body: some View {
        List(sortedAnalyses, selection: $selectedAnalysisID) { analysis in
            CandidateRow(analysis: analysis)
        }
        .listStyle(.sidebar)
    }
}

private struct CandidateRow: View {
    let analysis: ParkingAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let candidate = analysis.carCandidate {
                    Text("Mobil #\(candidate.trackID)")
                        .font(.system(size: 12.5, weight: .semibold))
                    if candidate.disturbance {
                        Text("PELANGGARAN")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.red, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("Foto diunggah")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                Spacer()
            }
            Text(secondaryLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let seconds = analysis.sessionRelativeSeconds {
            parts.append(ParkingTimelineView.formattedTimestamp(seconds))
        }
        if let candidate = analysis.carCandidate {
            parts.append(candidate.stopClass)
            parts.append("depth: \(candidate.depthReading)")
        }
        return parts.joined(separator: " · ")
    }
}
