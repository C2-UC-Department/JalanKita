//
//  CloudSyncSettingsView.swift
//  JalanKita Mac
//
//  Step 1 of Phase 2: a manual sync trigger against this Mac's own private
//  CloudKit database (same Apple ID as the iPhone during solo-dev
//  testing) — no CKShare/invite-acceptance UI yet, that's step 2. See
//  CloudKitSyncEngine's doc-comment for why this is a deliberate, scoped
//  starting point rather than the delivered end-state.
//

import SwiftUI
import JalanKitaKit

struct CloudSyncSettingsView: View {
    var model: AppModel
    @State private var isSyncing = false

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Wadah iCloud", value: CloudKitSchema.containerIdentifier)
                if let error = model.cloudKitSyncEngine.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Tidak ada galat", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Sesi") {
                LabeledContent("Total sesi", value: "\(model.sessions.count)")
                LabeledContent("Dari iPhone (punya jejak GPS asli)", value: "\(model.sessions.filter { $0.recordedDate != nil }.count)")
            }

            Section {
                Button {
                    Task {
                        isSyncing = true
                        await model.syncNow()
                        isSyncing = false
                    }
                } label: {
                    if isSyncing || model.cloudKitSyncEngine.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sinkronkan Sekarang", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing || model.cloudKitSyncEngine.isSyncing)
            } footer: {
                Text("Belum ada berbagi CKShare antar-surveyor pada tahap ini — Mac dan iPhone perlu masuk dengan Apple ID iCloud yang sama untuk pengujian.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sinkronisasi iCloud")
    }
}
