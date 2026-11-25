import Foundation

public enum ServerAddressError: Error, Equatable, LocalizedError {
    case empty
    case invalid

    public var errorDescription: String? {
        switch self {
        case .empty: return "アドレスを入力してください"
        case .invalid: return "アドレスの形式が正しくありません（例: 192.168.1.10:8765）"
        }
    }
}

public enum ServerAddress {
    public static let defaultPort = 8765

    /// "192.168.1.10", "192.168.1.10:8765", "http://mypc.local:8765/" などを正規化して URL にする
    public static func parse(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 全角で入力されても受け付ける
        text = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "。", with: ".")
        guard !text.isEmpty else { throw ServerAddressError.empty }
        if !text.contains("://") { text = "http://" + text }
        guard var comps = URLComponents(string: text),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              !host.contains(" ")
        else { throw ServerAddressError.invalid }
        comps.scheme = scheme
        if comps.port == nil { comps.port = defaultPort }
        guard let port = comps.port, (1...65535).contains(port) else { throw ServerAddressError.invalid }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        guard let url = comps.url else { throw ServerAddressError.invalid }
        return url
    }

    /// トークンの入力ゆれ（小文字・空白・ハイフン）を吸収
    public static func normalizeToken(_ token: String) -> String {
        token.precomposedStringWithCompatibilityMapping
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
