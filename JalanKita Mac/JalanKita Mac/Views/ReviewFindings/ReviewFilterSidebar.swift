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
//  ── It is wired to real data now, which it never was ──────────────────────
//
//  Every number on this rail used to be a literal. The class counts
//  (76/138/131) were real ONCE — they match `outputs/quantify/summary.json`'s
//  `per_class_defects` exactly — but they were a frozen snapshot that went
//  stale the moment a Stage 1 analysis inserted a frame or the clean-frame
//  toggle reloaded the queue. The status counts (41/318/27) matched nothing at
//  all: they sum to 386 against a dataset holding 345 boxes. And the `Picker`
//  was bound to view-local `@State` that no other view read, so choosing a row
//  moved a checkmark and filtered nothing.
//
//  Wired rather than deleted, which was the other option. Deleting would have
//  been right if the data didn't exist — but it does, the counts are one
//  `reduce` over the queue, and this rail is the only surface on the screen
//  that answers "how much is left". Throwing away a working answer because the
//  current version is hardcoded is the wrong trade.
//
//  ⚠️ `blockedPark` is gone from the class list, and not by special-casing it:
//  the section iterates `AppModel.reviewDefectTypesPresent` — the classes the
//  loaded queue actually contains — instead of `DefectType.allCases`. The
//  road-damage detector emits the merged 3-class taxonomy (crack / alligator /
//  pothole) and structurally cannot produce a blocked-parking finding, which
//  `RoadDamageDataset.defectType(_:)` already says in a comment. This rail was
//  the one place on screen contradicting it, complete with a count of 62. The
//  enum keeps the case; the parking vertical and the map still use it.
//

import SwiftUI

struct ReviewFilterSidebar: View {
    var model: AppModel

    var body: some View {
        List {
            Section("Saringan") {
                Picker("", selection: Binding(
                    get: { model.reviewStatusFilter },
                    set: { model.reviewStatusFilter = $0 }
                )) {
                    ForEach(ReviewStatusFilter.allCases) { option in
                        HStack {
                            Text(option.rawValue)
                            Spacer()
                            Text("\(model.reviewFindingCount(option))")
                                .font(.data(12))
                                .foregroundStyle(.secondary)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            // Only worth the space once there is more than one clip to choose
            // between — which is exactly when a video has been analysed into a
            // queue that already holds 29 clips' worth of Stage 0 frames.
            if model.reviewClipsPresent.count > 1 {
                Section("Klip") {
                    Picker("", selection: Binding(
                        get: { model.reviewClipFilter },
                        set: { model.reviewClipFilter = $0 }
                    )) {
                        Text("Semua klip").tag(String?.none)
                        ForEach(model.reviewClipsPresent, id: \.self) { clip in
                            Text(clip).tag(String?.some(clip))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Section("Kelas") {
                // Empty until a queue is loaded — an honest blank section rather
                // than a list of classes with zeroes beside them.
                ForEach(model.reviewDefectTypesPresent) { type in
                    Label {
                        HStack {
                            Text(type.label)
                            Spacer()
                            Text("\(model.reviewFindingCount(ofType: type))")
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
