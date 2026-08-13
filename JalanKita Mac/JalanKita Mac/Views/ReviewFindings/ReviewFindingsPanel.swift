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
//  ── The severity arithmetic now closes on screen ──────────────────────────
//
//  ADR-016 claimed this panel "cannot drift because it never computes." That was
//  true of the DATA and false of the DISPLAY, in two independent ways, both
//  measured against the real 958-frame Stage 0 CSVs:
//
//   1. Rows were rounded individually (`-Int(deduct_effective.rounded())`) while
//      the published `condition` came from Python's sum of the unrounded values.
//      The column failed to add up on 27 of 236 damaged frames. Fixed upstream —
//      `SeverityDeduction.points` is a `Double` now — and rendered here at one
//      decimal, `id_ID`.
//   2. Python clamps `condition` to [2, 98] AFTER subtracting. A frame with no
//      defects at all therefore scored 98 under a "Skor awal 100" with nothing in
//      between: a naked two-point hole, on 722 of the 958 frames.
//
//  So the block gained two rows. `Skor mentah` is the subtotal computed from the
//  DISPLAYED row values rather than the underlying ones — that is the load-bearing
//  detail, because it makes the column literally add up for someone checking it
//  with their finger. `Batas skor kondisi` carries whatever Python's clamp and
//  final rounding did, and appears only when that residual reaches ±1,0.
//
//  Why 1,0 and not something tighter: the residual is Python's own
//  `int(round(100 - total))` and measures between −0,5 and +0,5 on EVERY one of
//  the 236 damaged frames — self-evident to anyone reading `50,5` sitting
//  directly above `50`. A 0,5 threshold would fire on 217 of them and train
//  reviewers to ignore the row. At 1,0 it fires on exactly the inexplicable
//  cases — the 722 clean frames, all at precisely −2,0 — and nowhere else.
//
//  One consequence, stated so it doesn't later read as a bug:
//  `IMG_0044_f000540_t0018000` is the only frame in the set that hits the LOWER
//  clamp (three potholes deducting 98,46, so 1,54 before clamping) and it shows
//  NO clamp row — its residual is +0,4, inside the threshold. That is correct.
//  There the clamp and the final rounding land within half a point of each
//  other, so `Skor mentah 1,6` above `Skor kondisi 2` needs no explanation.
//
//  Verified by replaying all 958 frames through this exact arithmetic: the
//  printed column closes on every one, and the clamp row appears on exactly the
//  722 clean frames.
//
//  Rejected: putting the bounds on the wire (`"score_range": [2, 98]`) so the row
//  could name them. `per_frame.csv` has no such column and both CSVs come from
//  one upstream invocation, so Stage 0 could not have matched without a
//  regeneration run in a sibling repo — leaving the two paths captioning the same
//  road differently, which is the exact asymmetry ADR-016 exists to prevent. The
//  row therefore names no number at all; the explanation is in its `.help()`.
//  Also rejected: hardcoding `2...98` in Swift, which is the drift class the
//  "severity lives only in Python" rule was written to stop.
//
//  Note what is still NOT computed here: the score. `Skor mentah` is arithmetic
//  over numbers Python produced and published precisely so they could be added up
//  (`effective_deductions()`'s docstring: "they must sum to exactly what
//  `grade_segment` subtracted"). Deriving a subtotal from that is not scoring.
//

import SwiftUI

struct ReviewFindingsPanel: View {
    let frame: ReviewFrame
    @Binding var selectedFindingID: String?
    @Binding var decisions: [String: ReviewDecision]
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
                                // The chip is the alarm; the caveat below is the
                                // reason. Until now it was a bare word with the
                                // explanation nowhere on the screen.
                                .help(frame.warnings ?? "")
                        }
                    }

                    // The provenance caveat the worker ships with every result and
                    // the app used to decode and discard. Deliberately grey, not
                    // yellow: the yellow GPS label below is frame-specific and
                    // actionable, while this one is true of every frame forever —
                    // a warning band that never varies is wallpaper within ten
                    // frames, and it would dilute the one warning that does vary.
                    if let warnings = frame.warnings, !warnings.isEmpty {
                        Label(warnings, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                                        decision: decisions[finding.id]
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
                                calcRow(d.label, Self.signedText(d.points),
                                        isBold: false, isNegative: d.points < 0)
                            }
                            // Only when there is something to subtotal — on a clean
                            // frame it would just restate "Skor awal" one line later.
                            if !frame.deductions.isEmpty {
                                Divider()
                                calcRow("Skor mentah", Self.decimalText(displayedSubtotal),
                                        isBold: false)
                            }
                            if let clamp = clampResidual {
                                calcRow("Batas skor kondisi", Self.signedText(clamp),
                                        isBold: false, isNegative: clamp < 0)
                                    .help("Python membatasi skor kondisi ke rentang tetap dan "
                                          + "membulatkannya sekali di akhir; baris ini adalah "
                                          + "selisihnya. Nilainya tidak dihitung ulang di sini.")
                            }
                            Divider()
                            calcRow("Skor kondisi", "\(frame.score)", isBold: true)
                        }
                        // Without this line, the two changes on this screen combine
                        // into a promise the code correctly refuses to keep: a
                        // reviewer who rejects a pothole, having just been shown an
                        // arithmetic that visibly adds up, will expect the total to
                        // move. It must not — severity comes from Python and is
                        // never recomputed in Swift (ADR-016).
                        Text("Skor berasal dari detektor. Menolak temuan menandainya sebagai "
                             + "positif palsu untuk kalibrasi, dan tidak mengubah skor ini.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        decide(.accepted)
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
                        decide(.rejected)
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

                // Was: "Penolakan ikut dikumpulkan sebagai bahan kalibrasi ambang
                // batas." Nothing collected them — both buttons ran the same code
                // — and nothing collects them across launches even now: the app
                // stores no state at all (CLAUDE.md fact 7), so the decisions live
                // for this session only. Adding persistence is an architecture
                // change with its own ADR, not a footnote to a UI fix; until it
                // lands, the copy says what actually happens.
                Text("Hanya temuan terverifikasi masuk laporan dinas. Keputusan tercatat "
                     + "untuk sesi ini saja — belum ada ekspor penolakan.")
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

    private func decide(_ decision: ReviewDecision) {
        guard let id = selectedFindingID else { return }
        decisions[id] = decision
        onDecision()
    }

    // MARK: - The severity column's arithmetic

    /// Deduction rows summed AS DISPLAYED, so the column adds up for someone
    /// checking it by eye. Summing the underlying values instead would reintroduce
    /// the original bug in a subtler form: a subtotal that is right but does not
    /// match the rows printed above it.
    private var displayedSubtotal: Double {
        frame.deductions.reduce(Double(frame.startScore)) { $0 + Self.roundedToTenth($1.points) }
    }

    /// Whatever Python's clamp and final rounding did to the subtotal, or nil when
    /// that is small enough to be self-evident. See the file header for why the
    /// threshold is 1,0 and not tighter.
    private var clampResidual: Double? {
        let residual = Double(frame.score) - displayedSubtotal
        return abs(residual) >= 1.0 ? residual : nil
    }

    /// One decimal, `id_ID`. Rounded explicitly rather than left to the format
    /// style so `displayedSubtotal` and the rows it sums round identically —
    /// `FloatingPointFormatStyle` defaults to to-nearest-EVEN, which disagrees
    /// with `.rounded()` on exact halves and would put the column back out by 0,1.
    private static func roundedToTenth(_ value: Double) -> Double {
        (value * 10).rounded(.toNearestOrAwayFromZero) / 10
    }

    private static func decimalText(_ value: Double) -> String {
        roundedToTenth(value).formatted(
            .number.locale(Locale(identifier: "id_ID"))
                .precision(.fractionLength(1))
                .rounded(rule: .toNearestOrAwayFromZero))
    }

    /// Same, but always carrying its sign — these rows are moves, not quantities,
    /// and a deduction that reads "12,0" invites the reader to add it.
    private static func signedText(_ value: Double) -> String {
        roundedToTenth(value).formatted(
            .number.locale(Locale(identifier: "id_ID"))
                .precision(.fractionLength(1))
                .rounded(rule: .toNearestOrAwayFromZero)
                .sign(strategy: .always(includingZero: false)))
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

    /// nil = not yet decided. Was a `Bool`, which meant an accepted and a rejected
    /// finding rendered the identical green checkmark — the shared glyph WAS the
    /// visible half of Terima and Tolak being the same action.
    var decision: ReviewDecision?

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
            switch decision {
            case .accepted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Diterima")
            case .rejected:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("Ditolak")
            case nil:
                EmptyView()
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
        .opacity(decision == nil ? 1 : 0.6)
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
            // Two numbers, and the label says which is which. The box figure is what
            // the condition score is built from; the segmentation figure is what the
            // road actually looks like inside that box. They differ by a lot on thin
            // cracks — that gap is the point, not a rendering bug.
            var text = String(format: "%.1f%% permukaan (kotak)", pct)
            if let extent = finding.extentPercent {
                text += String(format: " · %.1f%% (segmentasi)", extent)
            }
            parts.append(text.replacingOccurrences(of: ".", with: ","))
        }
        if let mapped = finding.mappedFromNote {
            parts.append(mapped)
        }
        return parts.joined(separator: " · ")
    }
}
