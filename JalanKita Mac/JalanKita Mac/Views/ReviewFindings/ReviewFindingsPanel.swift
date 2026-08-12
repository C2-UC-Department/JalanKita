//
//  ReviewFindingsPanel.swift
//  JalanKita Mac
//
//  Terima/Tolak now do something: they mark the selected finding reviewed
//  and hand off to `onDecision` to advance selection, and both carry real
//  `.keyboardShortcut`s matching the J/K keycaps shown on the buttons
//  (previously just labels next to empty button closures). Finding rows
//  are real `Button`s instead of a decorative HStack with `.onTapGesture`,
//  so they pick up hover/pressed states and accessibility for free.
//

import SwiftUI
import JalanKitaKit

struct ReviewFindingsPanel: View {
    let frame: ReviewFrame
    @Binding var selectedFindingID: String?
    @Binding var reviewedIDs: Set<String>
    var onDecision: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 10) {
                        SeverityBadge(severity: frame.severity, size: .large)
                        HStack(spacing: 2) {
                            Text("\(frame.score)").font(.data(28, weight: .bold))
                            Text("/100").font(.data(15)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if frame.isProvisional {
                            Text("PROVISIONAL")
                                .font(.caption2.weight(.bold))
                                .tracking(0.4)
                                .foregroundStyle(.yellow)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.yellow.opacity(0.15), in: Capsule())
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(placeLine)
                            .font(.system(size: 15, weight: .semibold))
                        Text(provenanceLine)
                            .font(.data(11.5))
                            .foregroundStyle(.secondary)
                        // Not a soft caveat: without a GPS track this frame cannot be
                        // placed on the map at all, and a reviewer who assumes otherwise
                        // will file a work order against the wrong stretch of road.
                        if frame.coordinate == nil {
                            Label("Tanpa jejak GPS — frame ini tidak dapat dipetakan",
                                  systemImage: "location.slash")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "TEMUAN DI FRAME INI")
                        VStack(spacing: 8) {
                            ForEach(frame.findings) { finding in
                                Button {
                                    selectedFindingID = finding.id
                                } label: {
                                    FindingCard(
                                        finding: finding,
                                        isSelected: finding.id == selectedFindingID,
                                        isReviewed: reviewedIDs.contains(finding.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "PERHITUNGAN KEPARAHAN")
                        VStack(spacing: 6) {
                            calcRow("Skor awal", "\(frame.startScore)", isBold: false)
                            ForEach(frame.deductions) { d in
                                calcRow(d.label, "\(d.points)", isBold: false, isNegative: true)
                            }
                            Divider()
                            calcRow("Skor kondisi", "\(frame.score)", isBold: true)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        decide()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Terima")
                            Spacer()
                            keycap("J")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut("j", modifiers: [])
                    .disabled(selectedFindingID == nil)

                    Button {
                        decide()
                    } label: {
                        HStack {
                            Image(systemName: "xmark")
                            Text("Tolak")
                            Spacer()
                            keycap("K")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut("k", modifiers: [])
                    .disabled(selectedFindingID == nil)
                }

                Text("Hanya temuan terverifikasi masuk laporan dinas. Penolakan ikut dikumpulkan sebagai bahan kalibrasi ambang batas.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.10))
        .foregroundStyle(.white)
    }

    /// Segment/km binning needs a GPS log to exist; until then the honest unit of
    /// location is the clip the frame came from.
    private var placeLine: String {
        let parts = [frame.segmentLabel, frame.kmMarker].compactMap { $0 }
        return parts.isEmpty ? frame.sourceClip : parts.joined(separator: " · ")
    }

    private var provenanceLine: String {
        var parts = ["frame \(frame.frameNumber)", frame.timecode]
        if let coordinate = frame.coordinate {
            parts.insert(coordinate, at: 0)
            if let accuracy = frame.gpsAccuracyM { parts.insert("±\(accuracy) m", at: 1) }
        }
        if let capturedAt = frame.capturedAt { parts.append(capturedAt) }
        return parts.joined(separator: " · ")
    }

    private func decide() {
        guard let id = selectedFindingID else { return }
        reviewedIDs.insert(id)
        onDecision()
    }

    private func calcRow(_ label: String, _ value: String, isBold: Bool, isNegative: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: isBold ? 13.5 : 12.5, weight: isBold ? .semibold : .regular))
                .foregroundStyle(isBold ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(.data(isBold ? 15 : 12.5, weight: isBold ? .bold : .regular))
                .foregroundStyle(isBold ? Color.primary : (isNegative ? Color.red : Color.secondary))
        }
    }

    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct FindingCard: View {
    let finding: Finding
    let isSelected: Bool
    var isReviewed: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            DefectSwatch(type: finding.defectType, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.defectType.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isReviewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            // No confidence column exists in the YOLO label files, so a finding read
            // from those has none. Show nothing rather than a stand-in number.
            if let confidence = finding.confidence {
                Text(confidence.formatted(
                    .number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(2))))
                    .font(.data(13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? finding.defectType.color : .clear, lineWidth: 1.5)
        )
        .opacity(isReviewed ? 0.6 : 1)
    }

    private var detailText: String {
        if let vehicleNote = finding.vehicleNote {
            return vehicleNote
        }
        var parts: [String] = []
        if let area = finding.areaSqm {
            parts.append(String(format: "%.1f m²", area).replacingOccurrences(of: ".", with: ","))
        }
        if let pct = finding.percentOfSurface {
            parts.append(String(format: "%.1f%% permukaan", pct).replacingOccurrences(of: ".", with: ","))
        }
        if let mapped = finding.mappedFromNote {
            parts.append(mapped)
        }
        return parts.joined(separator: " · ")
    }
}
