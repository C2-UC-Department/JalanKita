//
//  ContentView.swift
//  JalanKita Mac
//
//  Root layout: a standard NavigationSplitView instead of a hand-rolled
//  HStack + manually-inset dark sidebar. This is what gives us, for free,
//  a resizable/collapsible sidebar, correct traffic-light layout, native
//  toolbar integration, and keyboard navigation — all of which the
//  previous hidden-title-bar + fixed-28pt-offset approach had to fake by
//  hand and got wrong in edge cases.
//
//  State lives in one `AppModel` (Observation framework), created once
//  here and handed to every screen — not re-derived as separate
//  `@State private var sessions = SampleData.sessions` copies per view.
//
//  Deliberately no `.frame(minWidth:minHeight:)` on the NavigationSplitView
//  itself. An earlier pass added one (to stop the window shrinking past
//  what the content needed), and it reproduced the exact sidebar text
//  corruption this file's other comments describe — but only once the
//  window was resized down to sit exactly at that externally-imposed
//  floor. NavigationSplitView already computes its own minimum from the
//  sidebar and detail content's own `.frame` constraints; stacking a
//  second, independently-computed minimum on top of that gave two
//  sources of truth for "how small can this get," and pinning the window
//  at the outer one left the sidebar laid out against a stale width.
//  Letting the split view own its natural minimum removed the bug
//  entirely, confirmed by forcing the window to its floor on every
//  screen. If a minimum ever needs restating, each pane already declares
//  its own via `.frame(minWidth:)` / `.navigationSplitViewColumnWidth`;
//  add width there, not here.
//

import SwiftUI
import Combine
import JalanKitaKit

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            NavigationStack {
                detailView
                    // Registered here, at the top of the NavigationStack,
                    // not inside SessionInboxView's own body — that view's
                    // root is an `HSplitView`, and this file's other
                    // comments already document that nesting complex layout
                    // containers directly under NavigationSplitView/
                    // NavigationStack causes real SwiftUI/AppKit bugs on
                    // macOS (previously seen as sidebar corruption; a
                    // `.navigationDestination` attached inside one of those
                    // panes is the same risky pattern one level deeper).
                    .navigationDestination(for: Session.self) { session in
                        ParkingVideoReviewView(session: session, model: model)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Reap the road-damage worker on quit. Without this the child Python
        // process outlives the app — the problem CLAUDE.md fact 14 records for
        // the other two services, whose shutdown paths still have no caller.
        // `willTerminate` rather than `.onDisappear`, which doesn't fire reliably
        // on app quit, only on the window going away.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            Task { await model.shutdownServices() }
        }
        // `preferredColorScheme` drives the whole window's NSAppearance on
        // macOS, not just the subtree it's attached to — setting it deep
        // inside ReviewFindingsView left the sidebar and the review pane
        // arguing over two different appearances in the same window,
        // which is what caused sidebar rows to render clipped on that
        // screen. Forcing it once, here, at the window root keeps sidebar
        // and content consistently in the same appearance.
        .preferredColorScheme(model.selection == .review ? .dark : nil)
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selection {
        case .sessionInbox:
            SessionInboxView(model: model)
        case .queue:
            ProcessingQueueView(model: model)
        case .review:
            ReviewFindingsView(model: model)
        case .mapSegments:
            MapSegmentsView(model: model)
        case .cloudSync:
            CloudSyncSettingsView(model: model)
        case .reports, .surveyors, .calibration:
            ContentUnavailableView(
                model.selection.title,
                systemImage: model.selection.symbolName,
                description: Text("Layar ini belum termasuk dalam empat referensi desain saat ini.")
            )
        }
    }
}

#Preview {
    ContentView()
}
