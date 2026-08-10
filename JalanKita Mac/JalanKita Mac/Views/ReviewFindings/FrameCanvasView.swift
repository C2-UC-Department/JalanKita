//
//  FrameCanvasView.swift
//  JalanKita Mac
//
//  The background is the real surveyed frame, loaded from disk at
//  `ReviewFrame.imageURL` — previously a single bundled sample photo
//  (ReviewSampleFrame, aka IMG_0885) with its 3:4 ratio hardcoded as a static
//  constant. Both had to go once the queue became 236 real frames: they are
//  1080x1920 portrait clips, and a wrong ratio doesn't letterbox harmlessly, it
//  slides every normalized box off the pixels it describes.
//
//  So the ratio now comes from the frame's own recorded `width`/`height`
//  (frames_provenance.csv), and `.aspectRatio(contentMode: .fit)` on a container
//  whose ratio matches the image means `.fill` crops nothing. Getting this wrong
//  is visible instantly — boxes drift toward one edge — which is why the
//  verification step for this change is "check a box lands on the damage".
//
//  Decoded images are cached by URL. Stepping through a queue revisits frames
//  constantly (prev/next, filmstrip clicks) and re-decoding a 1080x1920 JPEG on
//  every SwiftUI body evaluation is the kind of thing that reads as "the app got
//  slow" long before anyone suspects the canvas.
//

import SwiftUI

/// Process-wide decoded-frame cache, bounded by count.
///
/// `NSCache` rather than a dictionary: it evicts under memory pressure on its
/// own, which matters because the full survey is 958 frames and a reviewer can
/// legitimately visit all of them in one sitting.
private enum FrameImageCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 24
        return cache
    }()

    static func image(at url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct FrameCanvasView: View {
    let frame: ReviewFrame
    let maskActive: Bool
    let boxActive: Bool
    @Binding var selectedFindingID: String?

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    // The file is gone or unreadable. Say so on the canvas rather
                    // than rendering boxes over blank space, which would look like
                    // a detection bug instead of a missing file.
                    Rectangle()
                        .fill(.white.opacity(0.04))
                        .overlay(
                            Label("Gambar tidak dapat dimuat", systemImage: "exclamationmark.triangle")
                                .font(.data(12))
                                .foregroundStyle(.secondary)
                        )
                }

                ForEach(frame.findings) { finding in
                    FindingOverlay(
                        finding: finding,
                        isSelected: finding.id == selectedFindingID,
                        maskActive: maskActive,
                        boxActive: boxActive
                    )
                    .frame(width: finding.frameRect.width * geo.size.width,
                           height: finding.frameRect.height * geo.size.height)
                    .position(x: (finding.frameRect.minX + finding.frameRect.width / 2) * geo.size.width,
                              y: (finding.frameRect.minY + finding.frameRect.height / 2) * geo.size.height)
                    .onTapGesture { selectedFindingID = finding.id }
                }

                Text("frame \(frame.frameNumber) · \(frame.timecode)")
                    .font(.data(11.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(14)
            }
        }
        .aspectRatio(frame.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
        .task(id: frame.id) {
            image = FrameImageCache.image(at: frame.imageURL)
        }
    }
}

private struct FindingOverlay: View {
    let finding: Finding
    let isSelected: Bool
    let maskActive: Bool
    let boxActive: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if maskActive {
                MaskPatternShape(pattern: finding.defectType.pattern)
                    .fill(finding.defectType.color.opacity(finding.defectType == .blockedPark ? 0 : 0.55))
            }
            if boxActive {
                RoundedRectangle(cornerRadius: finding.defectType == .pothole ? 40 : 4)
                    .stroke(finding.defectType.color, lineWidth: isSelected ? 3 : 2)
            }
            Text(labelText)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(finding.defectType.color, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: -20)
        }
        .shadow(color: isSelected ? finding.defectType.color.opacity(0.6) : .clear, radius: 8)
    }

    /// The confidence suffix is dropped entirely when there is no confidence,
    /// rather than shown as "0,00" — the label has to read as "we don't know",
    /// not "the model was certain it was nothing".
    private var labelText: String {
        let name = finding.defectType.label.uppercased()
        guard let confidence = finding.confidence else { return name }
        let formatted = confidence.formatted(
            .number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(2)))
        return "\(name) · \(formatted)"
    }
}
