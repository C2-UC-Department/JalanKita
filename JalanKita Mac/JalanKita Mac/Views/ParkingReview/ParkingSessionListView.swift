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
                    ParkingSessionRow(session: session, analysis: model.parkingAnalyses[session.id])
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
    }
}

private struct ParkingSessionRow: View {
    let session: Session
    let analysis: ParkingAnalysis?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.roadName)
                .font(.system(size: 13, weight: .semibold))
            Text("\(session.date) · \(vehicleCountText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var vehicleCountText: String {
        guard let analysis else { return "—" }
        let n = analysis.rankedVehicles.count
        return n == 1 ? "1 kendaraan" : "\(n) kendaraan"
    }
}
