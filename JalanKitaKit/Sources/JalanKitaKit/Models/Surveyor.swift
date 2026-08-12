//
//  Surveyor.swift
//  JalanKitaKit
//

import Foundation

public struct Surveyor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
