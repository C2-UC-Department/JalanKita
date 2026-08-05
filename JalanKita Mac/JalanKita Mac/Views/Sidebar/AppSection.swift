//
//  AppSection.swift
//  JalanKita Mac
//

import Foundation

enum AppSection: String, Identifiable, Hashable {
    case sessionInbox
    case queue
    case review
    case parkingReview
    case mapSegments
    case reports
    case surveyors
    case calibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionInbox: "Sesi masuk"
        case .queue: "Antrean"
        case .review: "Peninjauan"
        case .parkingReview: "Tinjauan Parkir"
        case .mapSegments: "Peta & segmen"
        case .reports: "Laporan"
        case .surveyors: "Surveyor"
        case .calibration: "Model & kalibrasi"
        }
    }

    var symbolName: String {
        switch self {
        case .sessionInbox: "tray.full.fill"
        case .queue: "clock.fill"
        case .review: "checkmark.magnifyingglass"
        case .parkingReview: "parkingsign.circle.fill"
        case .mapSegments: "map.fill"
        case .reports: "doc.text.fill"
        case .surveyors: "person.2.fill"
        case .calibration: "slider.horizontal.3"
        }
    }

    enum Group: String, Identifiable {
        case pemrosesan = "PEMROSESAN"
        case hasil = "HASIL"
        case lapangan = "LAPANGAN"

        var id: String { rawValue }
    }

    static let groups: [(Group, [AppSection])] = [
        (.pemrosesan, [.sessionInbox, .queue, .review, .parkingReview]),
        (.hasil, [.mapSegments, .reports]),
        (.lapangan, [.surveyors, .calibration]),
    ]
}
