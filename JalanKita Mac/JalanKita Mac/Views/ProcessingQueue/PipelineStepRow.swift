//
//  PipelineStepRow.swift
//  JalanKita Mac
//
//  Uses `GroupBox` for the card instead of a manual
//  `.background(...).overlay(RoundedRectangle().stroke(...))` pair — it's
//  exactly the "titled, bordered content box" GroupBox exists for, and it
//  automatically matches the system's card material in both appearances.
//

import SwiftUI

struct PipelineStepRow: View {
    let step: PipelineStep

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.stats)
                    .font(.data(11.5))
                    .foregroundStyle(.secondary)

                if let sub = step.subProgress {
                    ProgressView(value: sub)
                }

                if let warning = step.warning {
                    Label {
                        Text(warning)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Severity.monitor.literalColor)
                    }
                    .padding(10)
                    .background(Severity.monitor.literalColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 12) {
                statusIcon
                Text("\(step.id) · \(step.title)")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(step.state == .active ? Color.accentColor : .secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active:
            Image(systemName: "circle.circle.fill").foregroundStyle(Color.accentColor)
        case .waiting:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
