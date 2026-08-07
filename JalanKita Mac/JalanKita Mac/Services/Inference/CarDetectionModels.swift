//
//  CarDetectionModels.swift
//  JalanKita Mac
//
//  Swift mirror of v13's demo_screenshots.py `_summary.json` -- the
//  car-detection-from-video stage that runs BEFORE OFRSNet. One JSON file per
//  processed video, written by pipeline_v13.py's `--screenshot-dir` into the
//  session's own working directory (not read over a pipe like the disturbance
//  worker's NDJSON -- see CarDetectionWorkerProcess's doc comment for why
//  this stage is a one-shot subprocess instead of a warm worker).
//

import Foundation

/// One car v13 classified as PARKED (its own STOP_CLASS bucket, including the
/// depth-tiebreak variant) -- a candidate photo for OFRSNet to score.
struct CarCandidate: Decodable, Identifiable {
    let trackID: Int
    let stopClass: String
    let disturbance: Bool
    let depthReading: String
    /// The MIDDLE frame of this car's observed span (farthest-to-nearest),
    /// not its first-seen frame -- the project owner's revised choice (an
    /// earlier version used the farthest/first frame). This is where `file`/
    /// `fileClean` were captured.
    let midFrame: Int
    let midSeconds: Double
    /// Annotated JPEG (box + label burned in) -- human review only.
    let file: String
    /// Unannotated JPEG -- what actually gets sent to OFRSNet. See
    /// demo_screenshots.py's write_screenshots() doc comment for why the
    /// annotated version must never be fed to a segmentation model.
    let fileClean: String

    var id: Int { trackID }

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case stopClass = "stop_class"
        case disturbance
        case depthReading = "depth_reading"
        case midFrame = "mid_frame"
        case midSeconds = "mid_seconds"
        case file
        case fileClean = "file_clean"
    }
}

/// Mirrors demo_screenshots.py's `_summary.json` top level.
struct CarDetectionSummary: Decodable {
    let sourceVideo: String
    let outputVideo: String
    let carsDetectedParked: [CarCandidate]

    enum CodingKeys: String, CodingKey {
        case sourceVideo = "source_video"
        case outputVideo = "output_video"
        case carsDetectedParked = "cars_detected_parked"
    }
}
