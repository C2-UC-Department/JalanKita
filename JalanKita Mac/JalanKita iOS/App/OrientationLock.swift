//
//  OrientationLock.swift
//  JalanKita iOS
//
//  A synced session's video is captured in whatever orientation the phone
//  physically was in — the app has no way to rotate the pixels after the
//  fact into a wider field of view, only to relabel already-narrow content.
//  A portrait-held recording is genuinely a narrower, taller slice of the
//  road than the landscape footage the Mac's detection pipeline expects, so
//  the fix has to happen here, at capture time: `ActiveRecordingView` locks
//  the interface to landscape only for as long as it's on screen, via
//  `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` below,
//  which the system consults on every rotation attempt. Locking Portrait out
//  of that mask means the OS won't let the recording screen settle into
//  portrait, which in practice is what gets the surveyor to actually rotate
//  the phone (a purely software-side lock can't rotate the device itself).
//

import UIKit

@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .all

    /// Locks the mask the system will hand back the next time it calls
    /// `supportedInterfaceOrientationsFor`, and asks it to re-evaluate right
    /// away — without `requestGeometryUpdate`, a mask change only takes
    /// effect at the next rotation the user happens to trigger themselves,
    /// which could be never if they never touch the device.
    static func apply(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
            print("[OrientationLock] requestGeometryUpdate(\(newMask)) failed: \(error)")
        }
    }
}
