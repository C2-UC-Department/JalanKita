//
//  DummySegmentation.swift
//  JalanKita Mac
//
//  Stands in for the real segmentation/severity pipeline (Appendix A.6),
//  which lives in a different repo and isn't wired up yet. Generates a
//  plausible-looking — but randomized — set of findings each time the
//  app launches, positioned over the actual road/vehicle regions of the
//  bundled sample photo (ReviewSampleFrame, aka IMG_0885), so the review
//  screen exercises the same layout and scoring path real model output
//  will eventually take.
//

import Foundation
import CoreGraphics

enum DummySegmentation {

    private struct DamageCandidate {
        let type: DefectType
        let rect: CGRect
    }

    /// Small rectangles over visible asphalt in ReviewSampleFrame —
    /// between and beside the cars, and the foreground strip in front of
    /// the dashboard. Kept off the sky/building/dashboard regions of the
    /// photo so a randomly-placed "pothole" never lands somewhere absurd.
    private static let damageCandidates: [DamageCandidate] = [
        DamageCandidate(type: .pothole, rect: CGRect(x: 0.40, y: 0.685, width: 0.10, height: 0.035)),
        DamageCandidate(type: .crack, rect: CGRect(x: 0.30, y: 0.715, width: 0.14, height: 0.03)),
        DamageCandidate(type: .alligator, rect: CGRect(x: 0.50, y: 0.735, width: 0.16, height: 0.035)),
        DamageCandidate(type: .crack, rect: CGRect(x: 0.20, y: 0.755, width: 0.18, height: 0.03)),
        DamageCandidate(type: .pothole, rect: CGRect(x: 0.62, y: 0.775, width: 0.12, height: 0.035)),
        DamageCandidate(type: .alligator, rect: CGRect(x: 0.38, y: 0.80, width: 0.20, height: 0.04)),
    ]

    /// Vehicles actually present in the photo: the parked Innova with a
    /// traffic cone beside it (left), and the CR-V ahead in the lane
    /// (right) — real "illegal parking" source material per Appendix A.7.
    private static let parkingCandidates: [CGRect] = [
        CGRect(x: 0.285, y: 0.535, width: 0.235, height: 0.155),
        CGRect(x: 0.60, y: 0.585, width: 0.235, height: 0.145),
    ]

    static func randomFindings() -> [Finding] {
        var findings: [Finding] = []

        let damageCount = Int.random(in: 1...3)
        for candidate in damageCandidates.shuffled().prefix(damageCount) {
            findings.append(finding(for: candidate))
        }

        // Nearly always include a parking finding — the photo is drawn
        // from the illegal-parking dataset, so it should almost always
        // read that way, but the odd frame with no reportable vehicle
        // keeps the demo honest about false negatives.
        if Double.random(in: 0...1) < 0.85, let box = parkingCandidates.randomElement() {
            findings.append(Finding(
                id: UUID().uuidString,
                defectType: .blockedPark,
                areaSqm: nil,
                percentOfSurface: nil,
                vehicleNote: "1 kendaraan · di badan jalan",
                confidence: Double.random(in: 0.80...0.98),
                mappedFromNote: nil,
                frameRect: box
            ))
        }

        return findings
    }

    private static func finding(for candidate: DamageCandidate) -> Finding {
        let confidence = Double.random(in: 0.55...0.97)
        switch candidate.type {
        case .pothole:
            return Finding(id: UUID().uuidString, defectType: .pothole,
                            areaSqm: Double.random(in: 0.4...3.2),
                            percentOfSurface: Double.random(in: 2...12),
                            vehicleNote: nil, confidence: confidence, mappedFromNote: nil,
                            frameRect: candidate.rect)
        case .alligator:
            return Finding(id: UUID().uuidString, defectType: .alligator,
                            areaSqm: Double.random(in: 0.3...1.6),
                            percentOfSurface: nil,
                            vehicleNote: nil, confidence: confidence,
                            mappedFromNote: "dinilai sebagai retak",
                            frameRect: candidate.rect)
        case .crack:
            return Finding(id: UUID().uuidString, defectType: .crack,
                            areaSqm: Double.random(in: 0.1...0.9),
                            percentOfSurface: nil,
                            vehicleNote: nil, confidence: confidence, mappedFromNote: nil,
                            frameRect: candidate.rect)
        case .blockedPark:
            fatalError("blockedPark is not a damage candidate")
        }
    }

    /// A simplified stand-in for `severity.py` (Appendix A.6): a
    /// PCI-informed deduction table off a perfect 100, with diminishing
    /// returns for repeated defect classes. Good enough to make the
    /// on-screen breakdown track whatever findings were actually rolled,
    /// not a claim about calibrated accuracy.
    static func severityBreakdown(for findings: [Finding]) -> (score: Int, deductions: [SeverityDeduction]) {
        var score = 100
        var deductions: [SeverityDeduction] = []
        var seenTypes: Set<DefectType> = []

        for finding in findings where finding.defectType != .blockedPark {
            let baseDeduction: Int
            switch finding.defectType {
            case .pothole: baseDeduction = 46
            case .alligator: baseDeduction = 15
            case .crack: baseDeduction = 8
            case .blockedPark: baseDeduction = 0
            }

            let isRepeat = seenTypes.contains(finding.defectType)
            seenTypes.insert(finding.defectType)

            let points = isRepeat ? -max(baseDeduction / 3, 3) : -baseDeduction
            score += points

            let label = isRepeat
                ? "Pengulangan kelas \(finding.defectType.label.lowercased())"
                : "\(finding.defectType.label) · di jalur roda ×1,4"
            deductions.append(SeverityDeduction(label: label, points: points))
        }

        return (max(score, 5), deductions)
    }

    static func makeReviewFrame() -> ReviewFrame {
        let findings = randomFindings()
        let (score, deductions) = severityBreakdown(for: findings)
        return ReviewFrame(
            id: "f\(Int.random(in: 1000...9999))",
            roadName: "Jl. Raya Darmo",
            indexInQueue: 12,
            totalInQueue: 41,
            frameNumber: String(format: "%06d", Int.random(in: 100...999)),
            timecode: "00:48:11",
            severity: Severity(score: score),
            score: score,
            isProvisional: true,
            segmentLabel: "Segmen 214",
            kmMarker: "km 3,42",
            coordinate: "-7,2823 / 112,7386",
            gpsAccuracyM: 7,
            findings: findings,
            startScore: 100,
            deductions: deductions
        )
    }
}
