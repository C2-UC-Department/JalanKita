//
//  CalibrationProfile.swift
//  JalanKitaKit
//
//  One mount's scale calibration (design brief §6.1.3 / §6.7): a captured
//  frame plus a known real-world width in metres. Not yet wired to a real
//  pixel-to-metres conversion (that math lives in a sibling repo's
//  `src/ipm.py`, not this one). Moved here from the iOS target once
//  CloudKit sync needed to share it — see `CalibrationProfile+CloudKit.swift`.
//

import Foundation

public struct CalibrationProfile: Codable, Sendable {
    public var mountLabel: String
    public var knownWidthMeters: Double
    /// Filename (not full path) of the calibration frame JPEG, stored
    /// alongside this profile under each platform's own Application
    /// Support directory. The actual pixel content syncs as a CKAsset
    /// (`CloudKitSchema.CalibrationField.frameAsset`), attached/read by
    /// each sync engine — this filename is purely local staging and isn't
    /// itself part of the synced record.
    public var frameFilename: String
    public var createdAt: Date
    public var surveyorID: String

    public init(mountLabel: String, knownWidthMeters: Double, frameFilename: String, createdAt: Date, surveyorID: String) {
        self.mountLabel = mountLabel
        self.knownWidthMeters = knownWidthMeters
        self.frameFilename = frameFilename
        self.createdAt = createdAt
        self.surveyorID = surveyorID
    }
}
