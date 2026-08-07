//
//  ParkingCandidateStripView.swift
//  JalanKita Mac
//
//  Second pane of Tinjauan Parkir, between the session list and the canvas —
//  only meaningful once a session can hold several ParkingAnalyses (v13's
//  uploadVideo, one per PARKED car it found). A manual photo upload still
//  produces exactly one, so this pane is a single unselectable-looking row
//  in that case rather than an extra click most users of that path will
//  ever need. `carCandidate` is nil for that case (see Models.swift) so the
//  extra v13 context (STOP_CLASS, depth, in-zone) simply doesn't render.
//

import SwiftUI

struct ParkingCandidateStripView: View {
    let analyses: [ParkingAnalysis]
    @Binding var selectedAnalysisID: ParkingAnalysis.ID?

    var body: some View {
        List(analyses, selection: $selectedAnalysisID) { analysis in
            CandidateRow(analysis: analysis)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)
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
        var parts = ["\(analysis.rankedVehicles.count) kendaraan terukur"]
        if let candidate = analysis.carCandidate {
            parts.append(candidate.stopClass)
            parts.append("depth: \(candidate.depthReading)")
        }
        return parts.joined(separator: " · ")
    }
}
