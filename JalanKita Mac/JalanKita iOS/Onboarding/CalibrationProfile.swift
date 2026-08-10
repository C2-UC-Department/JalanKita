//
//  CalibrationProfile.swift
//  JalanKita iOS
//
//  One mount's scale calibration (design brief §6.1.3 / §6.7): a captured
//  frame plus a known real-world width in metres. Stored locally only for
//  now — not yet wired to a real pixel-to-metres conversion (that math
//  lives in a sibling repo's `src/ipm.py`, not this one) and not yet
//  synced anywhere. Kept iOS-local rather than in JalanKitaKit because
//  nothing on the Mac side consumes it yet; move it once CloudKit sync
//  (Phase 2) needs to share it.
//

import Foundation

struct CalibrationProfile: Codable {
    var mountLabel: String
    var knownWidthMeters: Double
    /// Filename (not full path) of the calibration frame JPEG, stored
    /// alongside this profile under Application Support.
    var frameFilename: String
    var createdAt: Date
}
