//
//  ParkingSessionListView.swift
//  JalanKita Mac
//
//  Left pane of Tinjauan Parkir: every session with a real, stored
//  ParkingAnalysis (model.parkingReviewSessions — not `status == .done`
//  broadly, since SampleData's dummy "done" video sessions have nothing real
//  to show). Selection default/reset lives in the parent (ParkingReviewView),
//  matching how ProcessingQueueView/ReviewFindingsView own their own
//  selection state rather than each pane managing it independently.
//

import SwiftUI

struct ParkingSessionListView: View {
    let model: AppModel
    @Binding var selectedSessionID: Session.ID?

    var body: some View {
        Group {
            if model.parkingReviewSessions.isEmpty {
                ContentUnavailableView(
                    "Belum ada foto diproses",
                    systemImage: "parkingsign.circle",
                    description: Text("Unggah foto lewat \"Unggah foto…\" di Antrean pemrosesan untuk melihat hasilnya di sini.")
                )
            } else {
                List(model.parkingReviewSessions, selection: $selectedSessionID) { session in
                    ParkingSessionRow(session: session, analyses: model.parkingAnalyses[session.id] ?? [])
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
    }
}

private struct ParkingSessionRow: View {
    let session: Session
    let analyses: [ParkingAnalysis]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.roadName)
                .font(.system(size: 13, weight: .semibold))
            Text("\(session.date) · \(candidateCountText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Counts CANDIDATE PHOTOS (one per car v13 flagged PARKED in this
    /// session's video, or the single manual photo upload), not vehicles
    /// within a photo — that finer count lives per-candidate now, shown once
    /// one is selected in the middle pane.
    private var candidateCountText: String {
        switch analyses.count {
        case 0: "—"
        case 1: "1 foto"
        default: "\(analyses.count) foto"
        }
    }
}
