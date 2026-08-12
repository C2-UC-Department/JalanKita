//
//  ReviewFilterSidebar.swift
//  JalanKita Mac
//
//  The status filter is a genuine single-choice control now: a `Picker`
//  with `.inline` style, which renders as a checkmarked list and comes
//  with the right semantics for free. The previous version was a plain
//  Button per row manually drawing its own checkmark/square glyph, which
//  looked like a real control but wasn't wired to anything resembling
//  Picker/Toggle semantics (no keyboard access, no accessibility trait).
//

import SwiftUI
import JalanKitaKit

private enum ReviewStatusFilter: String, CaseIterable, Identifiable {
    case unseen = "Belum dilihat"
    case verified = "Terverifikasi"
    case rejected = "Ditolak"

    var id: String { rawValue }

    var count: Int {
        switch self {
        case .unseen: 41
        case .verified: 318
        case .rejected: 27
        }
    }
}

struct ReviewFilterSidebar: View {
    @State private var filter: ReviewStatusFilter = .unseen

    var body: some View {
        List {
            Section("Saringan") {
                Picker("", selection: $filter) {
                    ForEach(ReviewStatusFilter.allCases) { option in
                        HStack {
                            Text(option.rawValue)
                            Spacer()
                            Text("\(option.count)")
                                .font(.data(12))
                                .foregroundStyle(.secondary)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Kelas") {
                ForEach(DefectType.allCases) { type in
                    Label {
                        HStack {
                            Text(type.label)
                            Spacer()
                            Text("\(classCount(type))")
                                .font(.data(12))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        DefectSwatch(type: type, size: 13)
                    }
                }
            }

            Section("Pintasan") {
                shortcutRow("J", "terima")
                shortcutRow("K", "tolak")
                shortcutRow("M", "sembunyikan mask")
            }
        }
        .listStyle(.inset)
    }

    private func classCount(_ type: DefectType) -> Int {
        switch type {
        case .pothole: 76
        case .alligator: 138
        case .crack: 131
        case .blockedPark: 62
        }
    }

    private func shortcutRow(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 20, height: 20)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(action).foregroundStyle(.secondary)
        }
    }
}
