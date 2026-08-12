//
//  LogLine.swift
//  JalanKitaKit
//

import Foundation

public struct LogLine: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let time: String
    public let message: String
    public let isWarning: Bool

    public init(id: UUID = UUID(), time: String, message: String, isWarning: Bool) {
        self.id = id
        self.time = time
        self.message = message
        self.isWarning = isWarning
    }
}
