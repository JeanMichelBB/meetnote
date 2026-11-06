import AppKit
import SummaryKit
import SwiftUI

final class SummaryWindowController {
    private var window: NSWindow?

    func show(coordinator: SummaryCoordinator) {
        if window == nil {
            let hosting = NSHostingController(rootView: SummaryProgressView(coordinator: coordinator))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MeetNote summary"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SummaryProgressView: View {
    @ObservedObject var coordinator: SummaryCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let progress = coordinator.progress {
                header(progress)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(progress.steps) { StepRow(step: $0) }
                }
                if !progress.partial.isEmpty {
                    DisclosureGroup("Summary so far") {
                        ScrollView {
                            Text(progress.partial)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
                if !progress.log.isEmpty {
                    DisclosureGroup("Messages from the proxy (\(progress.log.count))") {
                        ScrollView {
                            Text(progress.log.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                    }
                }
                buttons(progress)
            } else {
                Text("No summary is running.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ progress: SummaryProgress) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summarizing").font(.headline)
                Text(coordinator.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(progress.startedAt)))
                    .font(.system(.body, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func buttons(_ progress: SummaryProgress) -> some View {
        HStack {
            if progress.finished != nil {
                Button("Open file") { coordinator.openFile() }
                if !progress.partial.isEmpty { Button("Copy summary") { coordinator.copySummary() } }
            } else {
                let waiting = progress.steps.contains {
                    if case .waiting = $0.state { return true }
                    return false
                }
                if progress.awaitingUser || waiting {
                    Button("Retry now") { coordinator.retryNow() }
                }
                Button("Summarize later") { coordinator.later() }
                Button("Cancel") { coordinator.cancel() }
            }
            Spacer()
            Button("Copy details") { coordinator.copyDetails() }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct StepRow: View {
    let step: StepInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .foregroundStyle(step.state == .pending ? .secondary : .primary)
                detail
            }
            Spacer()
            if showsTimer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(SummaryProgressView.clock(context.date.timeIntervalSince(step.since)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var showsTimer: Bool {
        switch step.state {
        case .active, .waiting: return true
        default: return false
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .active:
            ProgressView().controlSize(.small)
        case .waiting:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var detail: some View {
        switch step.state {
        case .pending:
            EmptyView()
        case .active(let text), .done(let text):
            if let text { Text(text).font(.caption).foregroundStyle(.secondary) }
        case .waiting(let message, let retryAt):
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.caption).foregroundStyle(.orange)
                if let retryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                        Text("Trying again in \(left) s").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
