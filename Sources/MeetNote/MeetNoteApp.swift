import AppKit
import Combine
import SummaryKit
import SwiftUI

@main
enum MeetNoteMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon and no windows at launch
        app.run()
    }
}

/// Menu bar icon: left click starts or stops recording, right click opens the menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let summary = SummaryCoordinator()
    private let settingsWindow = SettingsWindowController()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var savedFlashUntil = Date.distantPast
    private var pulseTimer: Timer?
    private var pulsePhase = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(iconClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()

        if ConnectorSettings.needsSetup() {
            DispatchQueue.main.async { self.settingsWindow.show(welcome: true) }
        }

        recorder.onTranscriptSaved = { [weak self] url in self?.summary.start(file: url) }
        summary.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &cancellables)

        summary.onFinished = { [weak self] saved in
            guard let self else { return }
            if saved {
                self.savedFlashUntil = Date().addingTimeInterval(6)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { self.refreshIcon() }
            }
            self.refreshIcon()
        }

        recorder.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &cancellables)

        // Show a checkmark for a few seconds when a transcript has just been saved.
        recorder.$lastTranscript
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.savedFlashUntil = Date().addingTimeInterval(5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { self.refreshIcon() }
            }
            .store(in: &cancellables)
    }

    // MARK: icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        var title = ""
        var tint: NSColor?

        if recorder.isRecording {
            symbol = "mic.fill"
        } else if recorder.isProcessing {
            symbol = "waveform"
            title = " …"
        } else if summary.isRunning, let progress = summary.progress {
            button.image = Self.stepDots(progress.steps, pulse: pulsePhase)
            button.contentTintColor = nil
            button.title = ""
            startPulse()
            return
        } else if recorder.message != nil || recorder.warning != nil {
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
        } else if summary.lastFailed {
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
        } else if Date() < savedFlashUntil {
            symbol = "checkmark.circle"
        } else {
            symbol = "mic"
        }

        stopPulse()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetNote")
        button.contentTintColor = tint
        button.title = title
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulsePhase.toggle()
            self.refreshIcon()
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    /// One dot per step: gray waiting its turn, blinking blue working, green done, orange waiting, red failed.
    private static func stepDots(_ steps: [StepInfo], pulse: Bool) -> NSImage {
        let d: CGFloat = 7, gap: CGFloat = 3.5
        let width = CGFloat(steps.count) * d + CGFloat(steps.count - 1) * gap
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            for (i, step) in steps.enumerated() {
                let rect = NSRect(x: CGFloat(i) * (d + gap), y: 4.5, width: d, height: d)
                let path = NSBezierPath(ovalIn: rect)
                switch step.state {
                case .pending:
                    NSColor.tertiaryLabelColor.setFill()
                case .active:
                    NSColor.systemBlue.withAlphaComponent(pulse ? 1 : 0.35).setFill()
                case .waiting:
                    NSColor.systemOrange.withAlphaComponent(pulse ? 1 : 0.45).setFill()
                case .done:
                    NSColor.systemGreen.setFill()
                case .failed:
                    NSColor.systemRed.setFill()
                }
                path.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: clicks

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showMenu()
        } else {
            recorder.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        for line in [recorder.status, recorder.warning, recorder.message].compactMap({ $0 }) {
            let item = NSMenuItem(title: Self.shorten(line), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if menu.items.isEmpty == false { menu.addItem(.separator()) }

        let toggle = NSMenuItem(
            title: recorder.isRecording ? "Stop and transcribe" : "Start recording",
            action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !recorder.isProcessing
        menu.addItem(toggle)
        menu.addItem(.separator())

        if let progress = summary.progress, summary.isRunning || summary.lastFailed {
            let head = NSMenuItem(title: "Summary: \(Self.shorten(progress.headline))", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for step in progress.steps {
                let mark: String
                var detail: String?
                switch step.state {
                case .pending: mark = "○"
                case .active(let d): mark = "◉"; detail = d
                case .waiting(let m, _): mark = "⏸"; detail = m
                case .done(let d): mark = "✓"; detail = d
                case .failed(let m): mark = "✕"; detail = m
                }
                let line = NSMenuItem(title: "\(mark)  \(step.title)", action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
                if let detail, !detail.isEmpty {
                    let sub = NSMenuItem(title: "      " + Self.shorten(detail), action: nil, keyEquivalent: "")
                    sub.isEnabled = false
                    menu.addItem(sub)
                }
            }
            if summary.isRunning {
                let blocked = progress.awaitingUser || progress.steps.contains {
                    if case .waiting = $0.state { return true }
                    return false
                }
                if blocked {
                    let retry = NSMenuItem(title: "Retry now", action: #selector(retrySummary), keyEquivalent: "")
                    retry.target = self
                    menu.addItem(retry)
                }
                let later = NSMenuItem(title: "Summarize later", action: #selector(laterSummary), keyEquivalent: "")
                later.target = self
                menu.addItem(later)
                let cancel = NSMenuItem(title: "Cancel summary", action: #selector(cancelSummary), keyEquivalent: "")
                cancel.target = self
                menu.addItem(cancel)
            }
            let show = NSMenuItem(title: "Show summary details…", action: #selector(showSummary), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
            menu.addItem(.separator())
        }
        if !summary.isRunning, let last = Self.newestTranscript() {
            let again = NSMenuItem(title: "Re-summarize last transcript", action: #selector(summarizeLast), keyEquivalent: "")
            again.target = self
            again.representedObject = last
            menu.addItem(again)
        }
        menu.addItem(.separator())

        if recorder.lastTranscript != nil {
            let last = NSMenuItem(title: "Open last transcript", action: #selector(openLast), keyEquivalent: "")
            last.target = self
            menu.addItem(last)
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let folder = NSMenuItem(title: "Open transcripts folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MeetNote", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach the menu just long enough to show it, so left clicks keep toggling recording.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// The most recent transcript file, so this works after the app was restarted too.
    private static func newestTranscript() -> URL? {
        let files = TranscriptWriter.allTranscripts()
        return files.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count > 90 ? String(text.prefix(87)) + "…" : text
    }

    @objc private func toggleRecording() { recorder.toggle() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func retrySummary() { summary.retryNow() }
    @objc private func laterSummary() { summary.later() }
    @objc private func cancelSummary() { summary.cancel() }
    @objc private func showSummary() { summary.showWindow() }
    @objc private func summarizeLast(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { summary.start(file: url) }
    }
    @objc private func openLast() { recorder.openTranscript() }
    @objc private func openFolder() { recorder.openTranscriptFolder() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
