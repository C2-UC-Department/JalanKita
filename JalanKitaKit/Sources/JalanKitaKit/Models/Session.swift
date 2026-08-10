//
//  Session.swift
//  JalanKitaKit
//
//  One recorded drive, somewhere between "just landed on disk" and "fully
//  processed and reported." Shared between JalanKita Mac (desk console) and
//  JalanKita iOS (recording app) so both speak the same session vocabulary.
//

import Foundation

public struct Session: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var roadName: String
    public var kmMarker: String?
    public var date: String
    public var surveyor: Surveyor
    public var clipCount: Int
    public var duration: String
    public var distanceKm: Double
    public var gpsAccuracyM: Int?
    public var gpsHz: Double?
    public var gpsGapNote: String?
    public var sizeGB: Double
    public var status: SessionStatus
    public var segmentCount: Int?
    public var selectedForBatch: Bool = false

    public init(id: String, roadName: String, kmMarker: String? = nil, date: String, surveyor: Surveyor,
                clipCount: Int, duration: String, distanceKm: Double, gpsAccuracyM: Int? = nil,
                gpsHz: Double? = nil, gpsGapNote: String? = nil, sizeGB: Double, status: SessionStatus,
                segmentCount: Int? = nil, selectedForBatch: Bool = false) {
        self.id = id
        self.roadName = roadName
        self.kmMarker = kmMarker
        self.date = date
        self.surveyor = surveyor
        self.clipCount = clipCount
        self.duration = duration
        self.distanceKm = distanceKm
        self.gpsAccuracyM = gpsAccuracyM
        self.gpsHz = gpsHz
        self.gpsGapNote = gpsGapNote
        self.sizeGB = sizeGB
        self.status = status
        self.segmentCount = segmentCount
        self.selectedForBatch = selectedForBatch
    }
}
