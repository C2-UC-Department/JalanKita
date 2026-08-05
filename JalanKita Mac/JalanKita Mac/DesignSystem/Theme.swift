//
//  Theme.swift
//  JalanKita Mac
//
//  Just the reusable pieces that don't already exist in SwiftUI/AppKit:
//  a monospaced-digit font helper (tabular data stays aligned) and two
//  small domain views (a stat tile, a section caption). Chrome colors —
//  panel backgrounds, separators, accent — now come straight from the
//  system (`Color.accentColor`, `NSColor.controlBackgroundColor`,
//  `NSColor.separatorColor`) at each call site instead of a custom
//  `Theme.accent` / `Theme.panel` / `Theme.hairline` palette that
//  duplicated them and didn't track Increase Contrast or a custom accent
//  color choice.
//

import SwiftUI

extension Font {
    static func data(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String?
    var detail: String?
    var accent: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.data(26, weight: .bold))
                    .foregroundStyle(accent)
                if let unit {
                    Text(unit)
                        .font(.data(13))
                        .foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
