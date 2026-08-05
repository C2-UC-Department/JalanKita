//
//  FrameCanvasView.swift
//  JalanKita Mac
//
//  The background is either the bundled sample photo (ReviewSampleFrame, aka
//  IMG_0885 — a real frame from the illegal-parking dataset, Appendix A.7)
//  when `frame.imageURL` is nil (DummySegmentation's default), or the actual
//  uploaded photo InferenceService just analyzed. The canvas locks its
//  aspect ratio to whichever image is showing rather than assuming a fixed
//  ratio, so the image is never letterboxed and the findings' normalized
//  rects always land on the actual pixels they describe.
//

import SwiftUI

struct FrameCanvasView: View {
    /// Width ÷ height of the bundled ReviewSampleFrame asset (3024 × 4032
    /// px) — the fallback whenever `frame.imageURL` is nil.
    static let sampleFrameAspectRatio: CGFloat = 3024.0 / 4032.0

    let frame: ReviewFrame
    let maskActive: Bool
    let boxActive: Bool
    @Binding var selectedFindingID: String?

    @State private var loadedImage: NSImage?

    private var aspectRatio: CGFloat {
        guard let size = loadedImage?.size, size.height > 0 else { return Self.sampleFrameAspectRatio }
        return size.width / size.height
    }

    private var background: Image {
        if let loadedImage {
            return Image(nsImage: loadedImage)
        }
        return Image("ReviewSampleFrame")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

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
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
        .task(id: frame.imageURL) {
            loadedImage = frame.imageURL.flatMap { NSImage(contentsOf: $0) }
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
            Text("\(labelText) · \(String(format: "%.2f", finding.confidence))")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(finding.defectType.color, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: -20)
        }
        .shadow(color: isSelected ? finding.defectType.color.opacity(0.6) : .clear, radius: 8)
    }

    private var labelText: String {
        finding.defectType.label.uppercased()
    }
}
