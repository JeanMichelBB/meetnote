import Foundation

/// Sends a transcript to the gpu-proxy and reports every step, wait and failure along the way.
///
/// The engine only ever talks to the proxy over the network, the same way any chat client does.
/// It never retries a proxy-side failure by itself (the proxy's circuit breaker opens after
/// 3 failures and would lock out other clients), it waits for you instead.
public final class SummaryEngine: @unchecked Sendable {
    private let config: ProxyConfig
    private let transcript: String
    private let title: String
    private let transcriptInfo: String
    private let onChange: @Sendable (SummaryProgress) -> Void
    private let session: URLSession

    private let lock = NSLock()
    private var progress = SummaryProgress()
    private var retryRequested = false
    private var deferRequested = false
    private var cancelRequested = false

    private var unreachableAttempts = 0
    private var gpuWaitStarted: Date?
    private var wakeStartedAt: Date?
    private var modelStartedAt: Date?
    private var lastPartialPush = Date.distantPast

    public init(
        config: ProxyConfig, transcript: String, title: String, transcriptInfo: String,
        onChange: @escaping @Sendable (SummaryProgress) -> Void
    ) {
        self.config = config
        self.transcript = transcript
        self.title = title
        self.transcriptInfo = transcriptInfo
        self.onChange = onChange
        if config.kind == .server {
            progress.steps = progress.steps.filter { [.transcript, .proxy, .summary, .save].contains($0.id) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: controls (safe to call from any thread)

    public func retryNow() { locked { retryRequested = true } }
    public func summarizeLater() { locked { deferRequested = true } }
    public func cancel() { locked { cancelRequested = true } }

    public var currentProgress: SummaryProgress { locked { progress } }

    /// Call after writing the summary into the file.
    public func reportSaved(_ detail: String?) {
        setStep(.save, .done(detail))
        update { $0.finished = .completed("") }
    }

    public func reportSaveFailed(_ reason: String) {
        setStep(.save, .failed(reason))
        update { $0.finished = .failed(reason) }
    }

    // MARK: run

    public func run() async -> Outcome {
        setStep(.transcript, .done(transcriptInfo))

        let estimatedTokens = transcript.count / 3
        let generated: Generated
        if estimatedTokens <= config.singlePassTokenLimit {
            generated = await generate(
                system: Prompt.system, user: Prompt.user(title: title, transcript: transcript), label: nil)
        } else {
            generated = await generateInParts()
        }

        switch generated {
        case .stop(let outcome):
            update { $0.finished = outcome }
            return outcome
        case .text(let text):
            setStep(.save, .active("Writing the summary into the file…"))
            return .completed(text)
        }
    }

    // MARK: long meetings

    private func generateInParts() async -> Generated {
        let limit = config.chunkTokenLimit * 3
        var chunks: [String] = []
        var current = ""
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }

        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let label = "Part \(index + 1) of \(chunks.count)"
            addLog("Long meeting: summarizing in \(chunks.count) parts. \(label)…")
            let result = await generate(
                system: Prompt.partSystem,
                user: Prompt.userPart(title: title, index: index + 1, count: chunks.count, text: chunk),
                label: label)
            switch result {
            case .stop: return result
            case .text(let text): notes.append(text)
            }
        }
        addLog("Combining \(chunks.count) parts into one summary…")
        return await generate(
            system: Prompt.mergeSystem, user: Prompt.userMerge(title: title, notes: notes),
            label: "Combining the parts")
    }

    // MARK: one generation, with all the waiting

    private enum Generated {
        case text(String)
        case stop(Outcome)
    }

    private func generate(system: String, user: String, label: String?) async -> Generated {
        while true {
            if let stop = takeStop() { return .stop(stop) }

            switch await preflight() {
            case .stop(let outcome): return .stop(outcome)
            case .again: continue
            case .ready(let endpoint, let alreadyLoaded):
                switch await stream(
                    endpoint: endpoint, system: system, user: user, label: label,
                    alreadyLoaded: alreadyLoaded)
                {
                case .text(let text): return .text(text)
                case .stop(let outcome): return .stop(outcome)
                case .again: continue
                }
            }
        }
    }

    // MARK: preflight (proxy reachable? PC free?)

    private enum Pre {
        case ready(Endpoint, alreadyLoaded: Bool)
        case again
        case stop(Outcome)
    }

    private struct Health {
        var windowsOnline: Bool
        var ollamaReady: Bool
        var circuit: String
    }

    private func preflight() async -> Pre {
        for id in [StepID.proxy, .pc, .wake, .model, .summary] { setStep(id, .pending) }
        update { $0.partial = "" }

        guard let first = config.endpoints.first else {
            setStep(.proxy, .failed("No server address is set. Open Settings from the menu."))
            return .stop(.failed("No server address is set."))
        }
        if let problem = ConnectionRules.problem(for: first.url) {
            setStep(.proxy, .failed(problem))
            return .stop(.failed(problem))
        }
        if config.kind == .server {
            setStep(.proxy, .active("Contacting the server…"))
            return .ready(first, alreadyLoaded: false)
        }

        // 1. Reach the proxy
        setStep(.proxy, .active("Contacting the proxy…"))
        // Both endpoints are slow (2 to 5 s) while the PC is asleep, because the proxy pings it,
        // so ask for both at once and accept either answer as proof the proxy is reachable.
        var found: (endpoint: Endpoint, health: Health, ms: Int, gpu: [String: Any]?)?
        var errors: [String] = []
        for endpoint in config.endpoints {
            let started = Date()
            async let healthResult = fetchResult(endpoint.url.appendingPathComponent("health"), timeout: config.healthTimeout)
            async let gpuResult = fetchResult(endpoint.url.appendingPathComponent("gpu"), timeout: config.healthTimeout)
            let (healthOutcome, gpuOutcome) = await (healthResult, gpuResult)
            let ms = Int(Date().timeIntervalSince(started) * 1000)

            let gpuJSON = try? gpuOutcome.get()
            if let json = try? healthOutcome.get() {
                let health = Health(
                    windowsOnline: json["windows_online"] as? Bool ?? false,
                    ollamaReady: json["ollama_ready"] as? Bool ?? false,
                    circuit: json["circuit_breaker"] as? String ?? "closed")
                found = (endpoint, health, ms, gpuJSON)
                break
            } else if let gpuJSON {
                // /health did not answer but /gpu did: the proxy is up, assume the model is not loaded.
                let health = Health(
                    windowsOnline: gpuJSON["windows_online"] as? Bool ?? false, ollamaReady: false,
                    circuit: "closed")
                found = (endpoint, health, ms, gpuJSON)
                break
            } else if case .failure(let error) = healthOutcome {
                errors.append("\(endpoint.name): \(Self.describe(error))")
            }
        }

        guard let found else {
            unreachableAttempts += 1
            let why = config.endpoints.isEmpty
                ? "No proxy address is set." : "Can't reach the proxy (\(errors.joined(separator: "; ")))."
            if unreachableAttempts >= config.maxUnreachableAttempts {
                setStep(.proxy, .failed("\(why) Check Tailscale or your network."))
                switch await waitForUser() {
                case .retry: unreachableAttempts = 0; return .again
                case .stop(let outcome): return .stop(outcome)
                case .elapsed: return .again
                }
            }
            let retryAt = Date().addingTimeInterval(config.unreachableRetrySeconds)
            setStep(.proxy, .waiting("\(why) Trying again…", retryAt: retryAt))
            return await after(wait(config.unreachableRetrySeconds))
        }
        unreachableAttempts = 0
        setStep(.proxy, .done("via \(found.endpoint.name), \(found.ms) ms"))

        // 2. Is the PC usable?
        setStep(.pc, .active("Checking whether the PC is in use…"))

        if found.health.circuit == "open" {
            let retryAt = Date().addingTimeInterval(config.circuitWaitSeconds)
            setStep(
                .pc,
                .waiting(
                    "The proxy is pausing after earlier failures. Waiting before trying again.",
                    retryAt: retryAt))
            return await after(wait(config.circuitWaitSeconds))
        }

        if let gpu = found.gpu, gpu["game_running"] as? Bool == true {
            return await waitForGPU(reason: gpu["game_process"] as? String)
        }
        gpuWaitStarted = nil

        let alreadyLoaded = found.health.windowsOnline && found.health.ollamaReady
        if alreadyLoaded {
            setStep(.pc, .done("PC is on and the model is already loaded"))
        } else if found.health.windowsOnline {
            setStep(.pc, .done("PC is on, the model is not loaded yet"))
        } else {
            setStep(.pc, .done("PC is asleep (last known state: not in use), it will be woken"))
        }
        return .ready(found.endpoint, alreadyLoaded: alreadyLoaded)
    }

    private func waitForGPU(reason: String?) async -> Pre {
        if gpuWaitStarted == nil { gpuWaitStarted = Date() }
        let message = Self.gpuMessage(reason)
        if Date().timeIntervalSince(gpuWaitStarted!) > config.maxGPUWaitSeconds {
            setStep(.pc, .failed("\(message) Still in use after a long wait."))
            switch await waitForUser() {
            case .retry: gpuWaitStarted = nil; return .again
            case .stop(let outcome): return .stop(outcome)
            case .elapsed: return .again
            }
        }
        let retryAt = Date().addingTimeInterval(config.gpuPollSeconds)
        setStep(.pc, .waiting("\(message) Checking again soon.", retryAt: retryAt))
        return await after(wait(config.gpuPollSeconds))
    }

    private static func gpuMessage(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "The PC is in use." }
        if reason == "session_unlocked" { return "The PC is unlocked, so it looks like a game is running." }
        return "The PC is in use (\(reason))."
    }

    private func after(_ result: WaitResult) async -> Pre {
        switch result {
        case .stop(let outcome): return .stop(outcome)
        case .elapsed, .retry: return .again
        }
    }

    // MARK: streaming request

    private enum StreamResult {
        case text(String)
        case again
        case stop(Outcome)
    }

    private enum Problem {
        case gpuBusy(String)
        case circuit(String)
        case wake(String)
        case ssh(String)
        case start(String)
        case other(String)
    }

    private func classify(_ detail: String) -> Problem {
        let lower = detail.lowercased()
        if lower.contains("gpu in use") { return .gpuBusy(detail) }
        if lower.contains("retry in") || lower.contains("windows unreachable") { return .circuit(detail) }
        if lower.contains("did not come online") { return .wake(detail) }
        if lower.contains("over ssh") { return .ssh(detail) }
        if lower.contains("did not start in time") { return .start(detail) }
        return .other(detail)
    }

    private func stream(
        endpoint: Endpoint, system: String, user: String, label: String?, alreadyLoaded: Bool
    ) async -> StreamResult {
        var request = URLRequest(url: endpoint.url.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = config.silenceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        let started = Date()
        let body: [String: Any] = [
            "model": config.model, "stream": true, "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        setStep(
            .wake,
            .active(alreadyLoaded ? "Sending the request…" : "Waiting for the proxy to get the PC ready…"))

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            let result = try await session.bytes(for: request)
            bytes = result.0
            response = result.1
        } catch {
            return await failedConnection(error, endpoint: endpoint)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            do { for try await byte in bytes { data.append(byte) } } catch {}
            let detail = Self.errorDetail(from: data, status: http.statusCode)
            if config.kind == .server {
                let code = http.statusCode
                let message: String
                switch code {
                case 401, 403: message = "The server refused the API key (HTTP \(code)). Check the key in Settings."
                case 404: message = "Not found (HTTP 404): \(detail). Check the address and the model name in Settings."
                default: message = "The server answered HTTP \(code): \(detail)"
                }
                addLog(message)
                setStep(.proxy, .failed(message))
                return await userDecision()
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return await handle(problem: classify(detail), retryAfter: retryAfter, httpStatus: http.statusCode)
        }

        if config.kind == .server {
            setStep(.proxy, .done("reached in \(Int(Date().timeIntervalSince(started) * 1000)) ms"))
            setStep(.summary, .active(label ?? "Writing the summary…"))
        }
        if alreadyLoaded {
            setStep(.wake, .done("PC already on"))
            setStep(.model, .done("Model already loaded"))
            setStep(.summary, .active(label ?? "Writing the summary…"))
        }

        // Read the stream. Before the answer, the proxy reports its own progress as "> text" lines.
        enum Phase { case undecided, progress, afterProgress, answer }
        var phase = Phase.undecided
        var answer = ""
        var sawDone = false
        var errorDetail: String?
        var finishReason: String?

        do {
            for try await line in bytes.lines {
                if let stop = takeStop() { return .stop(stop) }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { sawDone = true; break }
                guard let data = payload.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choice = (object["choices"] as? [[String: Any]])?.first
                else { continue }
                if let reason = choice["finish_reason"] as? String { finishReason = reason }
                guard let content = (choice["delta"] as? [String: Any])?["content"] as? String else { continue }

                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                switch phase {
                case .undecided, .progress, .afterProgress:
                    if config.kind == .gateway && trimmed.hasPrefix(">") {
                        // A progress line from the proxy, or its error message.
                        phase = .progress
                        let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                        if text.hasPrefix("Error:") {
                            errorDetail = text.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
                            addLog("Error: \(errorDetail ?? "")")
                            phase = .afterProgress
                        } else {
                            handleProgressLine(text)
                        }
                    } else if trimmed.isEmpty && phase != .undecided {
                        // Blank separator: the real answer or an error message follows.
                        phase = .afterProgress
                    } else {
                        phase = .answer
                        answerStarted(label: label)
                        answer += content
                        pushPartial(answer)
                    }
                case .answer:
                    answer += content
                    pushPartial(answer)
                }
            }
        } catch {
            pushPartial(answer, force: true)
            if (error as? URLError)?.code == .timedOut {
                setStep(
                    phase == .answer || config.kind == .server ? .summary : .wake,
                    .failed("The model stopped responding (no data for \(Int(config.silenceTimeout)) s)."))
                return await userDecision()
            }
            return await cutOff(endpoint: endpoint, reason: Self.describe(error))
        }
        pushPartial(answer, force: true)

        if let errorDetail, answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await handle(problem: classify(errorDetail), retryAfter: nil, httpStatus: 200)
        }
        if !sawDone {
            return await cutOff(endpoint: endpoint, reason: "The connection closed before the summary was complete.")
        }
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            setStep(.summary, .failed("The model returned an empty summary."))
            return await userDecision()
        }
        var result = cleaned
        if finishReason == "length" {
            result += "\n\n_The summary may be incomplete: the model reached its length limit._"
        }
        setStep(.summary, .done("\(result.split(separator: " ").count) words"))
        return .text(result)
    }

    // MARK: progress lines from the proxy

    private func handleProgressLine(_ text: String) {
        addLog(text)
        let lower = text.lowercased()
        if lower.contains("windows online") {
            let seconds = wakeStartedAt.map { Int(Date().timeIntervalSince($0)) }
            setStep(.wake, .done(seconds.map { "PC online after \($0) s" } ?? "PC online"))
        } else if lower.contains("wol") || lower.contains("windows offline") {
            wakeStartedAt = Date()
            setStep(.wake, .active("Wake-on-LAN sent, waiting for the PC (up to about 2 minutes)"))
        } else if lower.contains("ssh start") || lower.contains("ollama down") {
            if !isDone(.wake) { setStep(.wake, .done("PC already on")) }
            modelStartedAt = Date()
            setStep(.model, .active("Starting the model service (up to about 2.5 minutes)"))
        } else if lower.contains("ollama ready") {
            if !isDone(.wake) { setStep(.wake, .done("PC already on")) }
            let seconds = modelStartedAt.map { Int(Date().timeIntervalSince($0)) }
            setStep(.model, .done(seconds.map { "Ready after \($0) s" } ?? "Ready"))
        } else {
            // Any other line (SSH attempts, fallbacks, warnings) becomes the detail of the running step.
            for id in [StepID.model, .wake] {
                if case .active = state(of: id) { setStep(id, .active(text)); break }
            }
        }
    }

    private func answerStarted(label: String?) {
        if !isDone(.wake) { setStep(.wake, .done("PC already on")) }
        if !isDone(.model) { setStep(.model, .done("Model ready")) }
        setStep(.summary, .active(label ?? "Writing the summary…"))
    }

    private func pushPartial(_ text: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPartialPush) > 0.25 else { return }
        lastPartialPush = Date()
        update { $0.partial = text }
    }

    // MARK: problems

    private func handle(problem: Problem, retryAfter: TimeInterval?, httpStatus: Int) async -> StreamResult {
        switch problem {
        case .gpuBusy(let detail):
            let seconds = max(config.gpuPollSeconds, retryAfter ?? 0)
            setStep(
                .pc,
                .waiting("\(Self.gpuMessage(Self.reason(in: detail))) Checking again soon.", retryAt: Date().addingTimeInterval(seconds)))
            return await again(wait(seconds))
        case .circuit(let detail):
            let seconds = max(config.circuitWaitSeconds, retryAfter ?? 0)
            setStep(
                .pc,
                .waiting("\(detail) The proxy is pausing after earlier failures.", retryAt: Date().addingTimeInterval(seconds)))
            return await again(wait(seconds))
        case .wake(let detail):
            setStep(.wake, .failed(detail))
        case .ssh(let detail):
            setStep(isDone(.wake) ? .model : .wake, .failed(detail))
        case .start(let detail):
            setStep(.model, .failed(detail))
        case .other(let detail):
            let message = httpStatus == 200 ? detail : "The proxy answered \(httpStatus): \(detail)"
            setStep(currentStepForFailure(), .failed(message))
        }
        return await userDecision()
    }

    private func failedConnection(_ error: Error, endpoint: Endpoint) async -> StreamResult {
        let reason = Self.describe(error)
        if config.kind == .server {
            setStep(.proxy, .failed("Can't reach the server (\(reason)). Check the address in Settings."))
        } else if (error as? URLError)?.code == .timedOut {
            setStep(.wake, .failed("The proxy did not answer (\(reason))."))
        } else {
            setStep(.proxy, .failed("Lost the connection to the proxy (\(reason))."))
        }
        return await userDecision()
    }

    /// The stream ended early. If the PC started a game, wait for it; otherwise ask you.
    private func cutOff(endpoint: Endpoint, reason: String) async -> StreamResult {
        if config.kind == .gateway, let gpu = try? await getJSON(endpoint.url.appendingPathComponent("gpu"), timeout: config.healthTimeout),
            gpu["game_running"] as? Bool == true
        {
            addLog("The summary was cut off because the PC is now in use.")
            let seconds = config.gpuPollSeconds
            setStep(
                .pc,
                .waiting(
                    "The summary was cut off. \(Self.gpuMessage(gpu["game_process"] as? String)) Starting over when it is free.",
                    retryAt: Date().addingTimeInterval(seconds)))
            return await again(wait(seconds))
        }
        setStep(.summary, .failed("The summary was cut off. \(reason)"))
        return await userDecision()
    }

    private func userDecision() async -> StreamResult {
        switch await waitForUser() {
        case .retry, .elapsed: return .again
        case .stop(let outcome): return .stop(outcome)
        }
    }

    private func again(_ result: WaitResult) async -> StreamResult {
        switch result {
        case .stop(let outcome): return .stop(outcome)
        case .elapsed, .retry: return .again
        }
    }

    private func currentStepForFailure() -> StepID {
        for id in [StepID.summary, .model, .wake] {
            if case .active = state(of: id) { return id }
        }
        return .summary
    }

    // MARK: waiting

    private enum WaitResult {
        case elapsed
        case retry
        case stop(Outcome)
    }

    private func wait(_ seconds: TimeInterval) async -> WaitResult {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if Task.isCancelled { return .stop(.cancelled) }
            if let stop = takeStop() { return .stop(stop) }
            if takeRetry() { return .retry }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return .elapsed
    }

    /// Stops until you click Retry, Summarize later or Cancel.
    private func waitForUser() async -> WaitResult {
        update { $0.awaitingUser = true }
        defer { update { $0.awaitingUser = false } }
        while true {
            if Task.isCancelled { return .stop(.cancelled) }
            if let stop = takeStop() { return .stop(stop) }
            if takeRetry() { return .retry }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: helpers

    private func fetchResult(_ url: URL, timeout: TimeInterval) async -> Result<[String: Any], Error> {
        do { return .success(try await getJSON(url, timeout: timeout)) } catch { return .failure(error) }
    }

    private func getJSON(_ url: URL, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    private static func errorDetail(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String { return detail }
            if let error = object["error"] as? String { return error }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "HTTP \(status)" : String(text.prefix(200))
    }

    private static func reason(in detail: String) -> String? {
        // "GPU in use by session_unlocked — can't load..."
        guard let range = detail.range(of: "GPU in use by ") else { return nil }
        let rest = detail[range.upperBound...]
        return rest.split(whereSeparator: { $0 == " " || $0 == "." }).first.map(String.init)
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut: return "no answer"
        case .cannotConnectToHost: return "connection refused"
        case .cannotFindHost: return "address not found"
        case .notConnectedToInternet: return "no network"
        case .networkConnectionLost: return "connection lost"
        default: return urlError.localizedDescription
        }
    }

    private func isDone(_ id: StepID) -> Bool {
        if case .done = state(of: id) { return true }
        return false
    }

    private func state(of id: StepID) -> StepState {
        locked { progress.steps.first(where: { $0.id == id })?.state ?? .pending }
    }

    private func takeStop() -> Outcome? {
        locked {
            if cancelRequested { return .cancelled }
            if deferRequested { return .deferred }
            return nil
        }
    }

    private func takeRetry() -> Bool {
        locked {
            let requested = retryRequested
            retryRequested = false
            return requested
        }
    }

    private func setStep(_ id: StepID, _ state: StepState) {
        update { progress in
            guard let index = progress.steps.firstIndex(where: { $0.id == id }) else { return }
            if progress.steps[index].state != state {
                progress.steps[index].state = state
                progress.steps[index].since = Date()
            }
        }
    }

    private func addLog(_ line: String) {
        update { $0.log.append(line) }
    }

    private func update(_ change: (inout SummaryProgress) -> Void) {
        let snapshot: SummaryProgress = locked {
            change(&progress)
            return progress
        }
        onChange(snapshot)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
