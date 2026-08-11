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

    private var analyses: [ParkingAnalysis] {
        model.parkingAnalyses[session.id] ?? []
    }

    private var analysis: ParkingAnalysis? {
        guard let selectedAnalysisID else { return analyses.first }
        return analyses.first { $0.id == selectedAnalysisID } ?? analyses.first
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
                VehicleCandidatesCanvasView(analysis: analysis, selectedVehicleID: $selectedVehicleID, showAllVehicles: false)
                    .padding(24)
                    .frame(minWidth: 360, maxWidth: 480)

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
    }

    @ViewBuilder
    private var videoArea: some View {
        if let player {
            AVPlayerContainerView(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else if isLoadingVideo {
            ProgressView("Memuat video…")
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            ContentUnavailableView("Video tidak tersedia", systemImage: "video.slash",
                                   description: Text("Berkas video sumber untuk sesi ini tidak ditemukan."))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
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
    }

    private func seekToSelectedAnalysis() {
        guard let player, let seconds = analysis?.sessionRelativeSeconds else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
