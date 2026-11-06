import Foundation
import Security

/// What the user chose in Settings.
public struct ConnectorSettings: Equatable, Sendable {
    public var kind: ConnectorKind = .none
    public var url = ""
    public var model = ""
    public var apiKey = ""

    public init() {}

    private enum Key {
        static let kind = "summaryKind", url = "summaryURL", model = "summaryModel"
    }

    /// True until the user has saved Settings once.
    public static func needsSetup(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.kind) == nil
    }

    public static func load(defaults: UserDefaults = .standard) -> ConnectorSettings {
        var settings = ConnectorSettings()
        settings.kind = ConnectorKind(rawValue: defaults.string(forKey: Key.kind) ?? "") ?? .none
        settings.url = defaults.string(forKey: Key.url) ?? ""
        settings.model = defaults.string(forKey: Key.model) ?? ""
        settings.apiKey = Keychain.read() ?? ""
        return settings
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: Key.kind)
        defaults.set(url, forKey: Key.url)
        defaults.set(model, forKey: Key.model)
        Keychain.write(apiKey)
    }
}

/// The API key lives in the macOS Keychain, never in a plain file.
public enum Keychain {
    private static let service = "com.local.meetnote"
    private static let account = "apiKey"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

public enum ConnectionRules {
    /// Cleans what the user typed: adds http:// if missing, drops a trailing slash or /v1.
    public static func normalize(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") { value.removeLast(3) }
        return URL(string: value)
    }

    /// Plain http:// is only allowed on your own network. Returns a message when the address is not allowed.
    public static func problem(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "The address must start with http:// or https://."
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "The address has no host name." }
        if scheme == "http" && !isPrivate(host) {
            return "Plain http:// is only allowed on your own network. Use https:// for a server on the internet."
        }
        return nil
    }

    /// Short note for Settings: where the transcript text will go.
    public static func destination(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        return isPrivate(host) ? "Your own network (\(host))" : "The internet (\(host))"
    }

    public static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // Tailscale and carrier-grade NAT
        default: return false
        }
    }

    /// One plain-language answer for the Test connection button.
    public static func test(_ config: ProxyConfig) async -> String {
        guard let endpoint = config.endpoints.first else { return "Enter the server address first." }
        if let problem = problem(for: endpoint.url) { return problem }
        let path = config.kind == .gateway ? "health" : "v1/models"
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.timeoutInterval = 15
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                if config.kind == .server,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let list = object["data"] as? [[String: Any]]
                {
                    let names = list.compactMap { $0["id"] as? String }
                    if !config.model.isEmpty, config.model != "default", !names.contains(config.model) {
                        return "Connected, but the model \"\(config.model)\" was not found. Available: \(names.prefix(5).joined(separator: ", "))."
                    }
                    return "Connected. \(names.count) model(s) available."
                }
                return "Connected."
            case 401, 403: return "The server refused the API key (HTTP \(status))."
            case 404: return "Reached a server, but this address does not look right (HTTP 404)."
            default: return "The server answered HTTP \(status)."
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return "No answer. Check the address and that the server is on."
            case .cannotConnectToHost: return "Connection refused. Is the server running?"
            case .cannotFindHost: return "Address not found."
            default: return error.localizedDescription
            }
        } catch {
            return error.localizedDescription
        }
    }
}
