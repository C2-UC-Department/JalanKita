//
//  CaptureSessionController.swift
//  JalanKita iOS
//
//  Owns the AVCaptureSession + AVCaptureMovieFileOutput for continuous
//  dashcam-style recording. AVCaptureMovieFileOutput has no native
//  pause/resume, so "pause" is implemented as ending the current clip file
//  and "resume" as starting a new one — matching the existing desk app's
//  `Session.clipCount` field, which already models a session as one or
//  more clips rather than assuming exactly one file.
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
        case idle, recording, paused
    }

    private(set) var state: State = .idle
    private(set) var clipURLs: [URL] = []
    private(set) var elapsedSeconds: TimeInterval = 0

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var sessionDirectory: URL?
    private var clipIndex = 0
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var accumulatedElapsed: TimeInterval = 0

    /// True from the moment `movieOutput.stopRecording()` is called (by
    /// either `pause()` or `stop()`) until the delegate confirms that clip
    /// actually finished writing. `state` alone isn't enough to know this —
    /// `pause()` flips `state` to `.paused` synchronously, well before the
    /// clip file's async finalize actually completes.
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

    /// Begins recording into `directory`, creating `clip_0.mp4`.
    func startRecording(in directory: URL) {
        sessionDirectory = directory
        clipIndex = 0
        clipURLs = []
        accumulatedElapsed = 0
        beginClip()
    }

    /// Ends the current clip file. Recording resumes into a new clip via `resume()`.
    func pause() {
        guard state == .recording else { return }
        isWaitingForClipToFinish = true
        stopRequestedAt = Date()
        print("[CaptureSessionController] pause() -> stopRecording() called, waiting for finalize…")
        movieOutput.stopRecording()
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused else { return }
        clipIndex += 1
        beginClip()
    }

    /// Ends the current clip and finalizes the whole recording. The
    /// completion fires once the LAST clip file has actually finished
    /// writing (AVCaptureFileOutput's delegate callback), so callers can
    /// safely read `clipURLs`/the session directory there.
    ///
    /// Calling this right after `pause()` must NOT skip that wait just
    /// because `state` is already `.paused` — `pause()`'s own
    /// `stopRecording()` call may not have finished writing its clip yet,
    /// and returning early here would race that write (wrong `clipURLs`
    /// count, a directory scan that catches the file mid-write).
    func stop(completion: @escaping ([URL], TimeInterval) -> Void) {
        guard state == .recording || state == .paused || isWaitingForClipToFinish else {
            completion(clipURLs, accumulatedElapsed)
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
        } else if isWaitingForClipToFinish {
            // A just-issued pause() is still finalizing its clip — the
            // delegate callback below will fire the completion once that
            // write actually finishes, same as the .recording branch.
            state = .idle
        } else {
            // Paused, and that clip already finished writing — truly
            // nothing left in flight, safe to finish right now.
            state = .idle
            let handler = pendingStopCompletion
            pendingStopCompletion = nil
            handler?(clipURLs, accumulatedElapsed)
        }
    }

    private var pendingStopCompletion: (([URL], TimeInterval) -> Void)?

    private func beginClip() {
        guard let sessionDirectory else { return }
        let url = sessionDirectory.appendingPathComponent("clip_\(clipIndex).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        state = .recording
        recordingStartedAt = Date()
        startTimer()
    }

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
            accumulatedElapsed += Date().timeIntervalSince(recordingStartedAt)
        }
        recordingStartedAt = nil
        elapsedSeconds = accumulatedElapsed
    }

    private func tick() {
        guard let recordingStartedAt else { return }
        elapsedSeconds = accumulatedElapsed + Date().timeIntervalSince(recordingStartedAt)
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
                pendingStopCompletion(clipURLs, accumulatedElapsed)
            }
        }
    }
}
