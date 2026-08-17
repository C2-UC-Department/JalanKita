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
    @State private var importError: String?
    @State private var pendingDeletionID: Session.ID?

    // Single `.fileImporter` shared by every "Unggah…" menu item, dispatched by
    // `pendingImport`. Stacking several `.fileImporter` modifiers on one view (this
    // had 2, briefly grew to 4 while adding the GPS demo flow below) turned out to
    // silently break presentation for ALL of them, old and new alike — not just a
    // theoretical SwiftUI quirk, reproduced directly: the pre-existing "Video…" item
    // stopped opening its panel too. One importer + one dispatch enum is the fix,
    // and is also just a smaller surface than four independently-toggled booleans.
    private enum PendingImport {
        case photo
        case video
        /// First half of the demo "Video + GPS" pairing — see `handleImport`'s
        /// `.videoForGPS` case for how this transitions to `.gpsCSV`.
        case videoForGPS
        case gpsCSV(video: URL)
    }
    @State private var showingImporter = false
    @State private var pendingImport: PendingImport = .photo

    private var importerContentTypes: [UTType] {
        switch pendingImport {
        case .photo: [.image]
        case .video, .videoForGPS: [.movie]
        case .gpsCSV: [.commaSeparatedText, .plainText]
        }
    }

    private var filteredSessions: [Session] {
        let visible = model.sessions.filter { $0.status != .done }
        let base = searchText.isEmpty
            ? visible
            : visible.filter {
                $0.roadName.localizedCaseInsensitiveContains(searchText) ||
                $0.surveyor.name.localizedCaseInsensitiveContains(searchText)
            }
        return base.sorted(using: sortOrder)
    }

    private var selectedSession: Session? {
        model.sessions.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            table
                .frame(minWidth: 560)

            if let selectedSession {
                SessionDetailPanel(session: selectedSession, model: model)
                    .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
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
                    Button("Foto…") { pendingImport = .photo; showingImporter = true }
                    Button("Video…") { pendingImport = .video; showingImporter = true }
                    Button("Video + GPS (demo)…") { pendingImport = .videoForGPS; showingImporter = true }
                } label: {
                    Label("Unggah…", systemImage: "square.and.arrow.up")
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importerContentTypes) { result in
            handleImport(result)
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

    /// GB alone rounds any file under ~50 MB to a misleading "0,0" at the
    /// stat tiles' one-decimal precision — a single manually-uploaded photo
    /// or short video routinely falls in that range. Switching to MB below
    /// 1 GB keeps small, real sizes visible instead of reading as zero/broken.
    private func formattedSize(gb: Double) -> (value: String, unit: String) {
        if gb < 1 {
            let mb = gb * 1024
            return (mb.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(0))), "MB")
        }
        return (formattedGB(gb), "GB")
    }

    /// Same failure mode as `formattedSize(gb:)` above, same fix: a short
    /// segment or just-started session under ~50 m rounds to a misleading
    /// "0,0" at one-decimal km precision, so switch to metres below 1 km.
    private func formattedDistance(km: Double) -> (value: String, unit: String) {
        if km < 1 {
            let m = km * 1000
            return (m.formatted(.number.locale(Locale(identifier: "id_ID")).precision(.fractionLength(0))), "m")
        }
        return (formattedGB(km), "km")
    }

    /// Single completion handler for `showingImporter`, dispatched by whatever
    /// `pendingImport` was set to right before the panel opened.
    private func handleImport(_ result: Result<URL, Error>) {
        switch pendingImport {
        case .photo:
            withSecurityScopedAccess(result) { pickedURL in
                let staged = try Self.stagePhotoForWorker(pickedURL)
                model.uploadImage(url: staged)
            }
        case .video:
            withSecurityScopedAccess(result) { pickedURL in
                let staged = try Self.stageVideoForWorker(pickedURL)
                model.uploadVideo(url: staged)
            }
        case .videoForGPS:
            // First half of the demo pairing: stage the video, then re-open the SAME
            // importer for the companion CSV rather than uploading yet — the pairing
            // only completes once that second pick resolves.
            //
            // ⚠️ The re-presentation is deferred a run-loop tick on purpose. Flipping
            // `showingImporter` back to true synchronously, inside the completion
            // handler SwiftUI is still calling to dismiss THIS SAME panel, was tried
            // first and silently did nothing — SwiftUI hadn't yet finished applying
            // `isPresented = false` from the dismissal, so the immediate `= true`
            // collapsed into a no-op transition it never rendered. `DispatchQueue.
            // main.async` lets that dismissal complete first.
            withSecurityScopedAccess(result) { pickedURL in
                let staged = try Self.stageVideoForWorker(pickedURL)
                pendingImport = .gpsCSV(video: staged)
                DispatchQueue.main.async {
                    showingImporter = true
                }
            }
        case .gpsCSV(let video):
            // A cancelled/failed CSV pick is not an upload error — it just means
            // this session proceeds without GPS, same as the plain "Video…" flow.
            //
            // `startImmediately: false` — unlike the plain "Video…" flow above,
            // this one lands the session at `.readyToProcess` instead of
            // auto-starting, specifically so "Putar kiri/kanan" in the session's
            // own detail panel is reachable BEFORE processing burns through the
            // clip. See `AppModel.uploadVideo`'s doc comment.
            guard case .success(let pickedURL) = result,
                  pickedURL.startAccessingSecurityScopedResource() else {
                model.uploadVideo(url: video, startImmediately: false)
                return
            }
            defer { pickedURL.stopAccessingSecurityScopedResource() }
            model.uploadVideo(url: video, gpsCSVURL: pickedURL, startImmediately: false)
        }
    }

    /// Shared security-scoped-access dance every import branch above needs: grant
    /// access, run `body`, release access, and route any failure (including a
    /// denied grant) into `importError` uniformly.
    private func withSecurityScopedAccess(_ result: Result<URL, Error>,
                                          _ body: (URL) throws -> Void) {
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
                try body(pickedURL)
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
        let pendingSize = formattedSize(gb: model.pendingSizeGB)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatTile(title: "MENUNGGU DIPROSES", value: "\(model.newSessionsCount)", unit: "sesi")
                Divider()
                StatTile(title: "TOTAL SESI", value: "\(model.pendingSessionsCount)", unit: nil,
                         detail: "\(model.surveyorCount) surveyor")
                Divider()
                StatTile(title: "PERLU PERHATIAN", value: "\(model.attentionNeededCount)", unit: nil,
                         detail: "terdegradasi/gagal", accent: Severity.urgent.literalColor)
                Divider()
                StatTile(title: "UKURAN DATA", value: pendingSize.value, unit: pendingSize.unit)
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
                measurement(formattedDistance(km: session.distanceKm))
            }
            .width(80)

            TableColumn("Jejak GPS") { session in
                gpsTrack(for: session)
            }
            .width(100)

            TableColumn("Ukuran", value: \.sizeGB) { session in
                measurement(formattedSize(gb: session.sizeGB))
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

    private func measurement(_ formatted: (value: String, unit: String)) -> some View {
        HStack(spacing: 2) {
            Text(formatted.value)
            Text(formatted.unit).foregroundStyle(.secondary)
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
                // A "Video + GPS (demo)…" upload can sit at `.readyToProcess`
                // too now (§ `AppModel.uploadVideo`'s `startImmediately` doc
                // comment) — `startProcessing` would reject it for having no
                // CloudKit surveyor zone, so route by session kind same as
                // `SessionDetailPanel`'s "Proses sekarang".
                if model.sessions[index].recordedDate != nil {
                    model.startProcessing(sessionID: model.sessions[index].id)
                } else {
                    model.startManualVideoProcessing(sessionID: model.sessions[index].id)
                }
            }
            model.sessions[index].selectedForBatch = false
        }
        model.selection = .queue
    }
}

#Preview {
    ContentView()
}
