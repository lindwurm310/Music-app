import Foundation
import MusicSyncCore

enum APIError: LocalizedError {
    case unauthorized
    case notMusicSyncServer
    case incompatibleProtocol(Int)
    case http(Int, String)
    case cannotConnect
    case timedOut
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "トークンが違います。PC に表示されたトークンを入力し直してください。"
        case .notMusicSyncServer:
            return "MusicSync サーバーではありません。アドレスとポート番号を確認してください。"
        case .incompatibleProtocol(let v):
            return "サーバーのバージョン (protocol \(v)) に対応していません。アプリかサーバーを更新してください。"
        case .http(let code, let message):
            return "サーバーエラー (\(code)): \(message)"
        case .cannotConnect:
            return "サーバーに接続できません。PC で「musicsync serve」が起動しているか、iPhone と PC が同じ Wi-Fi にあるか、設定 > プライバシー > ローカルネットワーク で MusicSync が許可されているか確認してください。"
        case .timedOut:
            return "サーバーの応答がありません（タイムアウト）。"
        case .other(let message):
            return message
        }
    }
}

/// サーバーとの通信。状態を持たないので並行して使ってよい。
struct APIClient: Sendable {
    static let supportedProtocol = 1

    let baseURL: URL
    let token: String
    let session: URLSession

    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, token: String, session: URLSession = APIClient.sharedSession) {
        self.baseURL = baseURL
        self.token = ServerAddress.normalizeToken(token)
        self.session = session
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         authorized: Bool = true, timeout: TimeInterval? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if authorized { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let timeout { req.timeoutInterval = timeout }
        return req
    }

    private static func mapError(_ error: Error) -> Error {
        if error is APIError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return APIError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed, .internationalRoamingOff:
                return APIError.cannotConnect
            default: return APIError.other(urlError.localizedDescription)
            }
        }
        return APIError.other(error.localizedDescription)
    }

    private static func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.other("不正な応答") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String {
                message = e
            }
            throw APIError.http(http.statusCode, message)
        }
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Self.mapError(error)
        }
        try Self.check(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.notMusicSyncServer
        }
    }

    // MARK: - API

    func ping() async throws -> ServerInfo {
        let info = try await send(request("api/ping", authorized: false, timeout: 8), as: ServerInfo.self)
        guard info.app == "MusicSync" else { throw APIError.notMusicSyncServer }
        guard info.protocolVersion == Self.supportedProtocol else {
            throw APIError.incompatibleProtocol(info.protocolVersion)
        }
        return info
    }

    /// トークンが正しいかだけを軽く確認する
    func verifyToken() async throws {
        struct List: Decodable { var playlists: [Playlist] }
        _ = try await send(request("api/playlists", timeout: 10), as: List.self)
    }

    func manifest() async throws -> Manifest {
        let m = try await send(request("api/manifest", timeout: 120), as: Manifest.self)
        guard m.protocolVersion == Self.supportedProtocol else {
            throw APIError.incompatibleProtocol(m.protocolVersion)
        }
        return m
    }

    private struct PlaylistsBody: Codable { var playlists: [Playlist] }

    /// 端末のプレイリスト（削除済み含む）を送り、サーバーでマージされた結果を受け取る
    func syncPlaylists(_ playlists: [Playlist]) async throws -> [Playlist] {
        let body = try JSONEncoder().encode(PlaylistsBody(playlists: playlists))
        return try await send(request("api/playlists/sync", method: "POST", body: body), as: PlaylistsBody.self).playlists
    }

    /// 曲をダウンロードして一時ファイルの URL を返す（呼び出し側で移動すること）
    func downloadTrack(_ id: String) async throws -> URL {
        let req = request("api/tracks/\(id)/audio", timeout: 120)
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: req)
        } catch {
            throw Self.mapError(error)
        }
        do {
            try Self.check(response, data: nil)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        // OS が一時ファイルを消す前に自分の管理下へ移す
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tempURL, to: owned)
        return owned
    }

    func artwork(_ id: String) async throws -> Data {
        let req = request("api/artwork/\(id)")
        do {
            let (data, response) = try await session.data(for: req)
            try Self.check(response, data: data)
            return data
        } catch {
            throw Self.mapError(error)
        }
    }
}
