//
//  QueueRow.swift
//  JalanKita Mac
//
//  Plain row content for a List(selection:) — no custom selection
//  background here. The previous version manually painted a selection
//  highlight and border on top of a ScrollView row (`isSelected` picking
//  colors by hand), duplicating what List already renders for free and
//  risking it falling out of sync with the real selection.
//
//  "Running" state comes from `session.status`, not a hardcoded row index
//  — the earlier version always highlighted the first row as active
//  regardless of which session was actually processing.
//

import SwiftUI
import JalanKitaKit

struct QueueRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRunning ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(session.roadName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text("\(session.date) · \(formattedDistance) km · \(session.surveyor.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch session.status {
            case .segmenting(let progress):
                ProgressView(value: progress)
                Text("Segmentasi · \(Int(progress * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            default:
                Text("Menunggu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var isRunning: Bool {
        if case .segmenting = session.status { return true }
        return false
    }

    private var formattedDistance: String {
        session.distanceKm.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
    }
}
