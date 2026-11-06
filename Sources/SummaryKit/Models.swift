import Foundation

public enum StepID: String, CaseIterable, Sendable {
    case transcript, proxy, pc, wake, model, summary, save

    public var title: String {
        switch self {
        case .transcript: return "Transcript saved"
        case .proxy: return "Reach the server"
        case .pc: return "Check the PC"
        case .wake: return "Wake the PC"
        case .model: return "Load the model"
        case .summary: return "Write the summary"
        case .save: return "Save the summary"
        }
    }
}

public enum StepState: Equatable, Sendable {
    case pending
    case active(String?)
    case waiting(String, retryAt: Date?)
    case done(String?)
    case failed(String)
}

public struct StepInfo: Identifiable, Equatable, Sendable {
    public var id: StepID
    public var state: StepState = .pending
    public var since: Date = Date()
    public var title: String { id.title }
}

public enum Outcome: Equatable, Sendable {
    case completed(String)
    case deferred
    case cancelled
    case failed(String)
}

public struct SummaryProgress: Sendable {
    public var steps: [StepInfo] = StepID.allCases.map { StepInfo(id: $0) }
    /// Every progress line the proxy reported, oldest first.
    public var log: [String] = []
    /// The summary text received so far.
    public var partial: String = ""
    public var startedAt = Date()
    /// True when the engine is stopped and only a click (retry, later, cancel) can continue it.
    public var awaitingUser = false
    public var finished: Outcome?

    /// One short line describing the current situation, used in the file and the menu.
    public var headline: String {
        if let finished {
            switch finished {
            case .completed: return "Summary ready."
            case .deferred: return "Summary postponed."
            case .cancelled: return "Summary cancelled."
            case .failed(let why): return "Summary failed: \(why)"
            }
        }
        for step in steps {
            switch step.state {
            case .failed(let why): return "\(step.title) failed: \(why)"
            case .waiting(let why, _): return why
            default: continue
            }
        }
        for step in steps {
            if case .active(let detail) = step.state { return detail ?? step.title }
        }
        return "Preparing the summary…"
    }
}
