//
//  SidebarView.swift
//  JalanKita Mac
//
//  A genuine macOS sidebar: `List(selection:)` inside a NavigationSplitView
//  column. This replaces a hand-built VStack of tappable rows that
//  reimplemented hover/selection/focus itself with @State — which is
//  exactly the class of bug this pass is fixing (missed hover resets,
//  no keyboard navigation, no accessibility for free). `.badge()` gives
//  us the trailing counters natively instead of a custom capsule view.
//

import SwiftUI

struct SidebarView: View {
    var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { newValue in if let newValue { model.selection = newValue } }
        )) {
            ForEach(AppSection.groups, id: \.0.id) { group, sections in
                Section(group.rawValue.capitalized) {
                    ForEach(sections) { section in
                        Label(section.title, systemImage: section.symbolName)
                            .badge(badgeCount(for: section))
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SystemStatusFooter(isProcessing: !model.queuedSessions.isEmpty && model.selection == .queue)
                .padding(10)
        }
        // A fixed width, not a min/ideal/max range: when the window gets
        // tight on space, NavigationSplitView is willing to shrink this
        // column *below* a stated minimum instead of shrinking the detail
        // pane — at exactly 1180pt window width (this app's old declared
        // minimum) the sidebar collapsed to roughly 100pt, losing every
        // row's icon and label and leaving only the trailing badge
        // number. A single fixed value gives the split view nothing to
        // negotiate away.
        .navigationSplitViewColumnWidth(240)
    }

    private func badgeCount(for section: AppSection) -> Int {
        switch section {
        case .sessionInbox: model.batchSelectedCount
        case .queue: model.queuedSessions.count
        case .review: model.unreviewedFindingsCount
        case .parkingReview: model.parkingReviewSessions.count
        case .surveyors: model.surveyorCount
        case .mapSegments, .reports, .calibration: 0
        }
    }
}

struct SystemStatusFooter: View {
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(isProcessing ? "Sedang bekerja" : "Mac mini M4")
                    .font(.system(size: 12, weight: .semibold))
                Text(isProcessing
                     ? "GPU 91% · 22,4 GB · 1,04 frame/detik · sisa ± 38 menit"
                     : "GPU 62% · 18,3 GB · 1,04 frame/detik")
                    .font(.data(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
