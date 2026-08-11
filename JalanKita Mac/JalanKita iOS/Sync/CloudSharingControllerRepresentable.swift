//
//  CloudSharingControllerRepresentable.swift
//  JalanKita iOS
//
//  SwiftUI wrapper around UICloudSharingController — the standard iOS
//  share sheet for a CKShare (Messages/Mail/AirDrop/copy-link). Presented
//  from SyncSetupView once this surveyor's zone-wide share exists.
//

import CloudKit
import SwiftUI

struct CloudSharingControllerRepresentable: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onDismiss: (() -> Void)?

        init(onDismiss: (() -> Void)?) {
            self.onDismiss = onDismiss
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Sesi survei JalanKita"
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: any Error) {
            print("[CloudSharingControllerRepresentable] failed to save share: \(error)")
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onDismiss?()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDismiss?()
        }
    }
}
