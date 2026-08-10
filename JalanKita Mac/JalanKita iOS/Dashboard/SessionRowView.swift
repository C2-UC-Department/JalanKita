//
//  SessionRowView.swift
//  JalanKita iOS
//

import SwiftUI
import JalanKitaKit

struct SessionRowView: View {
    let session: Session

    var body: some View {
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
            SessionStatusBadge(status: session.status)
        }
        .padding(.vertical, 6)
    }
}
