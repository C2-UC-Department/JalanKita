//
//  DefectType.swift
//  JalanKita Mac
//
//  The defect-type language is orthogonal to Severity (see §5): it encodes
//  *what* kind of finding this is, not how bad it is, so it must read
//  distinctly from severity colours when both sit on the same frame.
//

import SwiftUI

enum DefectType: String, CaseIterable, Identifiable {
    case pothole      // Lubang
    case alligator    // Retak kulit buaya (fatigue cracking)
    case crack        // Retak garis (linear crack)
    case blockedPark  // Parkir mengganggu — not a road defect, shares the overlay language

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pothole: "Lubang"
        case .alligator: "Retak kulit buaya"
        case .crack: "Retak garis"
        case .blockedPark: "Parkir mengganggu"
        }
    }

    var color: Color {
        switch self {
        case .pothole: Color(red: 0.51, green: 0.38, blue: 0.93)
        case .alligator: Color(red: 0.55, green: 0.78, blue: 0.25)
        case .crack: Color(white: 0.85)
        case .blockedPark: Color(red: 0.20, green: 0.48, blue: 0.96)
        }
    }

    /// Fill pattern so type reads distinctly from Severity even in mono.
    var pattern: MaskPattern {
        switch self {
        case .pothole: .solid
        case .alligator: .crosshatch
        case .crack: .diagonalLines
        case .blockedPark: .outline
        }
    }

    enum MaskPattern {
        case solid, crosshatch, diagonalLines, outline
    }
}

/// A small legend swatch showing the fill pattern used to overlay this
/// defect type as a translucent mask on a video frame.
struct DefectSwatch: View {
    let type: DefectType
    var size: CGFloat = 14

    var body: some View {
        MaskPatternShape(pattern: type.pattern)
            .fill(type.color, style: FillStyle())
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(type.color, lineWidth: type.pattern == .outline ? 1.5 : 0)
            )
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Renders the fill pattern itself, reused between legend swatches and the
/// full-size mask overlays drawn on a reviewed frame.
struct MaskPatternShape: Shape {
    let pattern: DefectType.MaskPattern

    func path(in rect: CGRect) -> Path {
        switch pattern {
        case .solid:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.15)
        case .outline:
            return Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: rect.width * 0.15)
        case .crosshatch:
            var path = Path()
            let step = max(rect.width, rect.height) / 4
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += step
            }
            var y = rect.minY - rect.width
            while y < rect.maxY {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y + rect.width))
                y += step
            }
            return path.strokedPath(StrokeStyle(lineWidth: 1))
        case .diagonalLines:
            var path = Path()
            let step = max(rect.width, rect.height) / 5
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += step
            }
            return path.strokedPath(StrokeStyle(lineWidth: 1.4))
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        ForEach(DefectType.allCases) { t in
            VStack {
                DefectSwatch(type: t, size: 28)
                Text(t.label).font(.caption)
            }
        }
    }
    .padding()
}
