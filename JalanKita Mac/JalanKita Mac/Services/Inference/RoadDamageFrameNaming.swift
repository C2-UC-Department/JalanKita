//
//  RoadDamageFrameNaming.swift
//  JalanKita Mac
//
//  Parsers for the one filename convention that crosses the Swift/Python boundary
//  in this vertical: `video_frames.py`'s `<clip>_f<index:06d>_t<ms:07d>.jpg`, e.g.
//  `IMG_0040_f000030_t0001000.jpg`.
//
//  ⚠️ That name is the ONLY carrier of a frame's provenance. The extractor writes a
//  `frames_provenance.csv` beside the frames, but nothing in the app reads it — the
//  worker is handed one image path at a time and answers about that image alone, so
//  by the time a response comes back the filename is all there is. Change
//  `video_frames.py:100` without changing these and frames silently lose their frame
//  number, their timecode, and their place on the session timeline; nothing throws,
//  the ticks just stop appearing.
//
//  These four functions were the only part of the 376-line `RoadDamageDataset` worth
//  keeping when the Stage 0 dataset browser was dropped along with the Peninjauan
//  screen. They are pure string parsing over a format this repo controls on both
//  sides — deliberately not a regex, and deliberately tolerant: an unparseable field
//  yields an em-dash or nil, never a fabricated zero.
//

import Foundation

enum RoadDamageFrameNaming {
    /// Does this stem carry both of the extractor's fields? Photos uploaded ad hoc
    /// match none of the convention and must not be labelled as though they did.
    static func looksSampled(_ stem: String) -> Bool {
        let parts = stem.split(separator: "_")
        let hasFrame = parts.contains { $0.hasPrefix("f") && Int($0.dropFirst()) != nil }
        let hasTime = parts.contains { $0.hasPrefix("t") && Int($0.dropFirst()) != nil }
        return hasFrame && hasTime
    }

    /// `IMG_0040_f000030_t0001000` -> `IMG_0040`. Stands in for a road name, which
    /// no source on disk actually knows.
    static func sourceClip(fromStem stem: String) -> String {
        let parts = stem.split(separator: "_")
        return parts.count >= 2 ? parts[0...1].joined(separator: "_") : stem
    }

    /// The decoder's own frame index, not a formatted guess. Em-dash when absent.
    static func frameIndex(fromStem stem: String) -> String {
        guard let field = stem.split(separator: "_").first(where: { $0.hasPrefix("f") }),
              let value = Int(field.dropFirst()) else { return "—" }
        return String(value)
    }

    /// Display timecode, `HH:MM:SS`. Prefers an explicit `seconds` when the caller
    /// has one (the session-relative value), falling back to the stem's own `t<ms>`.
    static func timecode(seconds: Double?, stem: String) -> String {
        let total: Double
        if let seconds {
            total = seconds
        } else if let ms = milliseconds(fromStem: stem) {
            total = Double(ms) / 1000.0
        } else {
            return "—"
        }
        let whole = Int(total.rounded())
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
    }

    /// The frame's offset within its own clip, in seconds — the numeric form the
    /// timeline needs, as opposed to `timecode`'s display string.
    ///
    /// Clip-relative, not session-relative: a multi-clip synced session adds its
    /// `clipOffsets` running total on top, exactly as the parking vertical does for
    /// `ParkingAnalysis.sessionRelativeSeconds`.
    static func clipRelativeSeconds(fromStem stem: String) -> Double? {
        guard let ms = milliseconds(fromStem: stem) else { return nil }
        return Double(ms) / 1000.0
    }

    private static func milliseconds(fromStem stem: String) -> Int? {
        guard let field = stem.split(separator: "_").first(where: { $0.hasPrefix("t") }),
              let ms = Int(field.dropFirst()) else { return nil }
        return ms
    }
}
