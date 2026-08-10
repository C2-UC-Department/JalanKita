//
//  SegmentResult.swift
//  JalanKitaKit
//
//  One 10-metre road segment as reported back by the pipeline — the
//  reporting unit per the design brief's Appendix A.4, never an individual
//  defect count.
//

import Foundation

public struct SegmentResult: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let severity: Severity
    public let score: Int
    public let roadName: String
    public let kmMarker: String
    public let segmentLabel: String
    public let date: String
    public let defectTypes: [DefectType]
    public let hasBlockedParking: Bool
    public let areaSqm: Double

    public init(id: String, severity: Severity, score: Int, roadName: String, kmMarker: String,
                segmentLabel: String, date: String, defectTypes: [DefectType], hasBlockedParking: Bool,
                areaSqm: Double) {
        self.id = id
        self.severity = severity
        self.score = score
        self.roadName = roadName
        self.kmMarker = kmMarker
        self.segmentLabel = segmentLabel
        self.date = date
        self.defectTypes = defectTypes
        self.hasBlockedParking = hasBlockedParking
        self.areaSqm = areaSqm
    }
}
