import Foundation
import MusicSyncCore
import Observation

/// 接続先サーバーの設定（アドレスは UserDefaults、トークンは Keychain）
@Observable
@MainActor
final class ServerSettings {
    private(set) var baseURL: URL?
    private(set) var token: String = ""
    private(set) var serverName: String = ""

    private let defaults = UserDefaults.standard

    init() {
        if let s = defaults.string(forKey: "server.url") { baseURL = URL(string: s) }
        serverName = defaults.string(forKey: "server.name") ?? ""
        token = Keychain.get("token") ?? ""
    }

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    /// 表示用（http:// を省略）
    var displayAddress: String {
        guard let baseURL, let host = baseURL.host else { return "" }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    func save(baseURL: URL, token: String, serverName: String) {
        self.baseURL = baseURL
        self.token = token
        self.serverName = serverName
        defaults.set(baseURL.absoluteString, forKey: "server.url")
        defaults.set(serverName, forKey: "server.name")
        Keychain.set(token, for: "token")
    }

    func clear() {
        baseURL = nil
        token = ""
        serverName = ""
        defaults.removeObject(forKey: "server.url")
        defaults.removeObject(forKey: "server.name")
        Keychain.set(nil, for: "token")
    }

    func client() -> APIClient? {
        guard let baseURL, !token.isEmpty else { return nil }
        return APIClient(baseURL: baseURL, token: token)
    }
}
