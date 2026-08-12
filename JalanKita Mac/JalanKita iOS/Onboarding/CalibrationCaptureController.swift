//
//  CalibrationCaptureController.swift
//  JalanKita iOS
//
//  A small dedicated still-photo capture session for the calibration step
//  (§6.1.3) — separate from CaptureSessionController, which is scoped to
//  continuous movie recording during an active survey session.
//

import AVFoundation
import Observation
import UIKit

@MainActor
@Observable
final class CalibrationCaptureController: NSObject {
    private(set) var capturedImage: UIImage?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var completion: ((UIImage?) -> Void)?

    func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(photoOutput)
    }

    func start() {
        guard !session.isRunning else { return }
        Task.detached { [session] in session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
        Task.detached { [session] in session.stopRunning() }
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
}

extension CalibrationCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        Task { @MainActor in
            capturedImage = image
            completion?(image)
        }
    }
}
