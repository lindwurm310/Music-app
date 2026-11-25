import Foundation

/// サーバーの manifest に含まれる 1 曲。端末側のライブラリにもこの形のまま保存する。
public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var size: Int64
    public var sha256: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var trackNumber: Int
    public var discNumber: Int
    public var year: Int
    public var genre: String
    public var duration: Double
    public var artworkId: String?
    public var fileExtension: String

    public init(id: String, path: String = "", size: Int64 = 0, sha256: String = "",
                title: String, artist: String = "", album: String = "", albumArtist: String = "",
                trackNumber: Int = 0, discNumber: Int = 0, year: Int = 0, genre: String = "",
                duration: Double = 0, artworkId: String? = nil, fileExtension: String = "mp3") {
        self.id = id; self.path = path; self.size = size; self.sha256 = sha256
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.trackNumber = trackNumber; self.discNumber = discNumber; self.year = year
        self.genre = genre; self.duration = duration; self.artworkId = artworkId
        self.fileExtension = fileExtension
    }

    /// 端末内での保存ファイル名（ID ベースなのでファイル名の文字種に依存しない）
    public var fileName: String {
        let ext = fileExtension.filter { $0.isLetter || $0.isNumber }
        return ext.isEmpty ? id : "\(id).\(ext)"
    }

    public var displayArtist: String { artist.isEmpty ? (albumArtist.isEmpty ? "不明なアーティスト" : albumArtist) : artist }
    public var displayAlbum: String { album.isEmpty ? "不明なアルバム" : album }
    public var albumArtistOrArtist: String { albumArtist.isEmpty ? artist : albumArtist }

    /// 同じアルバムかを判定するキー
    public var albumKey: String {
        "\(LibraryText.normalize(albumArtistOrArtist))\u{1F}\(LibraryText.normalize(album))"
    }

    /// 同期の観点で「ファイル以外」の情報が変わったか
    public func metadataDiffers(from other: Track) -> Bool {
        var a = self, b = other
        a.sha256 = ""; b.sha256 = ""; a.size = 0; b.size = 0
        return a != b
    }
}

public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var trackIds: [String]
    /// エポックミリ秒。Last-Writer-Wins の比較に使う
    public var updatedAt: Int64
    public var deleted: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String,
                trackIds: [String] = [], updatedAt: Int64 = Playlist.nowMillis(), deleted: Bool = false) {
        self.id = id; self.name = name; self.trackIds = trackIds
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    public static func nowMillis(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 編集したら必ず呼ぶ。時計がずれていても単調増加させる。
    public mutating func touch(now: Int64 = Playlist.nowMillis()) {
        updatedAt = max(now, updatedAt + 1)
    }
}

public struct Manifest: Codable, Sendable {
    public var protocolVersion: Int
    public var serverVersion: String
    public var serverId: String
    public var serverName: String
    public var generatedAt: Int64
    public var libraryVersion: String
    public var tracks: [Track]
    public var playlists: [Playlist]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case serverVersion, serverId, serverName, generatedAt, libraryVersion, tracks, playlists
    }

    public init(protocolVersion: Int = 1, serverVersion: String = "", serverId: String,
                serverName: String = "", generatedAt: Int64 = 0, libraryVersion: String = "",
                tracks: [Track], playlists: [Playlist] = []) {
        self.protocolVersion = protocolVersion; self.serverVersion = serverVersion
        self.serverId = serverId; self.serverName = serverName; self.generatedAt = generatedAt
        self.libraryVersion = libraryVersion; self.tracks = tracks; self.playlists = playlists
    }
}

public struct ServerInfo: Codable, Sendable, Equatable {
    public var app: String
    public var protocolVersion: Int
    public var serverVersion: String
    public var serverId: String
    public var serverName: String

    enum CodingKeys: String, CodingKey {
        case app, serverVersion, serverId, serverName
        case protocolVersion = "protocol"
    }
}

public enum LibraryText {
    /// 全角/半角・大文字/小文字・空白を吸収した比較用文字列
    public static func normalize(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 並び替え用（先頭の "The " は無視）
    public static func sortKey(_ s: String) -> String {
        let n = normalize(s)
        return n.hasPrefix("the ") ? String(n.dropFirst(4)) : n
    }

    public static func matches(_ track: Track, query: String) -> Bool {
        let q = normalize(query)
        if q.isEmpty { return true }
        let hay = normalize("\(track.title) \(track.artist) \(track.album) \(track.albumArtist)")
        return q.split(separator: " ").allSatisfy { hay.contains($0) }
    }
}
