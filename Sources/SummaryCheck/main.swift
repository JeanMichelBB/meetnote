import Foundation
import SummaryKit

// Test tool: runs the summary engine against a (fake) proxy and prints every change.
// Usage: SummaryCheck --url http://127.0.0.1:9101 [--lan URL] [--transcript FILE] [--fast]
//        [--action later|retry|cancel] [--small-limits]

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let urlText = value("--url"), let url = URL(string: urlText) else {
    print("Missing --url")
    exit(2)
}

var endpoints = [Endpoint(name: "Tailscale", url: url)]
if let lan = value("--lan"), let lanURL = URL(string: lan) {
    endpoints.append(Endpoint(name: "LAN", url: lanURL))
}
var config = ProxyConfig(endpoints: endpoints)
if value("--kind") == "server" { config.kind = .server }
if let key = value("--key") { config.apiKey = key }
if let model = value("--model") { config.model = model }
if args.contains("--fast") {
    config.unreachableRetrySeconds = 0.5
    config.maxUnreachableAttempts = 2
    config.gpuPollSeconds = 1
    config.circuitWaitSeconds = 1
    config.silenceTimeout = 3
    config.healthTimeout = 1
}
if args.contains("--small-limits") {
    config.singlePassTokenLimit = 100
    config.chunkTokenLimit = 60
}

let transcriptPath = value("--transcript")
let transcript = transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    ?? "[00:00:03] Me: Hello, let's start.\n[00:00:09] Speaker 1: We agreed to ship Friday.\n[00:00:15] Speaker 2: No, Monday is safer.\n"

final class Printer: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [StepID: StepState] = [:]
    private var logCount = 0
    private var wasAwaiting = false
    private let start = Date()
    var onAwaiting: (() -> Void)?

    func show(_ p: SummaryProgress) {
        lock.lock()
        defer { lock.unlock() }
        let t = String(format: "%5.1fs", Date().timeIntervalSince(start))
        for step in p.steps where previous[step.id] != step.state {
            previous[step.id] = step.state
            print("\(t)  \(step.id.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(Self.text(step.state))")
        }
        while logCount < p.log.count {
            print("\(t)  proxy says: \(p.log[logCount])")
            logCount += 1
        }
        if p.awaitingUser && !wasAwaiting { print("\(t)  >> waiting for a click (retry / later / cancel)") }
        if p.awaitingUser && !wasAwaiting { onAwaiting?() }
        wasAwaiting = p.awaitingUser
    }

    static func text(_ s: StepState) -> String {
        switch s {
        case .pending: return "pending"
        case .active(let d): return "ACTIVE   \(d ?? "")"
        case .waiting(let why, let at): return "WAITING  \(why)" + (at.map { String(format: " (retry in %.0fs)", $0.timeIntervalSinceNow) } ?? "")
        case .done(let d): return "done     \(d ?? "")"
        case .failed(let why): return "FAILED   \(why)"
        }
    }
}

let printer = Printer()
let engine = SummaryEngine(
    config: config, transcript: transcript, title: "Test meeting", transcriptInfo: "test transcript",
    onChange: { printer.show($0) })

var actions = (value("--action") ?? "later").split(separator: ",").map(String.init)
printer.onAwaiting = {
    let action = actions.isEmpty ? "later" : actions.removeFirst()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        print("        (test clicks: \(action))")
        switch action {
        case "retry": engine.retryNow()
        case "cancel": engine.cancel()
        default: engine.summarizeLater()
        }
    }
}

let outcome = await engine.run()
switch outcome {
case .completed(let text):
    print("RESULT completed (\(text.count) chars): \(text.replacingOccurrences(of: "\n", with: " ").prefix(160))")
case .deferred: print("RESULT deferred")
case .cancelled: print("RESULT cancelled")
case .failed(let why): print("RESULT failed: \(why)")
}
