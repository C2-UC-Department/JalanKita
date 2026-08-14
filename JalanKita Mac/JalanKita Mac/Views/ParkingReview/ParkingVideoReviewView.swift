//
//  ParkingVideoReviewView.swift
//  JalanKita Mac
//
//  Tinjauan Parkir, reached per-session from Session Inbox's "Buka video"
//  action rather than a standalone sidebar destination — Session Inbox is
//  already the one place sessions are browsed from, so this screen doesn't
//  duplicate that with its own session list. Replaces the old static-image
//  candidate review with an actual video player: `ParkingTimelineView`'s
//  markers (unchanged from the previous pass) both seek the player and
//  drive the metrics panel, instead of only selecting a still frame.
//
//  Selecting a marker seeks the player, but playback itself never writes
//  back to `selectedAnalysisID` — a periodic time-observer driving that
//  would fight the seek it just performed (every tick re-seeking to the
//  "current" marker instead of letting playback advance), so the highlight
//  only follows explicit taps, same as the old candidate-strip pattern.
//
//  There IS a separate periodic time-observer, for the flagged vehicle's
//  bounding-box overlay drawn directly on the video — its box is only
//  correct at the exact detected frame, so it's shown only while playback
//  sits within a small tolerance of that timestamp and fades out the
//  moment the reviewer scrubs or plays away. This observer only ever
//  toggles that visibility flag, never seeks or touches selection, so it
//  can't reintroduce the fight described above.
//
//  The video surface is `AVPlayerView` (AppKit, via `NSViewRepresentable`),
//  NOT SwiftUI's `VideoPlayer` — confirmed by a real crash log that
//  `VideoPlayer` aborts on this project with a Swift metadata-initialization
//  failure inside `_AVKit_SwiftUI`, its private backing overlay. `AVPlayerView`
//  is the much older, plain-AppKit class the overlay itself ultimately wraps,
//  and doesn't go through whatever's failing there.
//
//  Since road damage became stage 3 of this pipeline, this screen shows BOTH
//  verticals against one video, on one shared timeline (`ParkingTimelineView`
//  draws both a vertical's ticks — magenta for parking, red for road damage —
//  on the same line, positioned by the same `sessionRelativeSeconds` axis).
//  They still keep separate selections (`selectedAnalysisID`/`selectedFrameID`),
//  since the underlying results are two distinct lists measured at different
//  frames for different reasons — but there's no manual tab anymore. Whichever
//  marker was tapped most recently (`lastSelectionKind`) decides which strip,
//  which on-video overlay, and which right-hand pane show.
//

import AppKit
import AVKit
import SwiftUI
import JalanKitaKit

struct ParkingVideoReviewView: View {
    let session: Session
    var model: AppModel

    /// Which vertical's marker was tapped most recently — decides which strip,
    /// which on-video overlay, and which right-hand pane show. No manual toggle:
    /// the timeline itself carries both verticals' ticks on one line, and tapping
    /// either kind of tick is what switches this.
    private enum SelectionKind: Equatable {
        case vehicle, damage
    }

    @State private var lastSelectionKind: SelectionKind = .vehicle
    @State private var player: AVPlayer?
    @State private var isLoadingVideo = true
    @State private var selectedAnalysisID: ParkingAnalysis.ID?
    @State private var selectedVehicleID: Int?
    @State private var selectedFrameID: ReviewFrame.ID?
    @State private var isNearSelectedTimestamp = true
    @State private var isNearSelectedFrame = false
    @State private var timeObserverToken: Any?

    private var analyses: [ParkingAnalysis] {
        model.parkingAnalyses[session.id] ?? []
    }

    private var damageFrames: [ReviewFrame] {
        model.roadDamageFrames[session.id] ?? []
    }

    private var damageFrame: ReviewFrame? {
        guard let selectedFrameID else { return nil }
        return damageFrames.first { $0.id == selectedFrameID }
    }

    private var analysis: ParkingAnalysis? {
        guard let selectedAnalysisID else { return analyses.first }
        return analyses.first { $0.id == selectedAnalysisID } ?? analyses.first
    }

    private var selectedVehicle: VehicleSummary? {
        analysis?.summary.vehicles.first { $0.id == selectedVehicleID }
    }

    /// The extracted screenshot's own aspect ratio — same frame the video's
    /// pixels come from, so the bounding-box overlay's normalized rect
    /// lines up with what's actually on screen.
    private var videoAspectRatio: CGFloat {
        guard let analysis, analysis.imageHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(analysis.imageWidth) / CGFloat(analysis.imageHeight)
    }

    /// One axis for both verticals, so a damage tick and a parking tick at the same
    /// x really are the same moment in the footage.
    private var totalSeconds: Double {
        session.durationSeconds
            ?? (analyses.compactMap(\.sessionRelativeSeconds)
                + damageFrames.compactMap(\.sessionRelativeSeconds)).max()
            ?? 0
    }

    /// Only worth showing once there's more than one timestamp to compare —
    /// same reasoning as the previous pass's `ParkingReviewView`.
    private var showsTimeline: Bool {
        analyses.compactMap(\.sessionRelativeSeconds).count > 1
    }

    private var showsDamageTimeline: Bool {
        damageFrames.compactMap(\.sessionRelativeSeconds).count > 1
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                videoArea
                if showsTimeline || showsDamageTimeline {
                    ParkingTimelineView(analyses: analyses, damageFrames: damageFrames, totalSeconds: totalSeconds,
                                        selectedAnalysisID: $selectedAnalysisID, selectedFrameID: $selectedFrameID,
                                        onSelectAnalysis: { selectAnalysis($0) },
                                        onSelectFrame: { selectFrame($0) })
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                switch lastSelectionKind {
                case .vehicle:
                    ParkingCandidateStripView(analyses: analyses, selectedAnalysisID: $selectedAnalysisID)
                case .damage:
                    RoadDamageFrameStripView(frames: damageFrames, selectedFrameID: $selectedFrameID)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity)

            switch lastSelectionKind {
            case .vehicle:
                if let analysis {
                    // The detected-vehicle frame used to have its own pane here
                    // — it now lives at the top of ParkingMetricsPanel's BEV
                    // section instead, so the video player (left) is free to
                    // use the space this pane used to take.
                    ParkingMetricsPanel(analysis: analysis, selectedVehicleID: selectedVehicleID)
                }
            case .damage:
                if let damageFrame {
                    RoadDamagePanel(frame: damageFrame)
                }
            }
        }
        .navigationTitle(session.roadName)
        .navigationSubtitle(subtitle)
        .task {
            selectedAnalysisID = analyses.first?.id
            selectedFrameID = damageFrames.first { !$0.findings.isEmpty }?.id ?? damageFrames.first?.id
            await loadPlayer()
        }
        .onChange(of: selectedAnalysisID) { _, _ in
            // Same "pipeline already knows which vehicle" default as the
            // previous pass — no manual tap needed to pick a vehicle.
            selectedVehicleID = analysis?.bestMatchVehicleID
            lastSelectionKind = .vehicle
            seekToSelectedAnalysis()
        }
        .onChange(of: selectedVehicleID) { _, newValue in
            guard let analysisID = analysis?.id else { return }
            Task { await model.selectParkingVehicle(sessionID: session.id, analysisID: analysisID, vehicleID: newValue) }
        }
        .onChange(of: selectedFrameID) { _, _ in
            // Picking a damage tick switches the pane to it — otherwise the click
            // would seek the video while the right-hand side still described a car.
            lastSelectionKind = .damage
            seekToSelectedFrame()
        }
        .onDisappear {
            if let player, let timeObserverToken {
                player.removeTimeObserver(timeObserverToken)
            }
        }
    }

    private var subtitle: String {
        let damaged = damageFrames.filter { !$0.findings.isEmpty }.count
        guard !damageFrames.isEmpty else { return "\(analyses.count) kendaraan terdeteksi" }
        return "\(analyses.count) kendaraan · \(damaged) dari \(damageFrames.count) frame berisi kerusakan"
    }

    @ViewBuilder
    private var videoArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let player {
                    AVPlayerContainerView(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if isLoadingVideo {
                    ProgressView("Memuat video…")
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ContentUnavailableView("Video tidak tersedia", systemImage: "video.slash",
                                           description: Text("Berkas video sumber untuk sesi ini tidak ditemukan."))
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if lastSelectionKind == .vehicle, isNearSelectedTimestamp, let analysis, let selectedVehicle {
                    let rect = ParkingMetrics.normalizedRect(for: selectedVehicle, imageWidth: analysis.imageWidth,
                                                             imageHeight: analysis.imageHeight)
                    if rect.width > 0, rect.height > 0 {
                        DetectedVehicleOverlay(vehicle: selectedVehicle)
                            .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                            .position(x: (rect.minX + rect.width / 2) * geo.size.width,
                                     y: (rect.minY + rect.height / 2) * geo.size.height)
                    }
                }

                // Same proximity rule as the vehicle box, and for the same reason:
                // these boxes are only correct at the exact sampled frame. At the
                // 5 s default the playhead is off that frame far more often than
                // on it, so drawing them continuously would put a pothole outline
                // over whatever happens to be on screen.
                if lastSelectionKind == .damage, isNearSelectedFrame, let damageFrame {
                    ForEach(damageFrame.findings) { finding in
                        let rect = finding.frameRect
                        if rect.width > 0, rect.height > 0 {
                            RoadDamageFindingOverlay(finding: finding)
                                .frame(width: rect.width * geo.size.width,
                                       height: rect.height * geo.size.height)
                                .position(x: (rect.minX + rect.width / 2) * geo.size.width,
                                          y: (rect.minY + rect.height / 2) * geo.size.height)
                        }
                    }
                }
            }
        }
        .aspectRatio(videoAspectRatio, contentMode: .fit)
    }

    private func loadPlayer() async {
        guard let asset = await SessionVideoAssetBuilder.buildPlayableAsset(for: session) else {
            isLoadingVideo = false
            return
        }
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = newPlayer
        isLoadingVideo = false
        seekToSelectedAnalysis()

        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            if let target = self.analysis?.sessionRelativeSeconds {
                self.isNearSelectedTimestamp = abs(time.seconds - target) < 0.5
            } else {
                self.isNearSelectedTimestamp = false
            }
            if let target = self.damageFrame?.sessionRelativeSeconds {
                self.isNearSelectedFrame = abs(time.seconds - target) < 0.5
            } else {
                self.isNearSelectedFrame = false
            }
        }
    }

    /// Fired directly by a timeline tap (see `ParkingTimelineView.onSelectAnalysis`)
    /// so re-tapping the already-selected marker still switches the pane/strip and
    /// re-seeks — `.onChange(of: selectedAnalysisID)` below only fires on an actual
    /// value change, which a re-tap of the current selection isn't.
    private func selectAnalysis(_ analysis: ParkingAnalysis) {
        lastSelectionKind = .vehicle
        seekToSeconds(analysis.sessionRelativeSeconds)
    }

    private func selectFrame(_ frame: ReviewFrame) {
        lastSelectionKind = .damage
        seekToSeconds(frame.sessionRelativeSeconds)
    }

    private func seekToSelectedAnalysis() {
        seekToSeconds(analysis?.sessionRelativeSeconds)
    }

    private func seekToSelectedFrame() {
        seekToSeconds(damageFrame?.sessionRelativeSeconds)
    }

    private func seekToSeconds(_ seconds: Double?) {
        guard let player, let seconds else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// One finding's box on the video, coloured by defect type — the same colour
/// language `DefectSwatch` uses in the panel beside it, so a reviewer matches a
/// box to a row by colour rather than by counting.
///
/// Per ADR-015 this vertical ships boxes, not masks: `Finding` has no mask field
/// and drawing a smooth outline here would imply a precision the detector does not
/// have.
private struct RoadDamageFindingOverlay: View {
    let finding: Finding

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(finding.defectType.color, lineWidth: 2)
            .shadow(color: finding.defectType.color.opacity(0.5), radius: 6)
            .allowsHitTesting(false)
    }
}

/// The flagged vehicle's box, drawn directly on the video instead of a
/// separate still-frame canvas (the old `VehicleCandidatesCanvasView`,
/// removed once nothing referenced it anymore) — view-only (no tap/
/// selection, no number tag), `Color.parkingMarker` (magenta) for "this is
/// the current selection," the same hue the shared timeline uses for every
/// parking-disturbance tick.
private struct DetectedVehicleOverlay: View {
    let vehicle: VehicleSummary

    private var color: Color { .parkingMarker }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: 2.5)
        }
        .shadow(color: color.opacity(0.6), radius: 8)
        .allowsHitTesting(false)
    }
}

/// Plain-AppKit `AVPlayerView`, not SwiftUI's `VideoPlayer` — see this
/// file's header comment.
private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
