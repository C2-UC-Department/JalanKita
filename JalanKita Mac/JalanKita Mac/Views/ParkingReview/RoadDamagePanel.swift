//
//  RoadDamagePanel.swift
//  JalanKita Mac
//
//  The right-hand pane for stage 3, mirroring `ParkingMetricsPanel`'s role for
//  stage 2: everything known about the selected frame, and nothing computed here.
//
//  🚫 No severity arithmetic in this file, or anywhere else in Swift. `score`,
//  `startScore` and every row of `deductions` arrive from Python's
//  `effective_deductions()` / `grade_segment()` and are displayed verbatim. The
//  deleted Swift deduction table disagreed with `severity.yaml` on every single
//  term, which is what ADR-016 settled — the only arithmetic below is summing the
//  rows Python already sent in order to *show the reviewer* that they do not quite
//  close, and why.
//
//  That residual is deliberate and is rendered as its own row rather than hidden:
//  Python rounds the total once and then clamps the result to [2, 98]
//  (`severity.py:163`). A frame with no defects at all therefore scores 98, not
//  100. Printing `100 − deductions = score` without showing the clamp would be an
//  equation that visibly does not balance, and the first person to notice would
//  reasonably assume the numbers were wrong rather than rounded.
//
//  Numbers are `id_ID`: decimal comma throughout.
//

import SwiftUI
import JalanKitaKit

struct RoadDamagePanel: View {
    let frame: ReviewFrame

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                scoreSection
                if !frame.findings.isEmpty {
                    Divider()
                    findingsSection
                }
                if let warnings = frame.warnings {
                    Divider()
                    caveat(warnings)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 380, idealWidth: 460, maxWidth: 540)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SeverityBadge(severity: frame.severity, size: .large)
                Spacer(minLength: 0)
                Text("\(frame.score)")
                    .font(.data(30, weight: .semibold))
                    .foregroundStyle(frame.severity.literalColor)
            }
            Text("\(frame.sourceClip) · \(frame.timecode) · frame \(frame.frameNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if frame.isProvisional {
                Label("Skor sementara", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Score

    /// `startScore` − Σ`deductions` − clamp/rounding residual = `score`.
    private var deductionTotal: Double {
        frame.deductions.reduce(0) { $0 + $1.points }
    }

    /// Whatever Python's rounding and its `[2, 98]` clamp took off the top. Signed
    /// so the column always reads as a subtraction from the start score.
    private var residual: Double {
        Double(frame.score) - (Double(frame.startScore) + deductionTotal)
    }

    private var scoreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SKOR KONDISI")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            row(label: "Skor awal", value: Self.number(Double(frame.startScore)), emphasis: false)
            ForEach(frame.deductions) { deduction in
                row(label: deduction.label, value: Self.number(deduction.points), emphasis: false)
            }
            if abs(residual) > 0.05 {
                row(label: "Pembulatan & batas 2–98", value: Self.number(residual), emphasis: false)
                    .foregroundStyle(.secondary)
            }
            Divider()
            row(label: "Skor kondisi", value: Self.number(Double(frame.score)), emphasis: true)
        }
    }

    private func row(label: String, value: String, emphasis: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(emphasis ? .callout.weight(.semibold) : .callout)
            Spacer(minLength: 12)
            Text(value)
                .font(.data(13, weight: emphasis ? .semibold : .regular))
        }
    }

    // MARK: - Findings

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEMUAN (\(frame.findings.count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            ForEach(frame.findings) { finding in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        DefectSwatch(type: finding.defectType)
                        Text(finding.defectType.label)
                            .font(.callout)
                        Spacer(minLength: 0)
                        if let confidence = finding.confidence {
                            Text(Self.percent(confidence * 100))
                                .font(.data(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(extentLine(for: finding))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let note = finding.mappedFromNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Box footprint and, when the U-Net measured one, segmentation extent beside
    /// it. Both are percentages of the whole frame, which is what makes them
    /// comparable — the box over-states a thin diagonal crack by construction, and
    /// showing the pair is the point.
    private func extentLine(for finding: Finding) -> String {
        var parts: [String] = []
        if let percent = finding.percentOfSurface {
            parts.append("\(Self.percent(percent)) permukaan (kotak)")
        }
        if let extent = finding.extentPercent {
            parts.append("\(Self.percent(extent)) (segmentasi)")
        }
        return parts.isEmpty ? "luas tidak tersedia" : parts.joined(separator: " · ")
    }

    private func caveat(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - id_ID formatting

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static func number(_ value: Double) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "—"
    }

    private static func percent(_ value: Double) -> String {
        (decimal.string(from: NSNumber(value: value)) ?? "—") + "%"
    }
}
