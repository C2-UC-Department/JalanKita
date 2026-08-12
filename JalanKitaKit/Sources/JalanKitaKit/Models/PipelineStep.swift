//
//  PipelineStep.swift
//  JalanKitaKit
//

import Foundation

public struct PipelineStep: Identifiable, Hashable, Codable, Sendable {
    public enum State: Hashable, Codable, Sendable { case done, active, waiting }

    public let id: Int
    public let title: String
    public var state: State
    public var detail: String
    public var stats: String
    public var warning: String?
    public var subProgress: Double?

    public init(id: Int, title: String, state: State, detail: String, stats: String,
                warning: String? = nil, subProgress: Double? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.stats = stats
        self.warning = warning
        self.subProgress = subProgress
    }
}
