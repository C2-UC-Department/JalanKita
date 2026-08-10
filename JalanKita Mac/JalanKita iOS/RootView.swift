//
//  RootView.swift
//  JalanKita iOS
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasCompletedOnboarding {
            HomeDashboardView()
        } else {
            OnboardingFlowView()
        }
    }
}
