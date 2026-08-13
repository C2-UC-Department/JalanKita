//
//  RoadDamageWorkerProcess.swift
//  JalanKita Mac
//
//  Owns the road-damage worker child process and speaks its NDJSON protocol —
//  the same shape as InferenceWorkerProcess, for the same reasons: an actor so
//  stdout decoding never touches the main actor, and one warm process per app run
//  because loading YOLO11s costs seconds that must not repeat per frame.
//
//  It reuses `AsyncLineReader` from InferenceWorkerProcess.swift rather than
//  carrying its own copy. That type is already the module's answer to "Pipe
//  delivers byte chunks, not lines", and a second implementation would be a
//  second place for the partial-read bug to come back.
//
//  Kept as a separate type from InferenceWorkerProcess rather than generalised
//  into one shared worker: the two have different launch resolution, different
//  environment overrides, and different response types, so a shared abstraction
//  would be three special cases wearing a trench coat. If a third Protocol A
//  worker ever appears, THAT is the point to extract one.
//

import Foundation

enum RoadDamageWorkerError: Error, LocalizedError {
    case workerNotFound(searched: [String])
    case launchFailed(String)
    case workerTerminated(status: Int32)
    case requestFailed(String)

    /// The worker accepted a request (or a launch) and never answered. Names the
    /// likely cause and the recovery, the way `workerNotFound` does — a bare
    /// "timed out" tells the reviewer nothing they can act on.
    case timedOut(seconds: Int, duringStart: Bool)

    var errorDescription: String? {
        switch self {
        case .workerNotFound(let searched):
            "Tidak menemukan worker kerusakan jalan. Dicari di:\n  "
                + searched.joined(separator: "\n  ")
                + "\nSetel JALANKITA_ROAD_DAMAGE_REPO atau buat RoadDamage/.venv."
        case .launchFailed(let reason):
            "Gagal menjalankan worker kerusakan jalan: \(reason)"
        case .workerTerminated(let status):
            "Worker kerusakan jalan berhenti tak terduga (kode \(status))."
        case .requestFailed(let message):
            message
        case .timedOut(let seconds, let duringStart):
            duringStart
                ? "Worker kerusakan jalan tidak siap dalam \(seconds) detik dan dihentikan. "
                    + "Kemungkinan pemuatan model tertahan; coba unggah foto lagi."
                : "Worker kerusakan jalan tidak merespons dalam \(seconds) detik dan "
                    + "dimulai ulang. Coba unggah foto itu lagi."
        }
    }
}

enum RoadDamageStderrLine {
    case event(RoadDamageEvent)
    case raw(String)
}

actor RoadDamageWorkerProcess {
    private let executableURL: URL
    private let arguments: [String]
    private let workingDirectory: URL?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutReader: AsyncLineReader?
    private var stderrReader: AsyncLineReader?

    private var pending: [String: CheckedContinuation<RoadDamageResponse, Error>] = [:]
    private var responsePumpTask: Task<Void, Never>?

    var onStderrLine: (@Sendable (RoadDamageStderrLine) -> Void)?

    init(executableURL: URL, arguments: [String], workingDirectory: URL?) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func setOnStderrLine(_ handler: @escaping @Sendable (RoadDamageStderrLine) -> Void) {
        onStderrLine = handler
    }

    /// Starts the worker and waits for `{"type":"ready"}`, i.e. until the model
    /// is loaded. No-op if already running.
    func start() async throws {
        if isRunning { return }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RoadDamageWorkerError.workerNotFound(searched: [executableURL.path])
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        // Same defensive posture as PYTHONWORKER_FORCE_CPU (ADR-012): a GPU
        // backend crash in a child process takes the whole console down, and this
        // vertical runs one cheap detector pass where the MPS win is small. A CLI
        // run without this variable still gets MPS, so timings differ by design.
        var environment = ProcessInfo.processInfo.environment
        environment["JALANKITA_ROAD_DAMAGE_FORCE_CPU"] = "1"
        // Unbuffered, so progress events arrive as they happen rather than in a
        // burst when the pipe flushes.
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutReader = AsyncLineReader(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrReader = AsyncLineReader(fileHandle: stderrPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            throw RoadDamageWorkerError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader

        startResponsePump(stdoutReader)
        try await waitForReady(stderrReader)
        startStderrPump(stderrReader)
    }

    func send(_ request: RoadDamageRequest) async throws -> RoadDamageResponse {
        guard let stdinHandle, isRunning else {
            throw RoadDamageWorkerError.workerTerminated(status: process?.terminationStatus ?? -1)
        }

        var line = try JSONEncoder().encode(request)
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: request.id)
                continuation.resume(throwing:
                    RoadDamageWorkerError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Gives up on one in-flight request, failing its caller instead of leaving it
    /// parked forever.
    ///
    /// Needed because `send`'s continuation is only ever resumed by a matching
    /// response line — a worker that accepts a request and then wedges resumes
    /// nothing, and the caller's `defer { isAnalyzingRoadDamage = false }` never
    /// runs, so Peninjauan's toolbar shows "Menganalisis…" until the app quits.
    ///
    /// Actor-isolated on purpose: `RoadDamageService` drives this from a detached
    /// timer, and `pending` must only ever be touched from inside the actor. That
    /// isolation is the reason the service uses a plain timer Task rather than a
    /// `withThrowingTaskGroup` race — a group's child task is non-isolated, and
    /// mutating `pending` from one would be the bug the deadline was added to fix.
    ///
    /// No-op when the request already answered, which is the common race.
    func abandon(requestID: String, afterSeconds seconds: Int) {
        pending.removeValue(forKey: requestID)?
            .resume(throwing: RoadDamageWorkerError.timedOut(seconds: seconds, duringStart: false))
    }

    func stop() {
        responsePumpTask?.cancel()
        responsePumpTask = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: RoadDamageWorkerError.workerTerminated(status: -1))
        }
        pending.removeAll()
        try? stdinHandle?.close()
        stdinHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdoutReader = nil
        stderrReader = nil
    }

    private func waitForReady(_ stderrReader: AsyncLineReader) async throws {
        for try await line in stderrReader.lines {
            if let event = Self.decodeEvent(line), event.type == "ready" {
                return
            }
            onStderrLine?(Self.classify(line))
            if !isRunning {
                throw RoadDamageWorkerError.workerTerminated(
                    status: process?.terminationStatus ?? -1)
            }
        }
        // Reader ended before "ready": the worker died during load, which is what
        // a missing checkpoint looks like from here.
        throw RoadDamageWorkerError.workerTerminated(status: process?.terminationStatus ?? -1)
    }

    private func startStderrPump(_ stderrReader: AsyncLineReader) {
        Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in stderrReader.lines {
                    await self.deliverStderr(line)
                }
            } catch {
                // Reader ended (process exited) — nothing further to pump.
            }
        }
    }

    private func deliverStderr(_ line: String) {
        onStderrLine?(Self.classify(line))
    }

    private func startResponsePump(_ stdoutReader: AsyncLineReader) {
        responsePumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in stdoutReader.lines {
                    await self.deliverResponse(line)
                }
            } catch {
                // Reader ended.
            }
            await self.failAllPending()
        }
    }

    private func deliverResponse(_ line: String) {
        guard let data = line.data(using: .utf8),
              let response = try? JSONDecoder().decode(RoadDamageResponse.self, from: data) else {
            // stdout is responses only, so an undecodable line means the worker
            // broke its own contract — surface it rather than dropping it silently.
            onStderrLine?(.raw("[worker] malformed response line: \(line)"))
            return
        }
        if let continuation = pending.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
    }

    private func failAllPending() {
        for (_, continuation) in pending {
            continuation.resume(throwing: RoadDamageWorkerError.workerTerminated(
                status: process?.terminationStatus ?? -1))
        }
        pending.removeAll()
    }

    private static func decodeEvent(_ line: String) -> RoadDamageEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RoadDamageEvent.self, from: data)
    }

    private static func classify(_ line: String) -> RoadDamageStderrLine {
        if let event = decodeEvent(line) { return .event(event) }
        return .raw(line)
    }
}
