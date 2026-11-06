import Foundation

public struct Endpoint: Sendable, Equatable {
    public var name: String
    public var url: URL
    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public enum ConnectorKind: String, Sendable, CaseIterable {
    /// Summaries are turned off.
    case none
    /// Any server that speaks the common chat-completions format (Ollama, LM Studio, OpenAI, ...).
    case server
    /// A gateway that wakes a PC on demand and streams its own progress lines.
    case gateway
}

public struct ProxyConfig: Sendable {
    public var kind: ConnectorKind = .gateway
    public var apiKey = ""
    /// Tried in order.
    public var endpoints: [Endpoint]
    /// A gateway replaces this with its own active model; a normal server needs the real name.
    public var model = "gemma4"
    /// /health and /gpu take 2 to 5 s when the PC is asleep, so this must be generous.
    public var healthTimeout: TimeInterval = 15
    public var unreachableRetrySeconds: TimeInterval = 20
    public var maxUnreachableAttempts = 4
    public var gpuPollSeconds: TimeInterval = 30
    public var maxGPUWaitSeconds: TimeInterval = 6 * 3600
    public var circuitWaitSeconds: TimeInterval = 60
    /// No data at all for this long means the model has stopped responding (the proxy itself uses 300 s).
    public var silenceTimeout: TimeInterval = 360
    /// Estimated tokens above which a long meeting is summarized in parts.
    public var singlePassTokenLimit = 40_000
    public var chunkTokenLimit = 24_000

    public init(endpoints: [Endpoint]) {
        self.endpoints = endpoints
    }

    public static func load(defaults: UserDefaults = .standard) -> ProxyConfig {
        let settings = ConnectorSettings.load(defaults: defaults)
        var config = ProxyConfig(endpoints: [])
        config.kind = settings.kind
        config.apiKey = settings.apiKey
        if let url = ConnectionRules.normalize(settings.url) {
            config.endpoints.append(Endpoint(name: settings.kind == .gateway ? "Gateway" : "Server", url: url))
        }
        if settings.kind == .gateway, let lan = defaults.string(forKey: "proxyLANURL"),
            let url = ConnectionRules.normalize(lan)
        {
            config.endpoints.append(Endpoint(name: "LAN", url: url))
        }
        if settings.kind == .server { config.model = settings.model.isEmpty ? "default" : settings.model }
        return config
    }
}
