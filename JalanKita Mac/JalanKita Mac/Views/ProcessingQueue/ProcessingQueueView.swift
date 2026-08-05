//
//  ProcessingQueueView.swift
//  JalanKita Mac
//
//  Operator console for the pipeline in Appendix C. The queue list is now
//  a real `List(selection:)` instead of a ScrollView of manually-tapped
//  rows — selection, hover, and keyboard up/down navigation all come from
//  the framework instead of being reimplemented with @State.
//
//  "Unggah foto…" is the entry point for the real parking-disturbance
//  pipeline (AppModel.uploadImage). The picked file is copied into the
//  app's own sandbox container (FileManager.temporaryDirectory) before being
//  handed to AppModel/InferenceService: the security-scoped access
//  `.fileImporter` grants is only valid for reads made by this (sandboxed)
//  process, not for the separate disturbance-worker subprocess that will
//  eventually open the path — staging a plain copy sidesteps that instead
//  of trying to extend sandbox access to a child process.
//

import SwiftUI
import UniformTypeIdentifiers

struct ProcessingQueueView: View {
    var model: AppModel

    @State private var selection: Session.ID?
    @State private var showingImporter = false
    @State private var importError: String?

    private var queue: [Session] { model.queuedSessions }

    private var active: Session? {
        queue.first { $0.id == selection } ?? queue.first
    }

    var body: some View {
        HSplitView {
            List(queue, selection: $selection) { session in
                QueueRow(session: session)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                todaySummary
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            if let active {
                detail(for: active)
                    .frame(minWidth: 500)
            } else {
                ContentUnavailableView("Antrean kosong", systemImage: "tray")
                    .frame(minWidth: 500)
            }
        }
        .navigationTitle("Antrean pemrosesan")
        .navigationSubtitle("\(queue.filter(isRunning).count) berjalan · \(queue.count - queue.filter(isRunning).count) menunggu")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Unggah foto…", systemImage: "photo.badge.plus")
                }
            }
            ToolbarItem { Button("Jeda antrean") {} }
            ToolbarItem { Button("Log lengkap") {} }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image]) { result in
            handleImport(result)
        }
        .alert("Unggah gagal", isPresented: .constant(importError != nil), presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { message in
            Text(message)
        }
        .onAppear {
            if selection == nil { selection = queue.first?.id }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let pickedURL):
            guard pickedURL.startAccessingSecurityScopedResource() else {
                importError = "Tidak bisa mengakses berkas yang dipilih."
                return
            }
            defer { pickedURL.stopAccessingSecurityScopedResource() }
            do {
                let staged = try Self.stageForWorker(pickedURL)
                model.uploadImage(url: staged)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Copies the picked photo into `FileManager.temporaryDirectory` (inside
    /// the app's own sandbox container) so `InferenceService`'s subprocess
    /// worker can open it by a plain path — see the type-level doc comment.
    private static func stageForWorker(_ sourceURL: URL) throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let destination = stagingDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func isRunning(_ session: Session) -> Bool {
        if case .segmenting = session.status { return true }
        return false
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "HARI INI")
            todayStat("Sesi selesai", "4")
            todayStat("Frame dinilai", "958")
            todayStat("Waktu komputasi", "3 j 12 m")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
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
                    progressStat("SISA", "38 mnt", color: .primary)
                    progressStat("LAJU", "1,04 f/d", color: .primary)
                    Spacer()
                }

                VStack(spacing: 10) {
                    ForEach(model.pipelineSteps) { step in
                        PipelineStepRow(step: step)
                    }
                }

                LogConsoleView(lines: model.logLines)
                    .frame(height: 190)
            }
            .padding(24)
        }
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
