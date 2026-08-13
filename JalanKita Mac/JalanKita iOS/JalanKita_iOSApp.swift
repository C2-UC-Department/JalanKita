//
//  JalanKita_iOSApp.swift
//  JalanKita iOS
//
//  Entry point for the surveyor recording app. This app captures video +
//  GPS only — it performs no on-device inference. See AppModel for the
//  single source of truth and RecordingSessionStore for local-only
//  persistence (no CloudKit yet; see the phase plan).
//

import SwiftUI

@main
struct JalanKita_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
