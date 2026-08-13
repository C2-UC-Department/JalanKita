//
//  SeverityDeduction.swift
//  JalanKitaKit
//

import Foundation

/// One row of the severity arithmetic, straight from Python's
/// `effective_deductions()`. Signed — always negative in practice.
///
/// `points` is a `Double`, and that is load-bearing rather than fussy. It used to
/// be `Int`, built with `-Int(deduct_effective.rounded())`, which threw away the
/// fraction at construction while the published `condition` came from Python's
/// sum of the UNROUNDED values. Measured over the real Stage 0 CSVs, the rows
/// then failed to add up to the total on **27 of the 236 damaged frames** — 14 low
/// by a point, 13 high, and never by more than one. For example
/// `IMG_0044_f000390_t0013000`: rows 5.854 / 7.741 / 4.682 / 39.682 rendered as
/// −6 −8 −5 −40 = 59, so the panel showed 41 where Python had published 42. Carry
/// the full precision and round only for display, at one decimal, and every one
/// of those closes — verified by replaying all 958 frames through the panel's
/// arithmetic, 0 remaining.
public struct SeverityDeduction: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let label: String
    public let points: Double

    public init(id: UUID = UUID(), label: String, points: Double) {
        self.id = id
        self.label = label
        self.points = points
    }
}
