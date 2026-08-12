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
//  The strip itself was the same class of bug: `ForEach(0..<6)` of hardcoded
//  glyphs that never corresponded to anything. It now renders the actual review
//  queue, and both it and the slider MOVE the queue — clicking a chip or dragging
//  the scrubber selects that frame.
//
//  Chips carry severity colour and defect swatches rather than photo thumbnails,
//  which is a deliberate trade. The queue is 236 frames (958 with clean ones
//  included) of 1080x1920 JPEGs; decoding even the visible slice of that on every
//  scroll is how a review screen starts feeling slow. Severity + class is also the
//  information a reviewer actually scans a strip for — "where are the bad ones" —
//  and the full-size frame is already on the canvas directly above.
//

import SwiftUI
import JalanKitaKit

struct FilmstripView: View {
    var model: AppModel
    let frame: ReviewFrame

    private var queue: [ReviewFrame] { model.reviewQueue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(queue) { item in
                            chip(for: item)
                                .id(item.id)
                                .onTapGesture { model.selectReviewFrame(id: item.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: frame.id) { _, id in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear { proxy.scrollTo(frame.id, anchor: .center) }
            }

            HStack {
                Text(frame.timecode)
                    .font(.data(11))
                    .foregroundStyle(.secondary)

                // Drives the queue rather than a playhead: there is no video here,
                // only sampled frames, so "scrub" means "jump to frame N of the queue".
                Slider(
                    value: Binding(
                        get: { Double((model.reviewQueuePosition ?? 1) - 1) },
                        set: { newValue in
                            let index = Int(newValue.rounded())
                            guard queue.indices.contains(index) else { return }
                            model.selectReviewFrame(id: queue[index].id)
                        }
                    ),
                    in: 0...Double(max(queue.count - 1, 1)),
                    step: 1
                )
                .disabled(queue.count <= 1)

                Text(queue.last?.timecode ?? "—")
                    .font(.data(11))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.white)
    }

    private func chip(for item: ReviewFrame) -> some View {
        let isCurrent = item.id == frame.id
        return VStack(spacing: 4) {
            HStack(spacing: 3) {
                // Distinct defect classes present, so the strip reads as "what kind
                // of damage is over there", not just "how bad".
                ForEach(distinctTypes(in: item), id: \.self) { type in
                    DefectSwatch(type: type, size: 10)
                }
                if item.findings.isEmpty {
                    Text("bersih")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.frameNumber)
                .font(.data(10))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .frame(width: 84, height: 52)
        .background(item.severity.literalColor.opacity(isCurrent ? 0.32 : 0.14),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? item.severity.literalColor : .clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func distinctTypes(in item: ReviewFrame) -> [DefectType] {
        var seen: Set<DefectType> = []
        return item.findings.compactMap { seen.insert($0.defectType).inserted ? $0.defectType : nil }
    }
}
