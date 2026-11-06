import AVFoundation
import AppKit
import SwiftUI

/// Records the mic ("Me") and system audio ("Them"), then transcribes both on this Mac.
/// Audio goes to a temporary folder only while recording and is deleted once the transcript is written.
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var modelReady = false
    @Published var elapsed: TimeInterval = 0
    @Published var message: String?
    @Published var warning: String?
    @Published var status: String?
    @Published var lastTranscript: URL?

    /// Called on the main thread once the transcript file is written.
    var onTranscriptSaved: ((URL) -> Void)?

    private let engine = AVAudioEngine()
    private let tap = SystemAudioTap()
    private let transcriber = Transcriber()
    private let separator = SpeakerSeparator()
    private var micFile: AVAudioFile?
    private var themFile: AVAudioFile?
    private var sessionFolder: URL?
    private var startDate = Date()
    private var timer: Timer?
    private var themHeardSound = false

    init() {
        modelReady = Self.modelsAreOnDisk()
    }

    /// True when the speech and speaker models were already downloaded on an earlier run.
    private static func modelsAreOnDisk() -> Bool {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
        return ["parakeet-tdt-0.6b-v3", "speaker-diarization"].allSatisfy { name in
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: base.appendingPathComponent(name).path)
            return !(contents ?? []).isEmpty
        }
    }

    var elapsedText: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    @MainActor
    private func start() async {
        guard !isProcessing else { return }
        message = nil
        warning = nil
        status = nil
        themHeardSound = false

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            message = "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetNote-temp", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let input = engine.inputNode
            let micFormat = input.outputFormat(forBus: 0)
            micFile = try AVAudioFile(
                forWriting: folder.appendingPathComponent("me.caf"),
                settings: micFormat.settings,
                commonFormat: micFormat.commonFormat,
                interleaved: micFormat.isInterleaved)
            input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                try? self?.micFile?.write(from: buffer)
            }
            try engine.start()

            try tap.start { [weak self] buffer in self?.handleThem(buffer) }
            if let format = tap.format {
                themFile = try AVAudioFile(
                    forWriting: folder.appendingPathComponent("them.caf"),
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved)
            }
        } catch {
            message = error.localizedDescription
            teardown()
            return
        }

        sessionFolder = folder
        startDate = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.startDate)
            if self.themHeardSound {
                self.warning = nil
            } else if self.elapsed > 8 {
                // macOS reports no error when system audio permission is missing; the audio is just silent.
                self.warning = "No sound from the other side yet. If a call is playing, check System Settings > Privacy & Security > Screen & System Audio Recording."
            }
        }
    }

    private func stop() {
        let duration = Date().timeIntervalSince(startDate)
        teardown()
        isRecording = false
        timer?.invalidate()
        timer = nil
        warning = nil

        guard let folder = sessionFolder else { return }
        sessionFolder = nil
        Task { await process(folder: folder, started: startDate, duration: duration) }
    }

    private func process(folder: URL, started: Date, duration: TimeInterval) async {
        await MainActor.run {
            isProcessing = true
            status = modelReady ? "Transcribing…" : "Downloading speech models (first time only), then transcribing…"
        }
        do {
            let meURL = folder.appendingPathComponent("me.caf")
            let themURL = folder.appendingPathComponent("them.caf")

            let meWords = try await transcriber.words(url: meURL)
            await MainActor.run { self.status = "Transcribing the other side…" }
            let themWords = try await transcriber.words(url: themURL)

            // Speaker separation is a bonus: if it fails, everyone on the other side is just "Them".
            await MainActor.run { self.status = "Identifying speakers…" }
            var spans: [SpeakerSpan] = []
            var note = ""
            do {
                if !themWords.isEmpty { spans = try await separator.spans(in: themURL) }
            } catch {
                note = " (Speaker labels failed: \(error.localizedDescription))"
            }

            // Remove words your mic picked up from the speakers (echo of the other side).
            let echo = EchoFilter.echoMask(
                me: meWords.map { ($0.word, $0.startTime) },
                them: themWords.map { ($0.word, $0.startTime) })
            let meClean = zip(meWords, echo).filter { !$0.1 }.map { $0.0 }

            let meSegments = Transcriber.group(words: meClean, labels: meClean.map { _ in "Me" })
            let themSegments = Transcriber.group(
                words: themWords, labels: SpeakerLabeler.labels(for: themWords, spans: spans))

            let url = try TranscriptWriter.write(
                segments: meSegments + themSegments, started: started, duration: duration)
            try? FileManager.default.removeItem(at: folder) // audio is not kept once the transcript exists

            await MainActor.run {
                self.lastTranscript = url
                self.modelReady = true
                self.status = "Transcript saved." + note
                self.isProcessing = false
                self.onTranscriptSaved?(url)
            }
        } catch {
            await MainActor.run {
                self.message = "Transcription failed: \(error.localizedDescription). The audio was kept in: \(folder.path)"
                self.status = nil
                self.isProcessing = false
            }
        }
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap.stop()
        micFile = nil
        themFile = nil
    }

    // Runs on the audio thread.
    private func handleThem(_ buffer: AVAudioPCMBuffer) {
        try? themFile?.write(from: buffer)
        if !themHeardSound, Self.hasSound(buffer) { themHeardSound = true }
    }

    private static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        for channel in 0..<(buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)) {
            for i in 0..<count where abs(data[channel][i]) > 0.0001 { return true }
        }
        return false
    }

    func openTranscript() {
        guard let lastTranscript else { return }
        NSWorkspace.shared.open(lastTranscript)
    }

    func openTranscriptFolder() {
        try? FileManager.default.createDirectory(at: TranscriptWriter.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(TranscriptWriter.folder)
    }
}
