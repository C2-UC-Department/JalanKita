//
//  SessionRowView.swift
//  JalanKita iOS
//

import SwiftUI
import JalanKitaKit

struct SessionRowView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        NavigationLink(value: session) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.roadName)
                        .font(.headline)
                    Text("\(session.date) · \(session.duration) · \(String(format: "%.1f km", session.distanceKm))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = session.gpsGapNote {
                        Label(note, systemImage: "location.slash")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    SessionStatusBadge(status: session.status)
                    SyncStatusBadge(status: model.syncStates.state(for: session.id).status)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// CloudKit upload status — orthogonal to `SessionStatusBadge`, which
/// reflects processing status (readyToProcess/segmenting/done/...), not
/// whether this device has actually finished handing the session to
/// iCloud yet.
struct SyncStatusBadge: View {
    let status: SessionSyncStatus

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private var text: String {
        switch status {
        case .notSynced: "Belum tersinkron"
        case .uploading: "Mengunggah…"
        case .synced: "Tersinkron"
        case .failed: "Gagal sinkron"
        }
    }

    private var symbol: String {
        switch status {
        case .notSynced: "icloud.slash"
        case .uploading: "icloud.and.arrow.up"
        case .synced: "checkmark.icloud.fill"
        case .failed: "exclamationmark.icloud.fill"
        }
    }

    private var color: Color {
        switch status {
        case .notSynced: .secondary
        case .uploading: .blue
        case .synced: .green
        case .failed: .red
        }
    }
}
