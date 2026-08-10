//
//  Theme.swift
//  JalanKitaKit
//
//  Just the reusable pieces that don't already exist in SwiftUI: a
//  monospaced-digit font helper (tabular data stays aligned) and two small
//  domain views (a stat tile, a section caption). Chrome colors — panel
//  backgrounds, separators, accent — come straight from the system
//  (`Color.accentColor`, platform separator colors) at each call site
//  instead of a custom palette that duplicated them.
//
//  Shared verbatim between JalanKita Mac and JalanKita iOS.
//

import SwiftUI

extension Font {
    public static func data(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

public struct StatTile: View {
    let title: String
    let value: String
    let unit: String?
    var detail: String?
    var accent: Color = .primary

    public init(title: String, value: String, unit: String? = nil, detail: String? = nil, accent: Color = .primary) {
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
        self.accent = accent
    }

    public var body: some View {
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

public struct SectionLabel: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
