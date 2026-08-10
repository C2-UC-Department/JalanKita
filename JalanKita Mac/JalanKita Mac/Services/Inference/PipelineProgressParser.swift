//
//  PipelineProgressParser.swift
//  JalanKita Mac
//
//  Pure mapping from one `WorkerStderrLine` (InferenceWorkerProcess) to the
//  `PipelineStep`/`LogLine` updates ProcessingQueueView already knows how to
//  render — no AppModel/UI dependency here, just data in, data out, so it's
//  trivially testable against captured worker output.
//
//  Stage grouping matches SampleData.pipelineSteps' 4 real pipeline steps:
//  the worker reports finer-grained stages (segmentation / instances /
//  geometry / scale / bev / attribute / render) than the UI shows, so
//  geometry+scale collapse into step 3 and bev+attribute+render into step 4.
//

import Foundation
import JalanKitaKit

enum PipelineProgressParser {
    static let stepID: [String: Int] = [
        "segmentation": 1,
        "instances": 2,
        "geometry": 3, "scale": 3,
        "bev": 4, "attribute": 4, "render": 4,
    ]

    struct Update {
        var stepID: Int?
        var stepState: PipelineStep.State?
        var logLine: LogLine?
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func handle(_ line: WorkerStderrLine) -> Update {
        let time = timeFormatter.string(from: Date())
        switch line {
        case .event(let event):
            switch event.type {
            case "progress":
                guard let stage = event.stage, let state = event.state,
                      let id = stepID[stage] else { return Update() }
                let stepState: PipelineStep.State = (state == "done") ? .done : .active
                let log = LogLine(time: time, message: "\(stage) · \(state)", isWarning: false)
                return Update(stepID: id, stepState: stepState, logLine: log)
            case "error":
                let log = LogLine(time: time, message: event.error ?? "kesalahan tak diketahui",
                                  isWarning: true)
                return Update(logLine: log)
            default:
                return Update()
            }
        case .raw(let text):
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return Update() }
            return Update(logLine: LogLine(time: time, message: text, isWarning: false))
        }
    }
}
