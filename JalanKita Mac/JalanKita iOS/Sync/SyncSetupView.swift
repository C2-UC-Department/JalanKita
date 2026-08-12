//
//  SyncSetupView.swift
//  JalanKita iOS
//
//  Step 2 of Phase 2: invites the Mac desk operator to this surveyor's
//  zone-wide CKShare. One invite ever, for one surveyor-Mac pairing — see
//  CloudKitSyncEngine.fetchOrCreateShare()'s doc comment for why sessions
//  recorded after accepting need no re-invite.
//

import CloudKit
import SwiftUI
import JalanKitaKit

struct SyncSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var share: CKShare?
    @State private var isPresentingShareSheet = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Wadah iCloud", value: CloudKitSchema.containerIdentifier)
                    LabeledContent("Surveyor", value: model.surveyorName.isEmpty ? "—" : model.surveyorName)
                } footer: {
                    Text("Bagikan zona Anda ke Mac operator sekali saja — setiap sesi baru yang direkam setelahnya otomatis ikut, tanpa perlu mengundang ulang.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await prepareAndPresentShare() }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Bagikan ke Mac…", systemImage: "person.badge.plus")
                        }
                    }
                    .disabled(isLoading)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sinkronisasi")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingShareSheet) {
                if let share {
                    CloudSharingControllerRepresentable(
                        share: share,
                        container: model.syncEngine.containerForSharing,
                        onDismiss: { isPresentingShareSheet = false }
                    )
                    .ignoresSafeArea()
                }
            }
        }
    }

    private func prepareAndPresentShare() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            share = try await model.syncEngine.fetchOrCreateShare()
            isPresentingShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
