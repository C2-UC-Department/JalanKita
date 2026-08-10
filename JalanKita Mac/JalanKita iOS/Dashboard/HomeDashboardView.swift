//
//  HomeDashboardView.swift
//  JalanKita iOS
//
//  §6.2 — minimal cut: Start Recording CTA + local session list. No sync
//  status or road-condition summary tile yet — those need CloudKit
//  (Phase 2/3), not built in this pass.
//

import SwiftUI
import JalanKitaKit

struct HomeDashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var isRecording = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isRecording = true
                    } label: {
                        Label("Mulai Merekam", systemImage: "record.circle.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 8)
                    .padding(.horizontal)
                }
                .listRowSeparator(.hidden)

                Section("SESI") {
                    if model.localSessions.isEmpty {
                        Text("Belum ada sesi terekam.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.localSessions) { session in
                            SessionRowView(session: session)
                        }
                    }
                }
            }
            .navigationTitle("JalanKita")
            .fullScreenCover(isPresented: $isRecording) {
                ActiveRecordingView()
            }
        }
    }
}
