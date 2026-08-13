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
    var model: AppModel

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
                // Only the status line ticks, not the whole List. Wrapping the
                // List itself in a TimelineView would re-render its structure
                // every second, which is how selection and scroll position get
                // disturbed; each row driving its own clock keeps the churn to
                // the one line that actually changes.
                //
                // It has to tick at all because a stall is defined by the
                // ABSENCE of worker output: with no heartbeat there is no model
                // mutation, so nothing would ever prompt a redraw and the
                // warning would never appear.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusLine(progress: progress, now: context.date)
                }
            default:
                Text("Menunggu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLine(progress: Double, now: Date) -> some View {
        if model.isStalled(session.id, now: now) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Mungkin macet · \(Int(progress * 100))%")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        } else if let elapsed = model.elapsed(for: session.id, now: now) {
            Text("Segmentasi · \(Int(progress * 100))% · \(compact(elapsed))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Text("Segmentasi · \(Int(progress * 100))%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Short form for the list — the detail pane carries the readable one.
    private func compact(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        if total >= 3600 { return "\(total / 3600)j \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)d" }
        return "\(total)d"
    }

    private var isRunning: Bool {
        if case .segmenting = session.status { return true }
        return false
    }

    private var formattedDistance: String {
        session.distanceKm.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
    }
}
