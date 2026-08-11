//
//  RootView.swift
//  JalanKita iOS
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasCompletedOnboarding {
            TabView {
                HomeDashboardView()
                    .tabItem { Label("Beranda", systemImage: "house.fill") }
                CoverageMapView()
                    .tabItem { Label("Peta Cakupan", systemImage: "map.fill") }
            }
        } else {
            OnboardingFlowView()
        }
    }
}
