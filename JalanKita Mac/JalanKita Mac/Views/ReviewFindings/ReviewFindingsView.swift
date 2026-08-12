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
//  The queue is now real detector output (ADR-015/016) rather than a single
//  randomized dummy frame, which changes two things structurally. There is an
//  EMPTY state — the dataset may be absent, and a UI-only checkout is expected
//  to run without it — so `frame` is optional all the way down. And "Acak ulang"
//  is gone: re-rolling random findings was the whole interaction model before,
//  whereas real review means stepping through a queue, so the toolbar carries
//  prev/next, a view menu, and the Stage 1 upload instead.
//
//  That upload action was, for one revision, invisible in practice. It was a
//  `Button("Analisis foto…", systemImage: "wand.and.stars")` sitting in the SAME
//  ToolbarItemGroup as the prev/next chevrons, and a macOS toolbar renders a
//  Label-bearing button icon-only by default — so it drew as a bare wand welded
//  into one segmented capsule with `<` and `>`, reading as a third NAVIGATION
//  control. Three separate things were wrong and all three are fixed here: it
//  moved to its own `.primaryAction` item (out of the nav capsule), it carries
//  `.labelStyle(.titleAndIcon)` (the title is the part that actually makes it
//  legible — without it the icon swap alone changes nothing), and it says
//  "Unggah foto…" with `photo.badge.plus` to match Antrean and Unggah Video
//  word-for-word rather than inventing a third verb for the same gesture.
//
//  Making room for a visible title is why the three display toggles collapsed
//  into one "Tampilan" menu. The rejected alternative was leaving them as button
//  toggles and accepting that the upload title truncates first on a narrow
//  window — i.e. reintroducing the exact bug, just later. Cost of the menu: the
//  toggles are one click further away.
//
//  ⚠️ The menu costs one non-obvious thing. A toolbar `Menu`'s content is only
//  instantiated when it OPENS, so `.keyboardShortcut("m")` declared on the mask
//  toggle inside it would silently stop working while closed — and both this
//  file's own history and ReviewFilterSidebar's "Pintasan" section advertise M
//  as real. The zero-size button in `.background` below exists solely to keep
//  that shortcut registered unconditionally. Do not delete it as dead UI.
//

import SwiftUI
import UniformTypeIdentifiers
import JalanKitaKit

struct ReviewFindingsView: View {
    var model: AppModel

    @State private var maskActive = true
    @State private var boxActive = true
    @State private var selectedFindingID: String?
    @State private var showingImporter = false
    @State private var importError: String?

    private var currentFrame: ReviewFrame? { model.reviewFrame }

    var body: some View {
        Group {
            if let currentFrame {
                content(for: currentFrame)
            } else {
                emptyState
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .navigationTitle("Peninjauan temuan")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Menu("Tampilan", systemImage: "eye") {
                    Toggle("Mask aktif", isOn: $maskActive)
                    Toggle("Kotak aktif", isOn: $boxActive)
                    Divider()
                    Toggle("Termasuk frame bersih", isOn: Binding(
                        get: { model.reviewIncludesCleanFrames },
                        set: { model.setReviewIncludesCleanFrames($0) }
                    ))
                    .help("Sertakan frame tanpa temuan — sebagian besar frame survei tidak rusak")
                }
            }

            ToolbarItemGroup {
                Button("Sebelumnya", systemImage: "chevron.left") {
                    model.stepReviewFrame(by: -1)
                    resetSelection()
                }
                .disabled((model.reviewQueuePosition ?? 0) <= 1)

                Button("Berikutnya", systemImage: "chevron.right") {
                    model.stepReviewFrame(by: 1)
                    resetSelection()
                }
                .disabled(model.reviewQueuePosition == nil
                          || model.reviewQueuePosition == model.reviewQueue.count)
            }

            // Stage 1: run the detector live on a new photo, as opposed to
            // reading the pre-computed dataset the queue loads on appear. Its
            // own item, NOT part of the group above — see the file header.
            ToolbarItem(placement: .primaryAction) {
                if model.isAnalyzingRoadDamage {
                    // A disabled button was the whole feedback story before, which
                    // for a CPU inference run reads as "this control is broken".
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Menganalisis…").foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Unggah foto…", systemImage: "photo.badge.plus")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Jalankan detektor pada foto baru dan tambahkan ke antrean")
                }
            }
        }
        // Keeps M working with the Tampilan menu closed; see the file header.
        // `.opacity(0)`, not `.hidden()`: a hidden view is dropped from layout
        // and takes its shortcut registration with it.
        .background {
            Button("") { maskActive.toggle() }
                .keyboardShortcut("m", modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image]) { result in
            handleImport(result)
        }
        // Two alerts, two different failures: this one is "we could not even read
        // the file you picked", which never reaches the worker at all.
        .alert("Unggah gagal", isPresented: .constant(importError != nil),
               presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { message in
            Text(message)
        }
        // ...and this one is "the detector ran and failed" — overwhelmingly
        // likely to be a missing RoadDamage/.venv on this machine.
        .alert("Analisis gagal", isPresented: .constant(model.roadDamageError != nil),
               presenting: model.roadDamageError) { _ in
            Button("OK") { model.roadDamageError = nil }
        } message: { message in
            Text(message)
        }
        .onAppear {
            if model.reviewQueue.isEmpty { model.loadRoadDamageQueue() }
            if selectedFindingID == nil { resetSelection() }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                model.analyzeRoadDamage(url: try Self.stageForWorker(url))
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Copies the picked file somewhere the worker can definitely read.
    ///
    /// Mirrors ProcessingQueueView's identical helper: the read access
    /// `.fileImporter` grants belongs to THIS process, not to the Python child
    /// that actually opens the path. Staging a plain copy sidesteps that rather
    /// than trying to hand a security scope across a process boundary. Kept even
    /// though the app is no longer sandboxed (CLAUDE.md fact 2) — this is one of
    /// the few places that would silently break if sandboxing ever came back.
    private static func stageForWorker(_ sourceURL: URL) throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        // Keep the original filename: it becomes ReviewFrame.id and the label the
        // reviewer sees, so a UUID here would make every analysis anonymous.
        let destination = stagingDir
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// "12 dari 236", or "0 dari 0" when there is nothing queued. Both numbers are
    /// derived from the queue itself — the previous version hardcoded 12 and 41.
    private var subtitle: String {
        guard let position = model.reviewQueuePosition, let currentFrame else {
            return "0 dari 0 · antrean kosong"
        }
        return "\(currentFrame.sourceClip) · \(position) dari \(model.reviewQueue.count)"
    }

    @ViewBuilder
    private func content(for frame: ReviewFrame) -> some View {
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
                FilmstripView(model: model, frame: frame)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
            .frame(minWidth: 420, maxWidth: .infinity)

            ReviewFindingsPanel(
                frame: frame,
                selectedFindingID: $selectedFindingID,
                reviewedIDs: Binding(
                    get: { model.reviewedFindingIDs },
                    set: { model.reviewedFindingIDs = $0 }
                ),
                onDecision: advanceToNextUnreviewed
            )
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 420)
        }
    }

    /// Reached in two very different situations, so the copy has to distinguish
    /// them: the dataset is missing (a setup problem, with the reason in the log),
    /// or it loaded and genuinely contains nothing to review.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Tidak ada frame untuk ditinjau", systemImage: "photo.on.rectangle.angled")
        } description: {
            if let reason = model.reviewLoadWarnings.first {
                Text(reason)
            } else if !model.reviewIncludesCleanFrames {
                Text("Detektor tidak menemukan kerusakan pada frame mana pun. "
                     + "Aktifkan “Termasuk frame bersih” untuk menelusuri seluruh survei.")
            } else {
                Text("Antrean peninjauan kosong.")
            }
        } actions: {
            // Upload first, and prominent. "Muat ulang antrean" was the only
            // action here, which is precisely backwards in the case that matters:
            // when the Stage 0 dataset is absent, reloading just fails again,
            // while analysing your own photo is the one thing that does work.
            Button("Unggah foto…") { showingImporter = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAnalyzingRoadDamage)
            Button("Muat ulang antrean") { model.loadRoadDamageQueue() }
        }
    }

    private func resetSelection() {
        selectedFindingID = model.reviewFrame?.findings.first?.id
    }

    private func advanceToNextUnreviewed() {
        guard let currentFrame,
              let currentID = selectedFindingID,
              let currentIndex = currentFrame.findings.firstIndex(where: { $0.id == currentID }) else { return }
        let remaining = currentFrame.findings[(currentIndex + 1)...]
        selectedFindingID = remaining.first { !model.reviewedFindingIDs.contains($0.id) }?.id
            ?? currentFrame.findings.first { !model.reviewedFindingIDs.contains($0.id) }?.id
    }
}

#Preview {
    ContentView()
}
