//
//  ReportsView.swift
//  JalanKita Mac
//
//  "Laporan" — the history of sessions that have finished processing.
//  Mirrors SessionInboxView's Table + SessionDetailPanel layout (same
//  reasons: sortable/resizable columns, native selection, keyboard nav),
//  minus everything only relevant to sessions still awaiting work — no
//  batch-select column, no "Proses"/"Unggah…" toolbar.
//

import SwiftUI
import JalanKitaKit

struct ReportsView: View {
    @Bindable var model: AppModel

    @State private var selection: Session.ID?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\Session.roadName)]
    @State private var pendingDeletionID: Session.ID?

    private var filteredSessions: [Session] {
        let base = searchText.isEmpty
            ? model.doneSessions
            : model.doneSessions.filter {
                $0.roadName.localizedCaseInsensitiveContains(searchText) ||
                $0.surveyor.name.localizedCaseInsensitiveContains(searchText)
            }
        return base.sorted(using: sortOrder)
    }

    private var selectedSession: Session? {
        model.sessions.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            table
                .frame(minWidth: 560)

            if let selectedSession {
                SessionDetailPanel(session: selectedSession, model: model)
                    .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Cari jalan atau surveyor")
        .navigationTitle("Laporan")
        .navigationSubtitle("\(model.doneSessionsCount) sesi selesai")
        .alert("Hapus sesi ini?", isPresented: .constant(pendingDeletionID != nil), presenting: pendingDeletionID) { id in
            Button("Hapus", role: .destructive) {
                model.deleteSession(id)
                pendingDeletionID = nil
            }
            Button("Batal", role: .cancel) { pendingDeletionID = nil }
        } message: { _ in
            Text("Video dan hasil analisis sesi ini akan dihapus permanen dari Mac ini.")
        }
        .onAppear {
            if selection == nil { selection = filteredSessions.first?.id }
        }
    }

    private func formattedGB(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
    }

    private var doneDistanceKm: Double {
        model.doneSessions.reduce(0) { $0 + $1.distanceKm }
    }

    private var doneSizeGB: Double {
        model.doneSessions.reduce(0) { $0 + $1.sizeGB }
    }

    private var statRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatTile(title: "SESI SELESAI", value: "\(model.doneSessionsCount)", unit: "sesi")
                Divider()
                StatTile(title: "JARAK TERSURVEI", value: formattedGB(doneDistanceKm), unit: "km")
                Divider()
                StatTile(title: "PARKIR MENGGANGGU", value: "\(model.disturbanceCount)", unit: nil,
                         detail: "kendaraan terdeteksi", accent: Severity.urgent.literalColor)
                Divider()
                StatTile(title: "UKURAN DATA", value: formattedGB(doneSizeGB), unit: "GB")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
        }
        .background(.background)
    }

    private var table: some View {
        Table(filteredSessions, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Jalan / Sesi", value: \.roadName) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.roadName).fontWeight(.semibold)
                    Text(subtitle(for: session))
                        .font(.caption)
                        .foregroundStyle(session.gpsGapNote != nil ? .red : .secondary)
                }
            }
            .width(min: 200, ideal: 240)

            TableColumn("Surveyor", value: \.surveyor.name)
                .width(min: 100, ideal: 130)

            TableColumn("Durasi", value: \.duration) { session in
                Text(session.duration).font(.data(12))
            }
            .width(80)

            TableColumn("Jarak", value: \.distanceKm) { session in
                measurement(session.distanceKm, unit: "km")
            }
            .width(80)

            TableColumn("Jejak GPS") { session in
                gpsTrack(for: session)
            }
            .width(100)

            TableColumn("Ukuran", value: \.sizeGB) { session in
                measurement(session.sizeGB, unit: "GB")
            }
            .width(80)

            TableColumn("Status") { session in
                SessionStatusBadge(status: session.status)
            }
            .width(min: 110, ideal: 140)
        }
        .safeAreaInset(edge: .top, spacing: 0) { statRow }
        .contextMenu(forSelectionType: Session.ID.self) { ids in
            if let id = ids.first {
                Button("Hapus sesi…", role: .destructive) {
                    pendingDeletionID = id
                }
            }
        }
        .onDeleteCommand {
            if let selection { pendingDeletionID = selection }
        }
    }

    private func measurement(_ value: Double, unit: String) -> some View {
        HStack(spacing: 2) {
            Text(value, format: .number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.data(12))
    }

    private func subtitle(for session: Session) -> String {
        var parts = [session.date, "\(session.clipCount) klip"]
        if let segmentCount = session.segmentCount { parts.append("\(segmentCount) segmen") }
        if let gap = session.gpsGapNote { parts.append(gap) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func gpsTrack(for session: Session) -> some View {
        if let acc = session.gpsAccuracyM, let hz = session.gpsHz {
            Text("±\(acc) m · \(Int(hz)) Hz").font(.data(12)).foregroundStyle(.green)
        } else if session.gpsGapNote != nil {
            Text("bolong").font(.data(12)).foregroundStyle(.red)
        } else {
            Text("—").font(.data(12)).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
