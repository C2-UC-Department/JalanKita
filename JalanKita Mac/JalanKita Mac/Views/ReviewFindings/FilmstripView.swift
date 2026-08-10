//
//  FilmstripView.swift
//  JalanKita Mac
//
//  The scrub bar is a real `Slider` now — the previous version hand-drew
//  a track, a fill, and a thumb circle with GeometryReader math, which
//  looked like a scrubber but didn't respond to a drag at all (a classic
//  "looks interactive, isn't" bug). A plain Slider is draggable for free
//  and reports its value back for whatever wires up real playback later.
//

import SwiftUI
import JalanKitaKit

struct FilmstripView: View {
    let frame: ReviewFrame

    @State private var scrubPosition: Double = 0.38

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                            .overlay(thumbnailGlyph(for: i))
                            .frame(width: 84, height: 52)
                    }
                }
            }

            HStack {
                Text(frame.timecode)
                    .font(.data(11))
                    .foregroundStyle(.secondary)
                Slider(value: $scrubPosition, in: 0...1)
                Text("02:12:05")
                    .font(.data(11))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.white)
    }

    @ViewBuilder
    private func thumbnailGlyph(for index: Int) -> some View {
        switch index {
        case 1: Rectangle().fill(DefectType.alligator.color.opacity(0.5)).frame(width: 20, height: 14).clipShape(RoundedRectangle(cornerRadius: 2))
        case 2: Circle().fill(DefectType.pothole.color.opacity(0.6)).frame(width: 22, height: 16)
        case 3: Path { p in p.move(to: CGPoint(x: 0, y: 8)); p.addLine(to: CGPoint(x: 24, y: -4)) }
                .stroke(.white.opacity(0.4), lineWidth: 1.5).frame(width: 24, height: 12)
        case 5: RoundedRectangle(cornerRadius: 3).stroke(DefectType.blockedPark.color.opacity(0.7), lineWidth: 1.5).frame(width: 26, height: 16)
        default: EmptyView()
        }
    }
}
