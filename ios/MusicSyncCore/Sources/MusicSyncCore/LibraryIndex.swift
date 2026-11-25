import Foundation

public struct Album: Identifiable, Hashable, Sendable {
    public var id: String          // albumKey
    public var title: String
    public var artist: String
    public var year: Int
    public var artworkId: String?
    public var tracks: [Track]
}

public struct Artist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var albums: [Album]
    public var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
}

/// 画面表示用の並び替え・グルーピング
public enum LibraryIndex {
    public static func sortedTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted { a, b in
            let ka = LibraryText.sortKey(a.title), kb = LibraryText.sortKey(b.title)
            if ka != kb { return ka < kb }
            return a.id < b.id
        }
    }

    public static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        (a.discNumber, a.trackNumber, LibraryText.sortKey(a.title), a.id)
            < (b.discNumber, b.trackNumber, LibraryText.sortKey(b.title), b.id)
    }

    public static func albums(_ tracks: [Track]) -> [Album] {
        var groups: [String: [Track]] = [:]
        for t in tracks { groups[t.albumKey, default: []].append(t) }
        return groups.map { key, items in
            let sorted = items.sorted(by: albumOrder)
            let first = sorted[0]
            return Album(
                id: key,
                title: first.displayAlbum,
                artist: first.albumArtistOrArtist.isEmpty ? "不明なアーティスト" : first.albumArtistOrArtist,
                year: sorted.map(\.year).max() ?? 0,
                artworkId: sorted.lazy.compactMap(\.artworkId).first,
                tracks: sorted
            )
        }
        .sorted { a, b in
            let ka = LibraryText.sortKey(a.title), kb = LibraryText.sortKey(b.title)
            return ka != kb ? ka < kb : a.id < b.id
        }
    }

    public static func artists(_ tracks: [Track]) -> [Artist] {
        var groups: [String: [Track]] = [:]
        for t in tracks {
            let name = t.albumArtistOrArtist.isEmpty ? "不明なアーティスト" : t.albumArtistOrArtist
            groups[LibraryText.normalize(name), default: []].append(t)
        }
        return groups.map { key, items in
            let albums = Self.albums(items).sorted { a, b in
                a.year != b.year ? a.year < b.year : LibraryText.sortKey(a.title) < LibraryText.sortKey(b.title)
            }
            return Artist(id: key, name: items[0].albumArtistOrArtist.isEmpty ? "不明なアーティスト" : items[0].albumArtistOrArtist, albums: albums)
        }
        .sorted { LibraryText.sortKey($0.name) < LibraryText.sortKey($1.name) }
    }

    /// プレイリストの曲 ID を実在する曲に解決（端末に無い曲は除外）
    public static func resolve(_ playlist: Playlist, in byId: [String: Track]) -> [Track] {
        playlist.trackIds.compactMap { byId[$0] }
    }
}

public enum Formatters {
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return i == 0 ? "\(count) B" : "\(String(format: "%.1f", value)) \(units[i])"
    }
}
