//
//  ReportsView.swift
//  JalanKita Mac
//
//  Where a session goes once it is finished. Sesi masuk holds everything that
//  still needs the operator, Antrean holds what is actively running, and this
//  screen holds `.done` — see `AppModel.inboxSessions` / `reportSessions` for
//  the single status-based rule all three share.
//
//  Deliberately built on the same `Table` + `.safeAreaInset(edge: .top)`
//  arrangement as SessionInboxView rather than a fresh layout: that file's own
//  comments document why a stat header must be an inset rather than a VStack
//  sibling (a fixed-height header stacked in front of a Table gets handed the
//  pane's full height and its Dividers stretch down the screen). Same container
//  shape, same fix.
//
//  Row navigation reuses the `.navigationDestination(for: Session.self)` that
//  ContentView already registers at the top of the NavigationStack, so opening
//  a report lands on the same ParkingVideoReviewView the inbox's detail panel
//  opens. No second navigation mechanism.
//

import SwiftUI
import JalanKitaKit

struct ReportsView: View {
    @Bindable var model: AppModel

    @State private var selection: Session.ID?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\Session.roadName)]

    private var filteredSessions: [Session] {
        let base = searchText.isEmpty
            ? model.reportSessions
            : model.reportSessions.filter {
                $0.roadName.localizedCaseInsensitiveContains(searchText) ||
                $0.surveyor.name.localizedCaseInsensitiveContains(searchText)
            }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.reportSessions.isEmpty {
                ContentUnavailableView(
                    "Belum ada laporan", systemImage: "doc.text",
                    description: Text("Sesi pindah ke sini otomatis setelah selesai diproses. "
                                      + "Yang masih menunggu ada di Sesi masuk, yang sedang berjalan ada di Antrean.")
                )
            } else {
                table
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Cari jalan atau surveyor")
        .navigationTitle("Laporan")
        .navigationSubtitle("\(model.reportSessions.count) sesi selesai · \(model.disturbanceCount) pelanggaran")
    }

    private var table: some View {
        Table(filteredSessions, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Jalan / Sesi", value: \.roadName) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.roadName).fontWeight(.semibold)
                    Text(subtitle(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 200, ideal: 260)

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

            // Not sortable on purpose: the count is derived from
            // `parkingAnalyses`, not a stored field on Session, so there is no
            // key path for Table to sort by without duplicating it onto the
            // model just to satisfy the API.
            TableColumn("Kendaraan") { session in
                Text("\(analyses(for: session).count)")
                    .font(.data(12))
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Pelanggaran") { session in
                let count = disturbances(for: session)
                Text("\(count)")
                    .font(.data(12, weight: count > 0 ? .bold : .regular))
                    .foregroundStyle(count > 0 ? .red : .secondary)
            }
            .width(100)

            TableColumn("") { session in
                NavigationLink(value: session) {
                    Text("Buka")
                }
                .buttonStyle(.link)
            }
            .width(60)
        }
        .safeAreaInset(edge: .top, spacing: 0) { statRow }
    }

    private var statRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatTile(title: "SESI SELESAI", value: "\(model.reportSessions.count)", unit: "sesi",
                         detail: "\(model.surveyorCount) surveyor")
                Divider()
                StatTile(title: "PELANGGARAN", value: "\(model.disturbanceCount)", unit: nil,
                         detail: "parkir dalam zona rambu",
                         accent: model.disturbanceCount > 0 ? .red : .primary)
                Divider()
                StatTile(title: "KENDARAAN DIANALISIS", value: "\(model.totalVehiclesAnalyzed)", unit: nil)
                Divider()
                StatTile(title: "JARAK TERSURVEI", value: formattedNumber(reportedDistanceKm), unit: "km")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
        }
        .background(.bar)
    }

    /// Distance across finished sessions only — the whole-corpus
    /// `model.totalDistanceKm` would count sessions still sitting in the inbox,
    /// which have not been surveyed in any reportable sense yet.
    private var reportedDistanceKm: Double {
        model.reportSessions.reduce(0) { $0 + $1.distanceKm }
    }

    private func analyses(for session: Session) -> [ParkingAnalysis] {
        model.parkingAnalyses[session.id] ?? []
    }

    private func disturbances(for session: Session) -> Int {
        analyses(for: session).filter { $0.carCandidate?.disturbance == true }.count
    }

    private func subtitle(for session: Session) -> String {
        var parts = [session.date, "\(session.clipCount) klip"]
        if let segmentCount = session.segmentCount { parts.append("\(segmentCount) segmen") }
        return parts.joined(separator: " · ")
    }

    private func measurement(_ value: Double, unit: String) -> some View {
        HStack(spacing: 2) {
            Text(value, format: .number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.data(12))
    }

    private func formattedNumber(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
    }
}

#Preview {
    ContentView()
}
