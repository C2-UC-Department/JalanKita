//
//  ParkingReviewView.swift
//  JalanKita Mac
//
//  "Tinjauan Parkir": the real parking-disturbance pipeline's own review
//  screen, replacing the earlier stopgap of merging its one blockedPark
//  finding into Peninjauan's ReviewFrame. Walks the same two stages as
//  app.py's Streamlit app — select the parked vehicle, read off the road
//  area it takes out of use — but as a native screen with a session list in
//  front (Streamlit only ever looks at one image at a time).
//
//  A plain `HStack` for the three panes, not `HSplitView`: ReviewFindingsView
//  documents why a nested 3-pane HSplitView inside NavigationSplitView's
//  detail slot corrupts the outer window sidebar's rendering — the same
//  constraint applies here, so the same fix applies here.
//

import SwiftUI

struct ParkingReviewView: View {
    var model: AppModel

    @State private var selectedSessionID: Session.ID?
    @State private var selectedVehicleID: Int?

    private var analysis: ParkingAnalysis? {
        selectedSessionID.flatMap { model.parkingAnalyses[$0] }
    }

    var body: some View {
        HStack(spacing: 0) {
            ParkingSessionListView(model: model, selectedSessionID: $selectedSessionID)

            if let analysis {
                VehicleCandidatesCanvasView(analysis: analysis, selectedVehicleID: $selectedVehicleID)
                    .padding(24)
                    .frame(minWidth: 420, maxWidth: .infinity)

                ParkingMetricsPanel(analysis: analysis, selectedVehicleID: selectedVehicleID)
            } else {
                ContentUnavailableView("Pilih sesi", systemImage: "parkingsign.circle",
                                       description: Text("Pilih sesi di sebelah kiri untuk melihat kendaraan dan metrik parkirnya."))
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .navigationTitle("Tinjauan Parkir")
        .navigationSubtitle(subtitle)
        .task {
            // Sessions are appended in upload order, so the most recently
            // analyzed one is last — this is what makes landing here right
            // after an upload pre-select the photo that was just processed.
            if selectedSessionID == nil {
                selectedSessionID = model.parkingReviewSessions.last?.id
            }
        }
        .onChange(of: selectedSessionID) { _, newValue in
            guard let newValue, let analysis = model.parkingAnalyses[newValue] else {
                selectedVehicleID = nil
                return
            }
            selectedVehicleID = analysis.rankedVehicles.first?.id
        }
        .onChange(of: selectedVehicleID) { _, newValue in
            guard let sessionID = selectedSessionID else { return }
            Task { await model.selectParkingVehicle(sessionID: sessionID, vehicleID: newValue) }
        }
    }

    private var subtitle: String {
        guard let analysis else { return "\(model.parkingReviewSessions.count) sesi" }
        return "\(analysis.rankedVehicles.count) kendaraan terukur"
    }
}
