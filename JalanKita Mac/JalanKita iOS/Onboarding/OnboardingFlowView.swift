//
//  OnboardingFlowView.swift
//  JalanKita iOS
//
//  Design brief §6.1 — permissions, mounting guide, scale calibration.
//

import SwiftUI

struct OnboardingFlowView: View {
    @Environment(AppModel.self) private var model

    private enum Step: Int, CaseIterable {
        case permissions, mounting, calibration
    }

    @State private var step: Step = .permissions

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                .padding(.horizontal)
                .padding(.top)

            switch step {
            case .permissions:
                PermissionsStepView { advance() }
            case .mounting:
                MountingGuideView { advance() }
            case .calibration:
                CalibrationStepView(
                    onFinish: { model.completeOnboarding() },
                    onSkip: { model.completeOnboarding() }
                )
            }
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            model.completeOnboarding()
            return
        }
        step = next
    }
}
