//
//  VideoDetectionView.swift
//  JalanKita Mac
//
//  A dedicated screen for the video -> v13 -> OFRSNet flow: upload action and
//  its result live together here, instead of split across Antrean (progress)
//  and Tinjauan Parkir (result) the way an earlier version worked. That split
//  made "is this still processing?" genuinely hard to answer by looking at
//  the app -- this screen's "HASIL PEMROSESAN TERBARU" section always shows
//  ONE of three unambiguous states for the most recent upload: still
//  processing (with live step progress), done (with the actual result), or
//  failed (with the reason) -- never a stale/ambiguous result sitting there
//  with no indication of whether it's current.
//
//  Reuses ParkingCandidateStripView/VehicleCandidatesCanvasView/
//  ParkingMetricsPanel as-is (built for ParkingReviewView, but they only ever
//  needed `analysis`/`analyses` + selection bindings, nothing ParkingReview-
//  specific) rather than duplicating that rendering here.
//

import SwiftUI
import UniformTypeIdentifiers
import JalanKitaKit

struct VideoDetectionView: View {
    var model: AppModel

    @State private var showingImporter = false
    @State private var importError: String?
    @State private var selectedAnalysisID: ParkingAnalysis.ID?
    @State private var selectedVehicleID: Int?

    private var latestSession: Session? {
        guard let id = model.latestVideoSessionID else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private var latestAnalyses: [ParkingAnalysis] {
        guard let id = model.latestVideoSessionID else { return [] }
        return model.parkingAnalyses[id] ?? []
    }

    private var selectedAnalysis: ParkingAnalysis? {
        guard let selectedAnalysisID else { return latestAnalyses.first }
        return latestAnalyses.first { $0.id == selectedAnalysisID } ?? latestAnalyses.first
    }

    var body: some View {
        // ScrollView, not a plain VStack: the result row (candidate strip +
        // canvas + metrics panel, each with their own minimum sizes) can
        // need more height than a smaller window has -- without a ScrollView
        // absorbing that overflow, SwiftUI instead raises the WINDOW's own
        // minimum size to fit everything, which is why the window couldn't
        // be resized/minimized smaller and nothing was scrollable to see the
        // rest. Every pane below still sizes and scrolls internally as before
        // when there's room; this is only the fallback for when there isn't.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Unggah video dashcam untuk dideteksi otomatis: mobil yang diklasifikasikan PARKED "
                     + "dianalisis satu per satu untuk mengukur seberapa mengganggu parkirnya.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                resultSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Unggah Video")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Unggah video…", systemImage: "video.badge.plus")
                }
                .disabled(model.isVideoProcessing)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.movie]) { result in
            handleImport(result)
        }
        .alert("Unggah gagal", isPresented: .constant(importError != nil), presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { message in
            Text(message)
        }
        .onChange(of: model.latestVideoSessionID) { _, _ in
            selectedAnalysisID = nil
        }
        // `.task(id:)`, not `.onChange`: selectedAnalysisID starts and often
        // stays nil here (selectedAnalysis falls back to latestAnalyses.first
        // rather than ever assigning it explicitly, unlike Tinjauan Parkir's
        // `.task { selectedSessionID = ... }`), so an onChange keyed to it
        // would never fire on first load and selectedVehicleID would stay nil
        // forever -- which, combined with showAllVehicles: false below,
        // rendered nothing and left every stat blank.
        .task(id: selectedAnalysis?.id) {
            selectedVehicleID = selectedAnalysis?.bestMatchVehicleID
        }
        .onChange(of: selectedVehicleID) { _, newValue in
            guard let sessionID = model.latestVideoSessionID, let analysisID = selectedAnalysis?.id else { return }
            Task { await model.selectParkingVehicle(sessionID: sessionID, analysisID: analysisID, vehicleID: newValue) }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "HASIL PEMROSESAN TERBARU")

            if let latestSession {
                statusView(for: latestSession)
            } else {
                ContentUnavailableView("Belum ada video diunggah", systemImage: "video.badge.plus",
                                       description: Text("Klik \"Unggah video…\" di atas untuk memulai."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func statusView(for session: Session) -> some View {
        switch session.status {
        case .segmenting:
            processingStatus(roadName: session.roadName)
        case .done:
            if latestAnalyses.isEmpty {
                ContentUnavailableView(
                    "Tidak ada mobil terdeteksi", systemImage: "checkmark.circle",
                    description: Text("Selesai memproses \"\(session.roadName)\" tapi tidak menemukan "
                                      + "mobil yang diklasifikasikan PARKED di video ini.")
                )
            } else {
                doneResult
            }
        case .failed(let reason):
            Label {
                Text(reason)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(Severity.urgent.literalColor)
            .padding(14)
            .background(Severity.urgent.literalColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        default:
            EmptyView()
        }
    }

    private func processingStatus(roadName: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Masih diproses: \(roadName)", systemImage: "clock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 10) {
                ForEach(model.pipelineSteps) { step in
                    PipelineStepRow(step: step)
                }
            }
        }
    }

    private var doneResult: some View {
        HStack(alignment: .top, spacing: 0) {
            ParkingCandidateStripView(analyses: latestAnalyses, selectedAnalysisID: $selectedAnalysisID)

            if let selectedAnalysis {
                VehicleCandidatesCanvasView(analysis: selectedAnalysis, selectedVehicleID: $selectedVehicleID,
                                           showAllVehicles: false)
                    .padding(20)
                    .frame(minWidth: 360, maxWidth: .infinity)

                ParkingMetricsPanel(analysis: selectedAnalysis, selectedVehicleID: selectedVehicleID)
            }
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
                let staged = try Self.stageVideoForWorker(pickedURL)
                model.uploadVideo(url: staged)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Same sandbox-staging reasoning as ProcessingQueueView's own
    /// `stageForWorker` (for photos) -- read access `.fileImporter` grants
    /// is only valid for reads made by this sandboxed process, not the
    /// separate v13 subprocess that will actually open the path.
    private static func stageVideoForWorker(_ sourceURL: URL) throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = stagingDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }
}

#Preview {
    ContentView()
}
