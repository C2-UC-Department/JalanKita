//
//  RoadDamageFrameProvenance.swift
//  JalanKita Mac
//
//  Decodes the GPS columns of `frames_provenance.csv` (written by
//  `video_frames.py extract()` beside the sampled frames) into a per-frame
//  coordinate lookup for `RoadDamageService.analyzeVideo` to attach to each
//  `ReviewFrame`. Deliberately separate from `SessionGPSTrackLoader`, which
//  parses a different, 3-column `time,lat,lon` track for the route polyline —
//  this one is keyed by frame filename, not time, and reads a CSV with 17
//  columns instead of 3.
//
//  Naive `,`-split, matching `SessionGPSTrackLoader`'s own convention for this
//  codebase's CSVs — none of `video_frames.py`'s string columns are expected
//  to contain a literal comma (filenames, "video"/"none"/"nearest", a date).
//

import Foundation

enum RoadDamageFrameProvenance {
    /// `frame_file` -> `"lat,lon"`, only for rows the extractor actually matched to a
    /// GPS fix (`gps_source != "none"`). Empty when the file is missing, unreadable, or
    /// no `--gps-csv` was given for this extraction — callers treat a missing entry the
    /// same as "no GPS for this frame", which is already `ReviewFrame.coordinate`'s
    /// existing nil case.
    static func loadCoordinates(provenanceCSV: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: provenanceCSV, encoding: .utf8) else {
            return [:]
        }

        // `whereSeparator: \.isNewline`, not `separator: "\n"`: Python's csv module
        // writes CRLF line endings, and Swift's `Character` treats `"\r\n"` as ONE
        // grapheme cluster — distinct from a bare `"\n"` Character. Splitting on
        // `"\n"` alone therefore never matches anything in this file and the whole
        // CSV collapses into a single "line", silently returning zero coordinates
        // for every frame. Confirmed live against a real extraction: every finding
        // in a GPS-tagged session came back with `coordinate == nil` until this
        // changed, no error anywhere in the chain.
        var lines = contents.split(whereSeparator: \.isNewline)[...]
        guard let header = lines.popFirst() else { return [:] }
        let columns = header.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0) }
        guard let frameFileIdx = columns.firstIndex(of: "frame_file"),
              let latIdx = columns.firstIndex(of: "lat"),
              let lonIdx = columns.firstIndex(of: "lon"),
              let sourceIdx = columns.firstIndex(of: "gps_source")
        else { return [:] }

        var coordinates: [String: String] = [:]
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0) }
            guard fields.count == columns.count,
                  fields[sourceIdx] != "none",
                  !fields[latIdx].isEmpty, !fields[lonIdx].isEmpty
            else { continue }
            coordinates[fields[frameFileIdx]] = "\(fields[latIdx]),\(fields[lonIdx])"
        }
        return coordinates
    }
}
