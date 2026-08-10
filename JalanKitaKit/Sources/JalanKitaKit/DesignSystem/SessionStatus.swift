//
//  SessionStatus.swift
//  JalanKitaKit
//
//  Pipeline/processing status for a session — orthogonal to road-condition
//  Severity. This tracks where a *session* sits in the ingest → process →
//  report pipeline, not how bad the road is.
//
//  Shared verbatim between JalanKita Mac and JalanKita iOS. The iOS
//  recording app also reuses `.degraded(reason:)` for GPS-loss during
//  capture, rather than inventing a parallel status vocabulary.
//

import SwiftUI

public enum SessionStatus: Hashable, Codable, Sendable {
    case readyToProcess
    case segmenting(progress: Double)
    case degraded(reason: String)
    case done
    case failed(reason: String)

    public var label: String {
        switch self {
        case .readyToProcess: "SIAP DIPROSES"
        case .segmenting(let p): "SEGMENTASI \(Int(p * 100))%"
        case .degraded: "TERDEGRADASI"
        case .done: "SELESAI"
        case .failed: "GAGAL"
        }
    }

    public var symbolName: String? {
        switch self {
        case .readyToProcess: "square.fill"
        case .segmenting: "circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }

    public var foreground: Color {
        switch self {
        case .readyToProcess: Color(white: 0.35)
        case .segmenting: .white
        case .degraded: .white
        case .done: .white
        case .failed: .white
        }
    }

    public var background: Color {
        switch self {
        case .readyToProcess: Color(white: 0.90)
        case .segmenting: Color(red: 0.20, green: 0.48, blue: 0.96)
        case .degraded: Color(red: 0.92, green: 0.58, blue: 0.13)
        case .done: Color(white: 0.10)
        case .failed: Color(red: 0.82, green: 0.20, blue: 0.24)
        }
    }

    /// A session counts toward the processing queue once it's ready or
    /// already running — not before (still just an inbox item) and not
    /// after (done/failed/degraded sessions leave the active queue).
    public var isQueued: Bool {
        switch self {
        case .readyToProcess, .segmenting: true
        case .degraded, .done, .failed: false
        }
    }
}

public struct SessionStatusBadge: View {
    let status: SessionStatus

    public init(status: SessionStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let symbol = status.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(status.label)
                .font(.caption2.weight(.bold))
                .tracking(0.3)
        }
        .foregroundStyle(status.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(status.background, in: Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        SessionStatusBadge(status: .readyToProcess)
        SessionStatusBadge(status: .segmenting(progress: 0.42))
        SessionStatusBadge(status: .degraded(reason: "4,2 km tanpa jejak"))
        SessionStatusBadge(status: .done)
        SessionStatusBadge(status: .failed(reason: "video rusak"))
    }
    .padding()
}
