//
//  ParkingReportView.swift
//  JalanKita iOS
//
//  Candidate list for one session's parking-disturbance results — the iOS
//  equivalent of the Mac's ParkingCandidateStripView pane, pushed on its
//  own screen instead of sitting alongside a 4-pane HSplitView (no room for
//  that on a phone, and the session is already chosen by the time you get
//  here from Session Detail).
//

import SwiftUI
import JalanKitaKit

struct ParkingReportView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    private var results: [DownloadedParkingResult] {
        model.parkingResults(sessionID: sessionID).sorted { $0.candidateID < $1.candidateID }
    }

    var body: some View {
        List(results) { result in
            NavigationLink {
                ParkingCandidateDetailView(result: result)
            } label: {
                CandidateRow(result: result)
            }
        }
        .navigationTitle("Tinjauan Parkir")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if results.isEmpty {
                ContentUnavailableView("Belum ada hasil", systemImage: "car.fill")
            }
        }
    }
}

private struct CandidateRow: View {
    let result: DownloadedParkingResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let trackID = result.carTrackID {
                    Text("Mobil #\(trackID)")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("Foto diunggah")
                        .font(.subheadline.weight(.semibold))
                }
                if result.disturbance == true {
                    Text("PELANGGARAN")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            Text("\(result.rankedVehicles.count) kendaraan terukur")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
