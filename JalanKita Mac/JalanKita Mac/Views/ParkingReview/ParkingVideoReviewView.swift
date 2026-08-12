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

import AppKit
import AVKit
import SwiftUI
import JalanKitaKit

struct ParkingVideoReviewView: View {
    let session: Session
    var model: AppModel

    @State private var player: AVPlayer?
    @State private var isLoadingVideo = true
    @State private var selectedAnalysisID: ParkingAnalysis.ID?
    @State private var selectedVehicleID: Int?
    @State private var isNearSelectedTimestamp = true
    @State private var timeObserverToken: Any?

    private var analyses: [ParkingAnalysis] {
        model.parkingAnalyses[session.id] ?? []
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

    private var totalSeconds: Double {
        session.durationSeconds ?? analyses.compactMap(\.sessionRelativeSeconds).max() ?? 0
    }

    /// Only worth showing once there's more than one timestamp to compare —
    /// same reasoning as the previous pass's `ParkingReviewView`.
    private var showsTimeline: Bool {
        analyses.compactMap(\.sessionRelativeSeconds).count > 1
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                videoArea
                if showsTimeline {
                    ParkingTimelineView(analyses: analyses, totalSeconds: totalSeconds,
                                        selectedAnalysisID: $selectedAnalysisID)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                ParkingCandidateStripView(analyses: analyses, selectedAnalysisID: $selectedAnalysisID)
            }
            .frame(minWidth: 480, maxWidth: .infinity)

            if let analysis {
                // The detected-vehicle frame used to have its own pane here
                // — it now lives at the top of ParkingMetricsPanel's BEV
                // section instead, so the video player (left) is free to
                // use the space this pane used to take.
                ParkingMetricsPanel(analysis: analysis, selectedVehicleID: selectedVehicleID)
            }
        }
        .navigationTitle(session.roadName)
        .navigationSubtitle("\(analyses.count) kendaraan terdeteksi")
        .task {
            selectedAnalysisID = analyses.first?.id
            await loadPlayer()
        }
        .onChange(of: selectedAnalysisID) { _, _ in
            // Same "pipeline already knows which vehicle" default as the
            // previous pass — no manual tap needed to pick a vehicle.
            selectedVehicleID = analysis?.bestMatchVehicleID
            seekToSelectedAnalysis()
        }
        .onChange(of: selectedVehicleID) { _, newValue in
            guard let analysisID = analysis?.id else { return }
            Task { await model.selectParkingVehicle(sessionID: session.id, analysisID: analysisID, vehicleID: newValue) }
        }
        .onDisappear {
            if let player, let timeObserverToken {
                player.removeTimeObserver(timeObserverToken)
            }
        }
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

                if isNearSelectedTimestamp, let analysis, let selectedVehicle {
                    let rect = ParkingMetrics.normalizedRect(for: selectedVehicle, imageWidth: analysis.imageWidth,
                                                             imageHeight: analysis.imageHeight)
                    if rect.width > 0, rect.height > 0 {
                        DetectedVehicleOverlay(vehicle: selectedVehicle)
                            .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                            .position(x: (rect.minX + rect.width / 2) * geo.size.width,
                                     y: (rect.minY + rect.height / 2) * geo.size.height)
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
            guard let target = self.analysis?.sessionRelativeSeconds else {
                self.isNearSelectedTimestamp = false
                return
            }
            self.isNearSelectedTimestamp = abs(time.seconds - target) < 0.5
        }
    }

    private func seekToSelectedAnalysis() {
        guard let player, let seconds = analysis?.sessionRelativeSeconds else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// The flagged vehicle's box, drawn directly on the video instead of a
/// separate still-frame canvas (the old `VehicleCandidatesCanvasView`,
/// removed once nothing referenced it anymore) — view-only (no tap/
/// selection, no number tag), magenta for "this is the current selection,"
/// the same color language that view used for the same concept.
private struct DetectedVehicleOverlay: View {
    let vehicle: VehicleSummary

    private var color: Color { Color(red: 1.0, green: 0, blue: 0.78) }

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
