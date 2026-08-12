//
//  CoverageMapView.swift
//  JalanKita iOS
//
//  Top-level "Peta Cakupan" tab — this surveyor's own recorded coverage,
//  not a multi-surveyor view. The iPhone only ever holds its own private
//  CloudKit zone; other surveyors' zones are visible only to the Mac (the
//  CKShare recipient), so scoping this to "sessions recorded on this
//  device" is correct, not a limitation to work around.
//

import MapKit
import SwiftUI
import JalanKitaKit

struct CoverageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var routesBySessionID: [String: [CLLocationCoordinate2D]] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if model.localSessions.isEmpty {
                    ContentUnavailableView(
                        "Belum ada sesi",
                        systemImage: "map",
                        description: Text("Peta cakupan akan terisi setelah kamu merekam sesi pertama.")
                    )
                } else {
                    List {
                        Section {
                            map
                                .frame(height: 320)
                                .listRowInsets(EdgeInsets())
                        }
                        Section("SESI") {
                            ForEach(model.localSessions) { session in
                                SessionRowView(session: session)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Peta Cakupan")
            .navigationDestination(for: Session.self) { session in
                SessionDetailView(session: session)
            }
            .navigationDestination(for: ParkingReportRoute.self) { route in
                ParkingReportView(sessionID: route.sessionID)
            }
            .task {
                await loadRoutes()
            }
            .onChange(of: model.localSessions.count) {
                Task { await loadRoutes() }
            }
        }
    }

    private var map: some View {
        Map {
            ForEach(model.localSessions) { session in
                if let coordinates = routesBySessionID[session.id], coordinates.count > 1 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(session.status.foreground, lineWidth: 3)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func loadRoutes() async {
        var routes: [String: [CLLocationCoordinate2D]] = [:]
        for session in model.localSessions {
            routes[session.id] = GPSTrackLoader.loadCoordinates(sessionID: session.id, store: model.store)
        }
        routesBySessionID = routes
    }
}
