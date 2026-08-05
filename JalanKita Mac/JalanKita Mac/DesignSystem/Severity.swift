//
//  Severity.swift
//  JalanKita Mac
//
//  The severity language is the app's primary information carrier — see
//  MOBILE_APP_METAPROMPT.md §5. Every grade pairs a colour with a distinct
//  shape/icon so it survives greyscale printing and colourblindness, and
//  every colour is tuned to stay legible sitting on top of map tiles.
//

import SwiftUI

enum Severity: String, CaseIterable, Identifiable {
    case urgent   // SEGERA · condition score < 40
    case monitor  // PANTAU · 40–69
    case ignore   // ABAIKAN · ≥ 70

    var id: String { rawValue }

    var label: String {
        switch self {
        case .urgent: "SEGERA"
        case .monitor: "PANTAU"
        case .ignore: "ABAIKAN"
        }
    }

    var scoreRange: String {
        switch self {
        case .urgent: "< 40"
        case .monitor: "40–69"
        case .ignore: "≥ 70"
        }
    }

    var meaning: String {
        switch self {
        case .urgent: "Risiko kecelakaan atau struktural. Selesaikan secepatnya."
        case .monitor: "Perlu dipantau. Survei ulang siklus berikutnya."
        case .ignore: "Kosmetik. Belum perlu truk perbaikan."
        }
    }

    /// A distinct shape per grade so the encoding survives greyscale and deuteranopia.
    var symbolName: String {
        switch self {
        case .urgent: "diamond.fill"
        case .monitor: "triangle.fill"
        case .ignore: "circle.fill"
        }
    }

    var literalColor: Color {
        switch self {
        case .urgent: Color(red: 0.86, green: 0.15, blue: 0.24)
        case .monitor: Color(red: 0.93, green: 0.60, blue: 0.10)
        case .ignore: Color(red: 0.45, green: 0.49, blue: 0.55)
        }
    }

    /// Route-line dash pattern so grades are distinguishable on a zoomed-out
    /// map even without colour — see §5, "works at three sizes."
    var lineDash: [CGFloat] {
        switch self {
        case .urgent: []
        case .monitor: [7, 5]
        case .ignore: [1, 4]
        }
    }

    init(score: Int) {
        switch score {
        case ..<40: self = .urgent
        case 40..<70: self = .monitor
        default: self = .ignore
        }
    }
}

/// A small grade badge — diamond/triangle/circle + label — reused identically
/// across list rows, map legends, and hero labels per the design brief.
struct SeverityBadge: View {
    let severity: Severity
    var size: Size = .regular

    enum Size {
        case compact, regular, large

        var font: Font {
            switch self {
            case .compact: .caption2.weight(.bold)
            case .regular: .caption.weight(.bold)
            case .large: .title3.weight(.bold)
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .compact: 7
            case .regular: 9
            case .large: 13
            }
        }

        var padding: EdgeInsets {
            switch self {
            case .compact: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 7)
            case .regular: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 10)
            case .large: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14)
            }
        }
    }

    var body: some View {
        Label {
            Text(severity.label)
                .font(size.font)
                .tracking(0.4)
        } icon: {
            Image(systemName: severity.symbolName)
                .font(.system(size: size.iconSize))
        }
        .foregroundStyle(.white)
        .padding(size.padding)
        .background(severity.literalColor, in: Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(Severity.allCases) { s in
            SeverityBadge(severity: s, size: .large)
        }
    }
    .padding()
}
