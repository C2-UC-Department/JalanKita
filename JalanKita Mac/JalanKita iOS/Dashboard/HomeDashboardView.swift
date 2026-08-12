//
//  HomeDashboardView.swift
//  JalanKita iOS
//
//  §6.2 — minimal cut: Start Recording CTA + local session list. Sessions
//  sync to CloudKit in the background (manual/foreground-triggered only in
//  this phase — no push yet); the road-condition summary tile still needs
//  the road-damage pipeline to exist, so it stays deferred.
//

import SwiftUI
import UniformTypeIdentifiers
import JalanKitaKit

struct HomeDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRecording = false
    @State private var isPresentingSyncSetup = false
    @State private var isImportingVideo = false
    @State private var importError: String?

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

                    Button {
                        isImportingVideo = true
                    } label: {
                        Label("Impor Video", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .listRowInsets(EdgeInsets())
                    .padding(.horizontal)
                }
                .listRowSeparator(.hidden)

                if let error = model.syncEngine.lastError {
                    Section("SINKRONISASI") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

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
            .navigationDestination(for: Session.self) { session in
                SessionDetailView(session: session)
            }
            .navigationDestination(for: ParkingReportRoute.self) { route in
                ParkingReportView(sessionID: route.sessionID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresentingSyncSetup = true
                    } label: {
                        Label("Bagikan ke Mac", systemImage: "person.badge.plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        if model.syncEngine.isSyncing {
                            ProgressView()
                        } else {
                            Label("Sinkronkan", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(model.syncEngine.isSyncing)
                }
            }
            .fullScreenCover(isPresented: $isRecording) {
                ActiveRecordingView()
            }
            .sheet(isPresented: $isPresentingSyncSetup) {
                SyncSetupView()
            }
            .fileImporter(isPresented: $isImportingVideo, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url):
                    Task {
                        do {
                            try await model.importVideo(from: url)
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("Impor gagal", isPresented: .constant(importError != nil), presenting: importError) { _ in
                Button("OK") { importError = nil }
            } message: { message in
                Text(message)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await model.syncNow() }
            }
        }
    }
}
