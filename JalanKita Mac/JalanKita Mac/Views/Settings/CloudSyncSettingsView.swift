//
//  CloudSyncSettingsView.swift
//  JalanKita Mac
//
//  Manual sync trigger, plus Step 2's CKShare acceptance: a surveyor's
//  iPhone (Sync/SyncSetupView.swift) invites this Mac to their zone-wide
//  share and sends the resulting link by any channel. Pasting it here
//  (`CKContainer.shareMetadatas`/`accept`) is the primary, relied-upon
//  accept path — clicking the link locally on the Mac can also work via
//  AppDelegate's automatic `userDidAcceptCloudKitShareWith`, but that
//  OS-level routing is an undocumented heuristic this UI doesn't depend on.
//

import SwiftUI
import JalanKitaKit

struct CloudSyncSettingsView: View {
    var model: AppModel
    @State private var isSyncing = false
    @State private var shareLinkText = ""

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
                if connectedSurveyors.isEmpty {
                    Text("Belum ada sesi tersinkron dari surveyor manapun.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connectedSurveyors) { surveyor in
                        LabeledContent {
                            Text("\(surveyor.sessionCount) sesi")
                                .foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(surveyor.name)
                                if let lastDate = surveyor.mostRecentRecordedDate {
                                    Text("Terakhir: \(lastDate.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Surveyor terhubung")
            } footer: {
                Text("Daftar ini berasal dari sesi yang sudah tersinkron, bukan daftar undangan CKShare — belum ada pencarian peserta berbagi di layar ini.")
                    .foregroundStyle(.secondary)
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
            }

            Section {
                TextField("Tempel tautan undangan…", text: $shareLinkText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await acceptPastedLink() }
                } label: {
                    if model.cloudKitSyncEngine.isAcceptingShare {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Terima Undangan", systemImage: "person.badge.plus")
                    }
                }
                .disabled(model.cloudKitSyncEngine.isAcceptingShare || URL(string: shareLinkText) == nil)
            } header: {
                Text("Terima undangan surveyor")
            } footer: {
                Text("Di iPhone, ketuk \"Bagikan ke Mac\" pada layar utama JalanKita, lalu kirim tautannya ke Mac ini dengan cara apa pun (pesan, email, catatan) dan tempel di sini. Sekali diterima, setiap sesi baru dari surveyor itu otomatis tersinkron — tidak perlu undangan ulang.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sinkronisasi iCloud")
    }

    private func acceptPastedLink() async {
        guard let url = URL(string: shareLinkText) else { return }
        await model.cloudKitSyncEngine.acceptShare(url: url)
        if model.cloudKitSyncEngine.lastError == nil {
            shareLinkText = ""
        }
    }

    /// Derived from synced `Session` records rather than a `CKShare`
    /// participant lookup — this app declares no contacts/discoverability
    /// entitlement, and every surveyor whose sessions actually arrived is,
    /// by definition, connected, which is the information that matters
    /// here.
    private var connectedSurveyors: [ConnectedSurveyor] {
        let grouped = Dictionary(grouping: model.sessions.filter { $0.recordedDate != nil }, by: \.surveyor.id)
        return grouped.values.compactMap { sessions in
            guard let name = sessions.first?.surveyor.name else { return nil }
            return ConnectedSurveyor(
                id: sessions[0].surveyor.id,
                name: name,
                sessionCount: sessions.count,
                mostRecentRecordedDate: sessions.compactMap(\.recordedDate).max()
            )
        }
        .sorted { $0.name < $1.name }
    }
}

private struct ConnectedSurveyor: Identifiable {
    let id: String
    let name: String
    let sessionCount: Int
    let mostRecentRecordedDate: Date?
}
