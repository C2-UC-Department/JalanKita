//
//  CaptureSessionController.swift
//  JalanKita iOS
//
//  Owns the AVCaptureSession + AVCaptureMovieFileOutput for continuous
//  dashcam-style recording. Every session is exactly one file, start to
//  stop — there is deliberately no pause/resume: an earlier version
//  implemented "pause" as ending the current clip and "resume" as starting
//  a new one, but that let the Mac's car-tracking pipeline lose track
//  continuity across the pause boundary (a car parked across a pause was
//  seen as two separate, shorter tracks instead of one). Recording once,
//  continuously, matches how a manually-uploaded video is always a single
//  file too.
//

import AVFoundation
import Observation

enum CaptureError: Error {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
}

@MainActor
@Observable
final class CaptureSessionController: NSObject {
    enum State {
        case idle, recording
    }

    private(set) var state: State = .idle
    private(set) var clipURLs: [URL] = []
    private(set) var elapsedSeconds: TimeInterval = 0

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var sessionDirectory: URL?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    /// Tracks the physical device's rotation and hands back the correct
    /// `AVCaptureConnection.videoRotationAngle` for it — Apple's own
    /// replacement for hand-rolling a `UIDeviceOrientation` mapping, which is
    /// a well-known source of off-by-90°/mirrored bugs. Landscape lock (see
    /// `OrientationLock`) is what gets the surveyor to actually hold the
    /// phone landscape; this is what makes the recorded file's own rotation
    /// metadata agree with that, however either landscape direction the
    /// phone ends up mounted in.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// True from the moment `movieOutput.stopRecording()` is called (by
    /// `stop()`) until the delegate confirms the clip actually finished
    /// writing. `state` alone isn't enough to know this — `stop()` flips
    /// `state` to `.idle` synchronously, well before the clip file's async
    /// finalize actually completes.
    private var isWaitingForClipToFinish = false
    private var stopRequestedAt: Date?

    func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        guard session.canAddOutput(movieOutput) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(movieOutput)

        // Without fragmentation, AVCaptureMovieFileOutput only writes the
        // full sample index at stopRecording() time — fine for a short
        // clip, but this app records hands-off for hours at a stretch, so
        // an unfragmented stop would have to serialize a huge index in one
        // shot. Fragmenting periodically during recording keeps stop fast
        // regardless of clip length (it only finalizes the trailing
        // fragment since the last flushed fragment).
        movieOutput.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.applyRotationAngle(angle) }
        }
    }

    /// Applied both on setup and on every subsequent device rotation (via
    /// `rotationObservation` above) — the coordinator's angle can change at
    /// any time the device rotates, not only once at configure time.
    private func applyRotationAngle(_ angle: CGFloat) {
        guard let connection = movieOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    /// `AVCaptureSession.startRunning()` is a genuinely blocking call — it
    /// can take anywhere from tens of milliseconds to over a second,
    /// especially on the very first camera access — which is why it's run
    /// off the main thread here. Callers MUST await this before recording:
    /// starting `movieOutput.startRecording(to:)` against a session that
    /// hasn't finished starting yet leaves the file output without a
    /// cleanly negotiated active connection, and that debt gets paid later
    /// when `stopRecording()` has to reconcile it — a plausible cause of an
    /// erratic, sometimes-long finalize unrelated to clip length.
    func startPreview() async {
        guard !session.isRunning else { return }
        await Task.detached { [session] in session.startRunning() }.value
    }

    func stopPreview() {
        guard session.isRunning else { return }
        Task.detached { [session] in session.stopRunning() }
    }

    /// Begins recording into `directory`, creating `clip_0.mov`.
    func startRecording(in directory: URL) {
        sessionDirectory = directory
        clipURLs = []
        let url = directory.appendingPathComponent("clip_0.mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        state = .recording
        recordingStartedAt = Date()
        startTimer()
    }

    /// Ends the clip and finalizes the recording. The completion fires once
    /// the clip file has actually finished writing (AVCaptureFileOutput's
    /// delegate callback), so callers can safely read `clipURLs`/the
    /// session directory there.
    func stop(completion: @escaping ([URL], TimeInterval) -> Void) {
        guard state == .recording || isWaitingForClipToFinish else {
            completion(clipURLs, elapsedSeconds)
            return
        }
        stopTimer()
        pendingStopCompletion = completion
        if state == .recording {
            isWaitingForClipToFinish = true
            stopRequestedAt = Date()
            print("[CaptureSessionController] stopRecording() called, waiting for finalize…")
            movieOutput.stopRecording()
            state = .idle
        }
        // else: already waiting on a prior stop() call's finalize — the delegate
        // callback below will fire this new completion once that write finishes.
    }

    private var pendingStopCompletion: (([URL], TimeInterval) -> Void)?

    private func startTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let recordingStartedAt {
            elapsedSeconds = Date().timeIntervalSince(recordingStartedAt)
        }
        recordingStartedAt = nil
    }

    private func tick() {
        guard let recordingStartedAt else { return }
        elapsedSeconds = Date().timeIntervalSince(recordingStartedAt)
    }
}

extension CaptureSessionController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            if let stopRequestedAt {
                let ms = Int(Date().timeIntervalSince(stopRequestedAt) * 1000)
                print("[CaptureSessionController] clip finalized after \(ms) ms" + (error != nil ? " (error: \(error!))" : ""))
                self.stopRequestedAt = nil
            }
            clipURLs.append(outputFileURL)
            isWaitingForClipToFinish = false
            if let pendingStopCompletion {
                self.pendingStopCompletion = nil
                state = .idle
                pendingStopCompletion(clipURLs, elapsedSeconds)
            }
        }
    }
}
