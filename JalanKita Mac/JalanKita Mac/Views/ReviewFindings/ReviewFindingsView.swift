//
//  ReviewFindingsView.swift
//  JalanKita Mac
//
//  §6.6 read-only review: verify what the pipeline already found, frame by
//  frame. No drawing tools, no editing masks — accept or reject only.
//
//  Refactored to use a native `Toggle(.button)` style for the mask/box
//  chips (previously a hand-rolled Button pretending to be a toggle, with
//  its own manual on/off color logic), real `.keyboardShortcut` on the
//  accept/reject/hide-mask actions (the J/K/M keycaps were previously
//  just labels — pressing the keys did nothing), and a `List` for the
//  left filter/class rail instead of tap-gesture buttons.
//
//  The three side-by-side panes use a plain `HStack`, not `HSplitView`.
//  This screen is the `detail` of the window's own `NavigationSplitView`,
//  and nesting a *second*, 3-pane `HSplitView` inside that detail slot
//  reproducibly corrupted the outer window sidebar's text layout (rows
//  rendered clipped from the left, section headers nearly disappeared) —
//  confirmed by toggling HSplitView vs HStack here with everything else
//  held constant. The other screens' HSplitViews are direct children of
//  NavigationSplitView's detail and have only two panes; neither seems to
//  trigger it. Losing user-draggable dividers on this one screen is a
//  reasonable trade for a sidebar that renders correctly everywhere else.
//

import SwiftUI
import JalanKitaKit

struct ReviewFindingsView: View {
    var model: AppModel

    @State private var maskActive = true
    @State private var boxActive = true
    @State private var selectedFindingID: String?
    @State private var reviewedIDs: Set<String> = []

    private var frame: ReviewFrame { model.reviewFrame }

    var body: some View {
        HStack(spacing: 0) {
            // A fixed width, not a min/max range — same reasoning as the
            // app's own sidebar in SidebarView.swift. This is a `List`
            // with `Section` headers, and letting an outer HStack squeeze
            // it down toward a stated minimum reproduced the identical
            // corrupted-header rendering, just on this inner list instead
            // of the window's main one.
            ReviewFilterSidebar()
                .frame(width: 240)
                .layoutPriority(1)

            VStack(spacing: 0) {
                FrameCanvasView(frame: frame, maskActive: maskActive, boxActive: boxActive,
                                 selectedFindingID: $selectedFindingID)
                    .padding(24)
                FilmstripView(frame: frame)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
            .frame(minWidth: 420, maxWidth: .infinity)

            ReviewFindingsPanel(
                frame: frame,
                selectedFindingID: $selectedFindingID,
                reviewedIDs: $reviewedIDs,
                onDecision: advanceToNextUnreviewed
            )
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 420)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .navigationTitle("Peninjauan temuan")
        .navigationSubtitle("\(frame.roadName) · \(frame.indexInQueue) dari \(frame.totalInQueue)")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Mask aktif", isOn: $maskActive)
                    .keyboardShortcut("m", modifiers: [])
                Toggle("Kotak aktif", isOn: $boxActive)
                Button("Acak ulang", systemImage: "shuffle") {
                    reshuffle()
                }
                .help("Buat ulang temuan dummy secara acak — backend segmentasi belum terhubung")
            }
        }
        .toggleStyle(.button)
        .onAppear {
            if selectedFindingID == nil { selectedFindingID = frame.findings.first?.id }
        }
    }

    private func reshuffle() {
        model.reviewFrame = DummySegmentation.makeReviewFrame()
        reviewedIDs.removeAll()
        selectedFindingID = model.reviewFrame.findings.first?.id
    }

    private func advanceToNextUnreviewed() {
        guard let currentID = selectedFindingID,
              let currentIndex = frame.findings.firstIndex(where: { $0.id == currentID }) else { return }
        let remaining = frame.findings[(currentIndex + 1)...]
        selectedFindingID = remaining.first { !reviewedIDs.contains($0.id) }?.id
            ?? frame.findings.first { !reviewedIDs.contains($0.id) }?.id
    }
}

#Preview {
    ContentView()
}
