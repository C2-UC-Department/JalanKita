//
//  ProcessingQueueView.swift
//  JalanKita Mac
//
//  Operator console for the pipeline in Appendix C. The queue list is now
//  a real `List(selection:)` instead of a ScrollView of manually-tapped
//  rows — selection, hover, and keyboard up/down navigation all come from
//  the framework instead of being reimplemented with @State.
//
//  Pure queue/progress viewer, no upload entry point of its own — both
//  "Unggah foto…" and "Unggah video…" live in Session Inbox's toolbar,
//  since that's where sessions actually live; a session created by either
//  upload shows up here automatically once its status flips to `.segmenting`.
//

import SwiftUI
import JalanKitaKit

struct ProcessingQueueView: View {
    var model: AppModel

    @State private var selection: Session.ID?

    private var queue: [Session] { model.queuedSessions }

    private var active: Session? {
        queue.first { $0.id == selection } ?? queue.first(where: isRunning) ?? queue.first
    }

    var body: some View {
        HSplitView {
            // `.listStyle(.sidebar)` pulls in NSVisualEffectView-based
            // vibrancy meant for a genuine top-level app sidebar (like the
            // real one on the far left) — this List is a secondary list
            // inside a content pane, not that, and with zero rows that
            // vibrancy rendered as a translucent block letting whatever
            // sits behind the window bleed through instead of a normal
            // opaque background. `.inset` is the correct style for a
            // regular in-pane list and doesn't carry that vibrancy at all.
            List(queue, selection: $selection) { session in
                QueueRow(session: session)
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                todaySummary
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            Group {
                if let active {
                    detail(for: active)
                } else {
                    noActiveSession
                }
            }
            .frame(minWidth: 500)
        }
        .navigationTitle("Antrean pemrosesan")
        .navigationSubtitle("\(queue.filter(isRunning).count) berjalan · \(queue.count - queue.filter(isRunning).count) menunggu")
        .toolbar {
            ToolbarItem { Button("Jeda antrean") {} }
            ToolbarItem { Button("Log lengkap") {} }
        }
        .onAppear {
            selectDefaultIfNeeded()
        }
        .onChange(of: model.sessions) { _, _ in
            selectDefaultIfNeeded()
        }
    }

    /// Prefers whichever session is actively `.segmenting` over just
    /// "first in the queue" — with synced sessions now waiting at
    /// `.readyToProcess` for a manual "Proses" click (instead of
    /// auto-starting), the queue can easily hold several sessions at once,
    /// and a reviewer landing here after starting one wants to see IT, not
    /// whichever one happens to sort first. Only touches the selection when
    /// it's missing or no longer in the queue (finished/removed) — never
    /// yanks the view away from a session someone deliberately clicked on.
    private func selectDefaultIfNeeded() {
        guard selection == nil || !queue.contains(where: { $0.id == selection }) else { return }
        selection = queue.first(where: isRunning)?.id ?? queue.first?.id
    }

    private func isRunning(_ session: Session) -> Bool {
        if case .segmenting = session.status { return true }
        return false
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "RINGKASAN")
            todayStat("Sesi selesai", "\(model.doneSessionsCount)")
            todayStat("Kendaraan diproses", "\(model.totalVehiclesAnalyzed)")
        }
        .padding(12)
        // A flat, mostly-opaque fill — `.regularMaterial` here stacked its
        // own blur on top of the sidebar's already-vibrant background,
        // reading as washed-out/see-through rather than a distinct card.
        // Same treatment as SidebarView's own pinned-bottom card.
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    /// Right pane when nothing's processing — keeps the same list-leftmost/
    /// detail-rightmost layout Antrean always has (the queue list stays
    /// visible and simply empty), rather than swapping the whole screen for
    /// a separate empty-state layout.
    private var noActiveSession: some View {
        ContentUnavailableView {
            Label("Tidak ada yang diproses", systemImage: "clock")
        } description: {
            Text("Pilih sesi yang siap diproses di Sesi Masuk lalu klik \"Proses\" untuk memulainya di sini.")
        } actions: {
            Button {
                model.selection = .sessionInbox
            } label: {
                Label("Buka Sesi Masuk", systemImage: "tray.full")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func todayStat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.data(12.5, weight: .semibold))
        }
    }

    private func detail(for session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.roadName).font(.title3.weight(.bold))
                    Text("\(session.date) · \(session.duration) · \(formatted(session.distanceKm)) km · \(session.clipCount) klip · \(formatted(session.sizeGB)) GB")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    progressStat("KEMAJUAN", progressText(for: session), color: .accentColor)
                    Spacer()
                }

                if steps(for: session).isEmpty {
                    Text("Belum diproses — pilih sesi ini lalu klik \"Proses\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(steps(for: session)) { step in
                            PipelineStepRow(step: step)
                        }
                    }
                }

                LogConsoleView(lines: model.logLines[session.id] ?? [])
                    .frame(height: 190)
            }
            .padding(24)
        }
    }

    private func steps(for session: Session) -> [PipelineStep] {
        model.pipelineSteps[session.id] ?? []
    }

    private func progressStat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
            Text(value).font(.data(20, weight: .bold)).foregroundStyle(color)
        }
    }

    private func progressText(for session: Session) -> String {
        if case .segmenting(let progress) = session.status {
            return "\(Int(progress * 100))%"
        }
        return "0%"
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
    }
}

#Preview {
    ContentView()
}
