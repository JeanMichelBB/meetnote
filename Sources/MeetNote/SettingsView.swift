import AppKit
import ServiceManagement
import SummaryKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?

    func show(welcome: Bool = false) {
        let hosting = NSHostingController(rootView: SettingsView(welcome: welcome) { [weak self] in
            self?.window?.close()
        })
        if window == nil {
            let window = NSWindow(contentViewController: hosting)
            window.title = "MeetNote settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else {
            window?.contentViewController = hosting
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let welcome: Bool
    let onClose: () -> Void

    @State private var settings = ConnectorSettings.load()
    @State private var testResult = ""
    @State private var testing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if welcome {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to MeetNote").font(.title2).bold()
                    Text("Left-click the menu bar icon to start and stop recording. macOS asks for microphone and system audio access the first time. Audio stays on this Mac and is deleted after the transcript is written.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Summary").font(.headline)
                Picker("", selection: $settings.kind) {
                    Text("No summary, transcript only").tag(ConnectorKind.none)
                    Text("AI server (Ollama, LM Studio, OpenAI, ...)").tag(ConnectorKind.server)
                    Text("Wake-on-demand gateway (advanced)").tag(ConnectorKind.gateway)
                }
                .labelsHidden()
                .onChange(of: settings.kind) { _ in testResult = "" }
            }

            if settings.kind != .none {
                VStack(alignment: .leading, spacing: 10) {
                    field("Address", text: $settings.url,
                          prompt: settings.kind == .server ? "http://localhost:11434" : "http://100.x.x.x:11435")
                    if settings.kind == .server {
                        field("Model name", text: $settings.model, prompt: "llama3.1")
                        HStack {
                            Text("API key").frame(width: 90, alignment: .leading)
                            SecureField("optional, stored in the macOS Keychain", text: $settings.apiKey)
                        }
                        Text("Examples: Ollama http://localhost:11434, LM Studio http://localhost:1234, OpenAI https://api.openai.com")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = ConnectionRules.normalize(settings.url) {
                        Label("The transcript text is sent to: \(ConnectionRules.destination(for: url)). Audio never leaves this Mac.",
                              systemImage: ConnectionRules.isPrivate(url.host ?? "") ? "lock.fill" : "globe")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Test connection") { test() }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        Text(testResult).font(.callout).foregroundStyle(testResult.hasPrefix("Connected") ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Toggle("Open MeetNote at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                Spacer()
                Button(welcome ? "Done" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        settings.save()
        UserDefaults.standard.set(true, forKey: "setupDone")
        onClose()
    }

    private func test() {
        testing = true
        testResult = ""
        var config = ProxyConfig(endpoints: [])
        config.kind = settings.kind
        config.apiKey = settings.apiKey
        config.model = settings.model.isEmpty ? "default" : settings.model
        if let url = ConnectionRules.normalize(settings.url) { config.endpoints = [Endpoint(name: "Server", url: url)] }
        Task {
            let result = await ConnectionRules.test(config)
            await MainActor.run {
                testResult = result
                testing = false
            }
        }
    }
}
