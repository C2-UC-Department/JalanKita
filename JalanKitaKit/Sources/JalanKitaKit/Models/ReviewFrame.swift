//
//  ReviewFrame.swift
//  JalanKitaKit
//
//  A reviewed frame: the unit of work on the Peninjauan Temuan screen.
//

import Foundation

public struct ReviewFrame: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let roadName: String
    public let indexInQueue: Int
    public let totalInQueue: Int
    public let frameNumber: String
    public let timecode: String
    public let severity: Severity
    public let score: Int
    public let isProvisional: Bool
    public let segmentLabel: String
    public let kmMarker: String
    public let coordinate: String
    public let gpsAccuracyM: Int
    public let findings: [Finding]
    public let startScore: Int
    public let deductions: [SeverityDeduction]

    public init(id: String, roadName: String, indexInQueue: Int, totalInQueue: Int, frameNumber: String,
                timecode: String, severity: Severity, score: Int, isProvisional: Bool, segmentLabel: String,
                kmMarker: String, coordinate: String, gpsAccuracyM: Int, findings: [Finding],
                startScore: Int, deductions: [SeverityDeduction]) {
        self.id = id
        self.roadName = roadName
        self.indexInQueue = indexInQueue
        self.totalInQueue = totalInQueue
        self.frameNumber = frameNumber
        self.timecode = timecode
        self.severity = severity
        self.score = score
        self.isProvisional = isProvisional
        self.segmentLabel = segmentLabel
        self.kmMarker = kmMarker
        self.coordinate = coordinate
        self.gpsAccuracyM = gpsAccuracyM
        self.findings = findings
        self.startScore = startScore
        self.deductions = deductions
    }
}
