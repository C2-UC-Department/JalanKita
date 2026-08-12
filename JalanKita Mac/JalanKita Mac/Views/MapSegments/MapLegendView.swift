//
//  MapLegendView.swift
//  JalanKita Mac
//
//  Legible over map tiles in both appearances (§5): a plate behind the
//  legend, and each grade pairs colour with a line-dash pattern and shape
//  so it survives greyscale and colourblindness.
//

import SwiftUI
import JalanKitaKit

struct MapLegendView: View {
    private let worstBySeverity: [Severity: Int] = [.urgent: 16, .monitor: 43, .ignore: 177]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NILAI TERBURUK / 10 M")
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)

            ForEach(Severity.allCases) { severity in
                HStack(spacing: 10) {
                    LegendLineSwatch(severity: severity)
                        .frame(width: 26, height: 10)
                    Image(systemName: severity.symbolName)
                        .font(.system(size: 8))
                        .foregroundStyle(severity.literalColor)
                    Text(severity.label)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 12)
                    Text("\(worstBySeverity[severity] ?? 0)")
                        .font(.data(12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .frame(width: 230)
    }
}

struct LegendLineSwatch: View {
    let severity: Severity

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(severity.literalColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: severity.lineDash))
        }
    }
}
