//
//  AppModel.swift
//  JalanKita iOS
//
//  Single source of truth for the recording app — NOT shared with the
//  Mac's AppModel. The two apps have very different shapes: the Mac is a
//  desk console orchestrating Process()-based ML workers; this is a
//  recording+GPS-logging app with no inference of its own. Both consume
//  the same JalanKitaKit model/design-system types so the vocabulary
//  (Session, Severity, SessionStatus, ...) stays identical.
//

import Foundation
import Observation
import JalanKitaKit

@MainActor
@Observable
final class AppModel {
    var hasCompletedOnboarding: Bool
    var surveyorName: String
    var calibration: CalibrationProfile?
    var localSessions: [Session] = []

    let store = RecordingSessionStore()

    private enum DefaultsKey {
        static let onboarded = "hasCompletedOnboarding"
        static let surveyorName = "surveyorName"
    }

    init() {
        let defaults = UserDefaults.standard
        hasCompletedOnboarding = defaults.bool(forKey: DefaultsKey.onboarded)
        surveyorName = defaults.string(forKey: DefaultsKey.surveyorName) ?? ""
        calibration = nil
        localSessions = []
        localSessions = store.loadIndex()
        calibration = store.loadCalibration()
    }

    func setSurveyorName(_ name: String) {
        surveyorName = name
        UserDefaults.standard.set(name, forKey: DefaultsKey.surveyorName)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboarded)
    }

    func saveCalibration(_ profile: CalibrationProfile) {
        calibration = profile
        store.saveCalibration(profile)
    }

    func recordingFinished(_ session: Session) {
        localSessions.insert(session, at: 0)
        store.appendToIndex(session)
    }
}
