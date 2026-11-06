import AppKit
import SummaryKit
import SwiftUI

/// Runs one summary job at a time, keeps the .md file's summary section up to date,
/// and remembers postponed meetings so nothing is lost.
final class SummaryCoordinator: ObservableObject {
    enum Kind { case idle, working, waiting, problem }

    @Published private(set) var progress: SummaryProgress?
    @Published private(set) var isRunning = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var title = ""
    @Published private(set) var file: URL?
    /// True when the last job ended in a failure the user should look at.
    @Published private(set) var lastFailed = false
    /// Called on the main thread when a job ends; true if the summary was saved.
    var onFinished: ((Bool) -> Void)?

    private var engine: SummaryEngine?
    private var lastHeadline = ""
    private let window = SummaryWindowController()
    private static let pendingKey = "pendingSummaries"

    init() {
        recoverInterrupted()
        pendingCount = pending.count
    }

    /// A summary that was running when the app quit or crashed leaves a stale status line in its file.
    /// Put those meetings back in the postponed list so nothing is lost.
    private func recoverInterrupted() {
        TranscriptWriter.organize()
        UserDefaults.standard.removeObject(forKey: Self.pendingKey) // old paths may have moved
        for url in TranscriptWriter.allTranscripts() {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                let current = SummaryFile.currentBody(of: text),
                current.hasPrefix("Summary in progress") || current.hasPrefix("Summary pending")
            else { continue }
            addPending(url)
            try? SummaryFile.replaceSection(
                in: url,
                with: "Summary interrupted (the app was closed). Right-click the MeetNote icon and choose \"Re-summarize last transcript\".")
        }
    }

    /// What the menu bar icon should show.
    var kind: Kind {
        guard isRunning, let progress else { return .idle }
        if progress.awaitingUser { return .problem }
        for step in progress.steps {
            switch step.state {
            case .failed: return .problem
            case .waiting: return .waiting
            default: continue
            }
        }
        return .working
    }

    // MARK: start and controls

    func start(file: URL) {
        guard !isRunning else {
            addPending(file)
            return
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let transcript = SummaryFile.transcriptText(from: text)
        guard !transcript.isEmpty else { return }

        let config = ProxyConfig.load()
        if config.kind == .none {
            try? SummaryFile.replaceSection(
                in: file, with: "Summaries are turned off. Choose a summary server in MeetNote settings, then use \"Re-summarize last transcript\".")
            return
        }

        let words = transcript.split(whereSeparator: \.isWhitespace).count
        let engine = SummaryEngine(
            config: config, transcript: transcript,
            title: SummaryFile.title(from: text), transcriptInfo: "\(words) words",
            onChange: { [weak self] progress in
                DispatchQueue.main.async { self?.received(progress) }
            })
        self.engine = engine
        self.file = file
        self.title = SummaryFile.title(from: text)
        lastHeadline = ""
        isRunning = true
        progress = engine.currentProgress
        removePending(file)
        lastFailed = false
        Task { [weak self] in
            let outcome = await engine.run()
            await MainActor.run { self?.finish(outcome, file: file, engine: engine) }
        }
    }

    func retryNow() { engine?.retryNow() }
    func later() { engine?.summarizeLater() }
    func cancel() { engine?.cancel() }

    func showWindow() { window.show(coordinator: self) }

    func openFile() {
        guard let file else { return }
        NSWorkspace.shared.open(file)
    }

    func copyDetails() {
        guard let progress else { return }
        var lines = ["Meeting: \(title)"]
        for step in progress.steps { lines.append("\(step.title): \(Self.describe(step.state))") }
        if !progress.log.isEmpty { lines.append("\nProxy messages:"); lines += progress.log }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func copySummary() {
        guard let text = progress?.partial, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Starts the oldest postponed meeting.
    func startNextPending() {
        guard !isRunning else { return showWindow() }
        while let path = pending.first {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                start(file: url)
                return
            }
            removePending(url)
        }
    }

    // MARK: updates from the engine

    private func received(_ newProgress: SummaryProgress) {
        // Late status updates must never overwrite the final result, in the file or on screen.
        guard isRunning else { return }
        progress = newProgress
        guard newProgress.finished == nil, let file, newProgress.headline != lastHeadline else { return }
        lastHeadline = newProgress.headline
        try? SummaryFile.replaceSection(in: file, with: "Summary in progress: \(newProgress.headline)")
    }

    private func finish(_ outcome: Outcome, file: URL, engine: SummaryEngine) {
        switch outcome {
        case .completed(let text):
            do {
                try SummaryFile.replaceSection(in: file, with: text)
                engine.reportSaved("Saved in \(file.lastPathComponent)")
            } catch {
                engine.reportSaveFailed(error.localizedDescription + " Use Copy summary to keep the text.")
                addPending(file)
            }
        case .deferred:
            addPending(file)
            try? SummaryFile.replaceSection(
                in: file,
                with: "Summary postponed. Right-click the MeetNote icon and choose \"Re-summarize last transcript\".")
        case .cancelled:
            try? SummaryFile.replaceSection(in: file, with: "Summary cancelled.")
        case .failed(let why):
            addPending(file)
            try? SummaryFile.replaceSection(in: file, with: "Summary failed: \(why)")
        }
        progress = engine.currentProgress
        isRunning = false
        var saved = false
        if case .completed = outcome, progress?.finished != nil { saved = !(pending.contains(file.path)) }
        if case .failed = outcome { lastFailed = true }
        if case .completed = outcome, !saved { lastFailed = true }
        onFinished?(saved)
    }

    // MARK: postponed list

    private var pending: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pendingKey)
            pendingCount = newValue.count
        }
    }

    private func addPending(_ url: URL) {
        if !pending.contains(url.path) { pending.append(url.path) }
    }

    private func removePending(_ url: URL) {
        pending.removeAll { $0 == url.path }
    }

    static func describe(_ state: StepState) -> String {
        switch state {
        case .pending: return "waiting its turn"
        case .active(let detail): return detail ?? "in progress"
        case .waiting(let message, _): return "waiting: \(message)"
        case .done(let detail): return detail ?? "done"
        case .failed(let message): return "FAILED: \(message)"
        }
    }
}
