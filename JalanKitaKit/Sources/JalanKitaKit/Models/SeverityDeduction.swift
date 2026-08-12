//
//  SeverityDeduction.swift
//  JalanKitaKit
//

import Foundation

public struct SeverityDeduction: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let label: String
    public let points: Int

    public init(id: UUID = UUID(), label: String, points: Int) {
        self.id = id
        self.label = label
        self.points = points
    }
}
