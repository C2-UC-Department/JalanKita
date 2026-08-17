//
//  AppSection.swift
//  JalanKita Mac
//

import Foundation
import JalanKitaKit

enum AppSection: String, Identifiable, Hashable {
    case sessionInbox
    case queue
    case mapSegments
    case findingsMap
    case reports
    case surveyors
    case calibration
    case cloudSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionInbox: "Sesi masuk"
        case .queue: "Antrean"
        case .mapSegments: "Peta & segmen"
        case .findingsMap: "Peta temuan"
        case .reports: "Laporan"
        case .surveyors: "Surveyor"
        case .calibration: "Model & kalibrasi"
        case .cloudSync: "Sinkronisasi iCloud"
        }
    }

    var symbolName: String {
        switch self {
        case .sessionInbox: "tray.full.fill"
        case .queue: "clock.fill"
        case .mapSegments: "map.fill"
        case .findingsMap: "mappin.and.ellipse"
        case .reports: "doc.text.fill"
        case .surveyors: "person.2.fill"
        case .calibration: "slider.horizontal.3"
        case .cloudSync: "icloud.and.arrow.up.fill"
        }
    }

    enum Group: String, Identifiable {
        case pemrosesan = "PEMROSESAN"
        case hasil = "HASIL"
        case lapangan = "LAPANGAN"

        var id: String { rawValue }
    }

    static let groups: [(Group, [AppSection])] = [
        (.pemrosesan, [.sessionInbox, .queue]),
        (.hasil, [.mapSegments, .findingsMap, .reports]),
        (.lapangan, [.surveyors, .calibration, .cloudSync]),
    ]
}
