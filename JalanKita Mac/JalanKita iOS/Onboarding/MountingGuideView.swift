//
//  MountingGuideView.swift
//  JalanKita iOS
//
//  §6.1.2 — good vs too-low vs too-tilted mount examples. This is load-
//  bearing, not cosmetic: the desk pipeline's accuracy is measured
//  against a specific road-width-in-frame target, and the mount angle is
//  what sets that. Illustrated schematically (SF Symbols + shapes) rather
//  than with photography, which this app doesn't ship any of.
//

import SwiftUI

struct MountingGuideView: View {
    let onContinue: () -> Void

    private let examples: [MountExample] = [
        MountExample(
            title: "Baik",
            detail: "Kamera sejajar cakrawala, jalan mengisi sebagian besar bingkai.",
            horizonOffset: 0, isGood: true
        ),
        MountExample(
            title: "Terlalu rendah",
            detail: "Kap mobil menutupi terlalu banyak bingkai — jalan yang terlihat terlalu sedikit.",
            horizonOffset: 40, isGood: false
        ),
        MountExample(
            title: "Terlalu miring",
            detail: "Sudut condong ke langit atau ke bawah mengubah skala yang dilihat model.",
            horizonOffset: -60, isGood: false
        ),
    ]

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Panduan pemasangan")
                    .font(.largeTitle.weight(.bold))
                Text("Pemasangan yang konsisten menghasilkan hasil yang konsisten.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            TabView {
                ForEach(examples) { example in
                    MountExampleCard(example: example)
                        .padding(.horizontal)
                }
            }
            .tabViewStyle(.page)

            Button("Lanjutkan") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

private struct MountExample: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let horizonOffset: CGFloat
    let isGood: Bool
}

private struct MountExampleCard: View {
    let example: MountExample

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                GeometryReader { proxy in
                    let midY = proxy.size.height / 2 + example.horizonOffset
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: midY))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: midY))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

                    Path { path in
                        path.move(to: CGPoint(x: proxy.size.width * 0.3, y: proxy.size.height))
                        path.addLine(to: CGPoint(x: proxy.size.width * 0.45, y: midY))
                        path.addLine(to: CGPoint(x: proxy.size.width * 0.55, y: midY))
                        path.addLine(to: CGPoint(x: proxy.size.width * 0.7, y: proxy.size.height))
                    }
                    .stroke(Color.primary.opacity(0.4), lineWidth: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack {
                    HStack {
                        Image(systemName: example.isGood ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(example.isGood ? .green : .red)
                            .padding(10)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(height: 220)

            VStack(spacing: 6) {
                Text(example.title).font(.title3.weight(.bold))
                Text(example.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
