//
//  FindingsMapView.swift
//  JalanKita Mac
//
//  Real-GPS counterpart to MapSegmentsView, which stays exactly as it was —
//  its `SegmentResult`/`RouteSampleCoordinates` data is still 100% sample,
//  and turning it real means designing road-segment aggregation (10 m
//  binning, combined severity) that doesn't exist anywhere in this codebase
//  yet. This view sidesteps that: it plots one marker per GPS-tagged
//  `ReviewFrame` — real GPS, interpolated in `video_frames.py` and threaded
//  through by `RoadDamageService`, no aggregation invented.
//
//  ⚠️ One marker per FRAME, not per finding. An earlier version plotted one
//  per `Finding`, which meant a clean stretch of road — the common case; the
//  detector under-fires by design (RoadDamage/README.md's "Known limits")
//  and a short demo clip may find nothing at all — showed no coverage on the
//  map whatsoever, indistinguishable from "GPS join failed". Tagging every
//  sampled frame instead means the whole surveyed route is visible, with
//  severity (not defect type) carrying the color: a clean frame still scores
//  and still tints `.ignore`, so "surveyed, nothing found" reads differently
//  from "not surveyed at all".
//
//  Parking-disturbance candidates share this map too, as a second, differently-
//  shaped pin (`DefectType.blockedPark`, whose own doc comment already calls it
//  "not a road defect, shares the overlay language"). They have no coordinate of
//  their own — `ParkingAnalysis` carries none — so one is derived here: a
//  recording-start anchor (a synced session's real `recordedDate`, or — for a
//  manual "Video + GPS" upload, which has no `recordedDate` — the video's own
//  `mvhd` creation time, read by `RoadDamageVideoProcess.extract` for every
//  session regardless and kept in `AppModel.manualUploadRecordingStart` for
//  exactly this) plus `sessionRelativeSeconds` gives an absolute timestamp,
//  nearest-matched against that session's own GPS track (`AppModel.gpsCSVURL`,
//  synced or manual, via `SessionGPSTrackLoader`). Same nearest-fixed-gap idea
//  as the road-damage join, one layer up because `ParkingAnalysis` has no
//  per-frame provenance CSV to carry a coordinate through.
//

import SwiftUI
import MapKit
import JalanKitaKit

private struct MappedFrame: Identifiable {
    let frame: ReviewFrame
    let coordinate: CLLocationCoordinate2D

    var id: String { frame.id }
}

private struct MappedParking: Identifiable {
    let analysis: ParkingAnalysis
    let coordinate: CLLocationCoordinate2D

    var id: String { analysis.id }
}

private enum MapPin: Hashable {
    case roadDamage(String)
    case parking(String)
}

struct FindingsMapView: View {
    var model: AppModel

    @State private var selection: MapPin?

    private var mappedFrames: [MappedFrame] {
        model.roadDamageFrames.values.flatMap { frames in
            frames.compactMap { frame -> MappedFrame? in
                guard let coordinate = Self.parseCoordinate(frame.coordinate) else { return nil }
                return MappedFrame(frame: frame, coordinate: coordinate)
            }
        }
    }

    /// A manual photo upload's `sessionRelativeSeconds` is nil (§ file header)
    /// and has no timeline to place on in the first place — everything else
    /// (video from a synced session OR a manual "Video + GPS" upload) qualifies,
    /// gated only by whether a recording-start anchor and a GPS track both exist
    /// for that session.
    private var mappedParkings: [MappedParking] {
        model.parkingAnalyses.values.flatMap { analyses in
            analyses.compactMap { analysis -> MappedParking? in
                guard let relSeconds = analysis.sessionRelativeSeconds,
                      let session = model.sessions.first(where: { $0.id == analysis.sessionID }),
                      let recordingStart = session.recordedDate ?? model.manualUploadRecordingStart[session.id]
                else { return nil }
                let candidateTime = recordingStart.addingTimeInterval(relSeconds)
                guard let coordinate = SessionGPSTrackLoader.nearestCoordinate(
                    sessionID: session.id, at: candidateTime) else { return nil }
                return MappedParking(analysis: analysis, coordinate: coordinate)
            }
        }
    }

    var body: some View {
        mapArea
            .navigationTitle("Peta temuan")
    }

    private var mapArea: some View {
        Map(initialPosition: .region(region), selection: $selection) {
            ForEach(mappedFrames) { mapped in
                Marker(markerTitle(for: mapped.frame), systemImage: mapped.frame.severity.symbolName,
                       coordinate: mapped.coordinate)
                    .tint(mapped.frame.severity.literalColor)
                    .tag(MapPin.roadDamage(mapped.frame.id))
            }
            ForEach(mappedParkings) { mapped in
                Marker(DefectType.blockedPark.label, systemImage: "parkingsign.circle.fill",
                       coordinate: mapped.coordinate)
                    .tint(DefectType.blockedPark.color)
                    .tag(MapPin.parking(mapped.analysis.id))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottomLeading) {
            switch selection {
            case .roadDamage(let id):
                if let frame = mappedFrames.first(where: { $0.id == id })?.frame {
                    FindingDetailCard(frame: frame) { self.selection = nil }
                        .padding(16)
                }
            case .parking(let id):
                if let analysis = mappedParkings.first(where: { $0.id == id })?.analysis {
                    ParkingDetailCard(analysis: analysis) { self.selection = nil }
                        .padding(16)
                }
            case nil:
                if mappedFrames.isEmpty && mappedParkings.isEmpty {
                    EmptyFindingsCard().padding(16)
                } else {
                    FindingsCountCard(frameCount: mappedFrames.count, parkingCount: mappedParkings.count)
                        .padding(16)
                }
            }
        }
    }

    /// "3 temuan" or "Bersih" — enough to scan the map without tapping every pin.
    private func markerTitle(for frame: ReviewFrame) -> String {
        frame.findings.isEmpty ? "Bersih" : "\(frame.findings.count) temuan"
    }

    /// Fits real coordinate bounds with a margin, falling back to
    /// `MapSegmentsView`'s own Surabaya overview region when there's nothing
    /// real to show yet (no session has a GPS-tagged frame or candidate).
    private var region: MKCoordinateRegion {
        let coordinates = mappedFrames.map(\.coordinate) + mappedParkings.map(\.coordinate)
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -7.278, longitude: 112.745),
                                      latitudinalMeters: 9000, longitudinalMeters: 9000)
        }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        // 1.6x the raw span plus a floor, so a single-point or tightly-clustered
        // track still shows enough surrounding road to be legible, not a blank tile.
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.004),
                                    longitudeDelta: max((lons.max()! - lons.min()!) * 1.6, 0.004))
        return MKCoordinateRegion(center: center, span: span)
    }

    /// `ReviewFrame.coordinate` is `"lat,lon"` — see `RoadDamageService.makeFrame`'s
    /// doc comment. Free-form by construction (the field predates any producer), so
    /// this is the one place that format is decided; nil for anything else.
    private static func parseCoordinate(_ raw: String?) -> CLLocationCoordinate2D? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Fixed, not a min/ideal/max range — `RoadDamagePanel`/`ParkingMetricsPanel`
/// declare their own `.frame(minWidth:...)` for their normal home (a
/// resizable side panel), but that range wasn't enough inside `Map`'s
/// `.overlay`: the overlay proposes the Map's own full size, and a photo with
/// no width of its own (`AsyncImage` at native aspect ratio) happily grew to
/// fill it — dragging the whole card, and the panel stretched inside it, to
/// nearly the window's full width and height instead of a small floating
/// card. Confirmed against a live screenshot, not theorized; a hard `width`
/// AND `height` here is what actually stops it, a `maxHeight` alone did not.
private let mapDetailCardWidth: CGFloat = 420
private let mapDetailCardHeight: CGFloat = 560
private let mapDetailPhotoHeight: CGFloat = 170

/// The whole frame behind the tapped pin: its photo, then `RoadDamagePanel`
/// verbatim — the same score-breakdown-plus-findings view the review screen
/// uses, so the map doesn't grow a second, divergent rendering of numbers
/// that already have one canonical display.
private struct FindingDetailCard: View {
    let frame: ReviewFrame
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            photo
            RoadDamagePanel(frame: frame)
        }
        .frame(width: mapDetailCardWidth, height: mapDetailCardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .shadow(radius: 10, y: 4)
    }

    private var photo: some View {
        AsyncImage(url: frame.imageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder(systemImage: "photo.badge.exclamationmark")
            default:
                placeholder(systemImage: "photo")
            }
        }
        .frame(width: mapDetailCardWidth, height: mapDetailPhotoHeight)
        .clipped()
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}

/// The parking-disturbance counterpart to `FindingDetailCard`: photo, then
/// `ParkingMetricsPanel` verbatim — same reasoning, one canonical display of
/// these numbers (Tinjauan Parkir's own right pane) rather than a second one
/// invented for the map.
private struct ParkingDetailCard: View {
    let analysis: ParkingAnalysis
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            photo
            ParkingMetricsPanel(analysis: analysis, selectedVehicleID: analysis.bestMatchVehicleID)
        }
        .frame(width: mapDetailCardWidth, height: mapDetailCardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .shadow(radius: 10, y: 4)
    }

    private var photo: some View {
        AsyncImage(url: analysis.imageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder(systemImage: "photo.badge.exclamationmark")
            default:
                placeholder(systemImage: "photo")
            }
        }
        .frame(width: mapDetailCardWidth, height: mapDetailPhotoHeight)
        .clipped()
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}

private struct FindingsCountCard: View {
    let frameCount: Int
    let parkingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TITIK BER-GPS")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("\(frameCount + parkingCount)")
                .font(.data(20, weight: .bold))
            Text("\(frameCount) frame jalan · \(parkingCount) parkir mengganggu")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EmptyFindingsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Belum ada frame ber-GPS")
                .font(.system(size: 13, weight: .semibold))
            Text("Unggah lewat \"Video + GPS (demo)…\" di Sesi masuk, atau tunggu sesi tersinkron dengan jejak GPS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    ContentView()
}
