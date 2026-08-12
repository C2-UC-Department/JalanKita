//
//  SessionInboxView.swift
//  JalanKita Mac
//
//  §6.2/Appendix C landing screen. Rewritten around `Table`, which is the
//  idiomatic macOS component for this content: it gives us sortable,
//  resizable columns, native row selection, and keyboard navigation for
//  free — the previous version hand-built a fixed-width HStack "table"
//  inside a ScrollView, which had none of that and made selection state
//  fragile (row taps and the checkbox each raced to mutate `sessions` by
//  whole-struct equality lookup).
//

import SwiftUI
import UniformTypeIdentifiers
import JalanKitaKit

struct SessionInboxView: View {
    @Bindable var model: AppModel

    @State private var selection: Session.ID?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\Session.roadName)]
    @State private var showingPhotoImporter = false
    @State private var showingVideoImporter = false
    @State private var importError: String?
    @State private var pendingDeletionID: Session.ID?

    private var filteredSessions: [Session] {
        let base = searchText.isEmpty
            ? model.sessions
            : model.sessions.filter {
                $0.roadName.localizedCaseInsensitiveContains(searchText) ||
                $0.surveyor.name.localizedCaseInsensitiveContains(searchText)
            }
        return base.sorted(using: sortOrder)
    }

    private var selectedSession: Session? {
        model.sessions.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "Belum ada sesi", systemImage: "tray",
                    description: Text("Sesi akan muncul di sini setelah surveyor menyinkronkan rekaman dari iPhone, atau unggah foto/video secara manual lewat menu \"Unggah…\" di atas.")
                )
            } else {
                HSplitView {
                    table
                        .frame(minWidth: 560)

                    if let selectedSession {
                        SessionDetailPanel(session: selectedSession, model: model)
                            .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Cari jalan atau surveyor")
        .navigationTitle("Sesi masuk")
        .navigationSubtitle("\(model.newSessionsCount) baru · \(formattedGB(model.totalSizeGB)) GB total")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    processBatch()
                } label: {
                    Label("Proses \(model.batchSelectedCount) sesi", systemImage: "checkmark")
                }
                .disabled(model.batchSelectedCount == 0)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Foto…") { showingPhotoImporter = true }
                    Button("Video…") { showingVideoImporter = true }
                } label: {
                    Label("Unggah…", systemImage: "square.and.arrow.up")
                }
            }
        }
        .fileImporter(isPresented: $showingPhotoImporter, allowedContentTypes: [.image]) { result in
            handlePhotoImport(result)
        }
        .fileImporter(isPresented: $showingVideoImporter, allowedContentTypes: [.movie]) { result in
            handleVideoImport(result)
        }
        .alert("Unggah gagal", isPresented: .constant(importError != nil), presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { message in
            Text(message)
        }
        .alert("Hapus sesi ini?", isPresented: .constant(pendingDeletionID != nil), presenting: pendingDeletionID) { id in
            Button("Hapus", role: .destructive) {
                model.deleteSession(id)
                pendingDeletionID = nil
            }
            Button("Batal", role: .cancel) { pendingDeletionID = nil }
        } message: { _ in
            Text("Video dan hasil analisis sesi ini akan dihapus permanen dari Mac ini.")
        }
        .onAppear {
            if selection == nil { selection = filteredSessions.first?.id }
        }
    }

    private func formattedGB(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
    }

    private func handlePhotoImport(_ result: Result<URL, Error>) {
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
                let staged = try Self.stagePhotoForWorker(pickedURL)
                model.uploadImage(url: staged)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func handleVideoImport(_ result: Result<URL, Error>) {
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
                let staged = try Self.stageVideoForWorker(pickedURL)
                model.uploadVideo(url: staged)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Copies the picked photo into `FileManager.temporaryDirectory` (inside
    /// the app's own sandbox container) so `InferenceService`'s subprocess
    /// worker can open it by a plain path — the security-scoped access
    /// `.fileImporter` grants is only valid for reads made by this
    /// (sandboxed) process, not the separate worker subprocess.
    private static func stagePhotoForWorker(_ sourceURL: URL) throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let destination = stagingDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Same sandbox-staging reasoning as `stagePhotoForWorker`, for the v13
    /// car-detection subprocess instead of the disturbance worker.
    private static func stageVideoForWorker(_ sourceURL: URL) throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = stagingDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Pinned above the table via `.safeAreaInset`, not stacked as a
    /// `VStack` sibling in front of it. `Table` (like `List`) wants to own
    /// the full height of whatever contains it; putting a fixed-height
    /// header in a plain `VStack` alongside it — inside an `HSplitView`
    /// pane, which negotiates each pane's size from its content's
    /// reported ideal size — left the layout system unable to tell the
    /// header "you're fixed-height, the table is flexible," and it
    /// resolved that ambiguity by handing the *header's* HStack far more
    /// height than its content needed. Since the header's own `Divider()`
    /// views fill whatever cross-axis height their HStack is given, they
    /// visibly stretched down the whole pane. `.safeAreaInset` sidesteps
    /// the ambiguity entirely: the table measures itself first and gets
    /// full control of the pane, the inset content is measured at its own
    /// natural size and pinned above it.
    private var statRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatTile(title: "MENUNGGU DIPROSES", value: "\(model.newSessionsCount)", unit: "sesi")
                Divider()
                StatTile(title: "TOTAL SESI", value: "\(model.sessions.count)", unit: nil,
                         detail: "\(model.surveyorCount) surveyor")
                Divider()
                StatTile(title: "JARAK TERSURVEI", value: formattedGB(model.totalDistanceKm), unit: "km",
                         detail: "\(model.doneSessionsCount) sesi selesai")
                Divider()
                StatTile(title: "PARKIR MENGGANGGU", value: "\(model.disturbanceCount)", unit: nil,
                         detail: "kendaraan terdeteksi", accent: Severity.urgent.literalColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
        }
        .background(.background)
    }

    private var table: some View {
        Table(filteredSessions, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { session in
                Toggle("Sertakan dalam batch", isOn: batchBinding(for: session))
                    .labelsHidden()
            }
            .width(32)

            TableColumn("Jalan / Sesi", value: \.roadName) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.roadName).fontWeight(.semibold)
                    Text(subtitle(for: session))
                        .font(.caption)
                        .foregroundStyle(session.gpsGapNote != nil ? .red : .secondary)
                }
            }
            .width(min: 200, ideal: 240)

            TableColumn("Surveyor", value: \.surveyor.name)
                .width(min: 100, ideal: 130)

            TableColumn("Durasi", value: \.duration) { session in
                Text(session.duration).font(.data(12))
            }
            .width(80)

            TableColumn("Jarak", value: \.distanceKm) { session in
                measurement(session.distanceKm, unit: "km")
            }
            .width(80)

            TableColumn("Jejak GPS") { session in
                gpsTrack(for: session)
            }
            .width(100)

            TableColumn("Ukuran", value: \.sizeGB) { session in
                measurement(session.sizeGB, unit: "GB")
            }
            .width(80)

            TableColumn("Status") { session in
                SessionStatusBadge(status: session.status)
            }
            .width(min: 110, ideal: 140)
        }
        .safeAreaInset(edge: .top, spacing: 0) { statRow }
        .contextMenu(forSelectionType: Session.ID.self) { ids in
            if let id = ids.first {
                Button("Hapus sesi…", role: .destructive) {
                    pendingDeletionID = id
                }
            }
        }
        .onDeleteCommand {
            if let selection { pendingDeletionID = selection }
        }
    }

    private func measurement(_ value: Double, unit: String) -> some View {
        HStack(spacing: 2) {
            Text(value, format: .number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(1)))
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.data(12))
    }

    private func subtitle(for session: Session) -> String {
        var parts = [session.date, "\(session.clipCount) klip"]
        if let segmentCount = session.segmentCount { parts.append("\(segmentCount) segmen") }
        if let gap = session.gpsGapNote { parts.append(gap) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func gpsTrack(for session: Session) -> some View {
        if let acc = session.gpsAccuracyM, let hz = session.gpsHz {
            Text("±\(acc) m · \(Int(hz)) Hz").font(.data(12)).foregroundStyle(.green)
        } else if session.gpsGapNote != nil {
            Text("bolong").font(.data(12)).foregroundStyle(.red)
        } else {
            Text("—").font(.data(12)).foregroundStyle(.secondary)
        }
    }

    /// Looks the row up by its stable `id`, not by whole-struct equality —
    /// the previous `sessions.firstIndex(of: session)` broke as soon as two
    /// rows were value-equal, and re-ran a full struct comparison on every
    /// toggle.
    private func batchBinding(for session: Session) -> Binding<Bool> {
        guard let index = model.sessions.firstIndex(where: { $0.id == session.id }) else {
            return .constant(false)
        }
        return $model.sessions[index].selectedForBatch
    }

    private func processBatch() {
        for index in model.sessions.indices where model.sessions[index].selectedForBatch {
            if case .readyToProcess = model.sessions[index].status {
                model.startProcessing(sessionID: model.sessions[index].id)
            }
            model.sessions[index].selectedForBatch = false
        }
        model.selection = .queue
    }
}

#Preview {
    ContentView()
}
