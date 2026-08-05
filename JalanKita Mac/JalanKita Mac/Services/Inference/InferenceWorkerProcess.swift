//
//  InferenceWorkerProcess.swift
//  JalanKita Mac
//
//  Owns the `disturbance-worker` child process and speaks its NDJSON
//  protocol (one JSON object per line each way — see InferenceModels.swift
//  and src/disturbance.py's `serve_worker`). This is the first async/await
//  code in the app (previously zero Task/URLSession usage); it's an actor,
//  not a MainActor type, so decoding stdout and parsing stderr never blocks
//  the UI even though the project defaults new code to MainActor isolation.
//
//  One process per app run: launched lazily on first use and kept warm,
//  because model loading alone takes seconds to over a minute and must not
//  repeat per image (confirmed against a live `--serve` run this session).
//

import Foundation

enum InferenceWorkerError: Error, LocalizedError {
    case workerNotFound
    case launchFailed(String)
    case workerTerminated(status: Int32)
    case malformedResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .workerNotFound:
            "Tidak menemukan biner disturbance-worker (belum dipaketkan atau path dev tidak diset)."
        case .launchFailed(let reason):
            "Gagal menjalankan disturbance-worker: \(reason)"
        case .workerTerminated(let status):
            "disturbance-worker berhenti tak terduga (kode \(status))."
        case .malformedResponse(let raw):
            "Balasan worker tidak bisa dibaca: \(raw)"
        case .requestFailed(let message):
            message
        }
    }
}

/// A single parsed line from the worker's stderr: either a structured
/// `WorkerEvent` (progress/ready/error) or an unstructured chatter line
/// (model loading, `tqdm`, warnings) that isn't valid JSON.
enum WorkerStderrLine {
    case event(WorkerEvent)
    case raw(String)
}

actor InferenceWorkerProcess {
    private let executableURL: URL
    private let arguments: [String]
    private let workingDirectory: URL?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutReader: AsyncLineReader?
    private var stderrReader: AsyncLineReader?

    /// Pending requests awaiting a response, keyed by request id. `analyze`
    /// calls only ever have one in flight at a time in this app (Phase 3
    /// doesn't build a request queue), but keying by id rather than
    /// assuming FIFO costs nothing and matches the protocol's own shape.
    private var pending: [String: CheckedContinuation<WorkerResponse, Error>] = [:]
    private var responsePumpTask: Task<Void, Never>?

    /// Where stderr events land — set by InferenceService before any request
    /// is sent, consumed off the actor via a plain closure hop.
    var onStderrLine: (@Sendable (WorkerStderrLine) -> Void)?

    /// `arguments` defaults to just `--serve` (the packaged, frozen worker's
    /// only argument). A dev-mode launch invoking the system `python3`
    /// directly instead passes `["-m", "src.disturbance", "--serve"]` — see
    /// `InferenceService.resolveWorkerLaunch()`.
    init(executableURL: URL, arguments: [String] = ["--serve"], workingDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func setOnStderrLine(_ handler: @escaping @Sendable (WorkerStderrLine) -> Void) {
        onStderrLine = handler
    }

    /// Starts the worker and blocks (async) until it reports `{"type": "ready"}`
    /// on stderr, i.e. until `load_models()` has finished. No-op if already running.
    func start() async throws {
        if isRunning { return }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw InferenceWorkerError.workerNotFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

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
            throw InferenceWorkerError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader

        startResponsePump(stdoutReader)
        try await waitForReady(stderrReader)
        startStderrPump(stderrReader)
    }

    /// Sends one request and awaits its matching response, routed by `id`
    /// (the caller's own request `id` field — passed separately rather than
    /// read back off `request` so this works for any Encodable request shape
    /// the protocol grows, e.g. `WorkerRequest`/`RenderBEVRequest`). Throws
    /// if the worker isn't running (call `start()` first) or exits mid-request.
    func send<Request: Encodable>(_ request: Request, id: String) async throws -> WorkerResponse {
        guard let stdinHandle, isRunning else {
            throw InferenceWorkerError.workerTerminated(status: process?.terminationStatus ?? -1)
        }

        let data = try JSONEncoder().encode(request)
        var line = data
        line.append(0x0A) // '\n'

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: InferenceWorkerError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Terminates the child process, if any, and fails every request still
    /// in flight — called from `InferenceService` on app termination so no
    /// orphaned `disturbance-worker` process survives quitting mid-analysis.
    func stop() {
        responsePumpTask?.cancel()
        responsePumpTask = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: InferenceWorkerError.workerTerminated(status: -1))
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
                throw InferenceWorkerError.workerTerminated(status: process?.terminationStatus ?? -1)
            }
        }
        throw InferenceWorkerError.workerTerminated(status: process?.terminationStatus ?? -1)
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
        guard let data = line.data(using: .utf8) else { return }
        guard let response = try? JSONDecoder().decode(WorkerResponse.self, from: data) else {
            // A malformed stdout line means the worker's own contract broke —
            // there's no request id to route this to, so it's dropped after
            // being surfaced as a log line rather than silently ignored.
            onStderrLine?(.raw("[worker] malformed response line: \(line)"))
            return
        }
        if let continuation = pending.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
    }

    private func failAllPending() {
        for (_, continuation) in pending {
            continuation.resume(throwing: InferenceWorkerError.workerTerminated(
                status: process?.terminationStatus ?? -1))
        }
        pending.removeAll()
    }

    private static func decodeEvent(_ line: String) -> WorkerEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkerEvent.self, from: data)
    }

    private static func classify(_ line: String) -> WorkerStderrLine {
        if let event = decodeEvent(line) {
            return .event(event)
        }
        return .raw(line)
    }
}

/// Turns a `FileHandle`'s byte stream into an `AsyncSequence` of UTF-8 lines,
/// buffering partial reads across chunks. `Process`/`Pipe` deliver arbitrary
/// byte chunks, not line-delimited ones, so this is required to get one
/// `AsyncSequence` element per NDJSON line rather than per OS read.
final class AsyncLineReader: @unchecked Sendable {
    private let fileHandle: FileHandle

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    var lines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = fileHandle
            Task.detached {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break // EOF: process exited / pipe closed.
                    }
                    buffer.append(chunk)
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            continuation.yield(line)
                        }
                    }
                }
                continuation.finish()
            }
        }
    }
}
