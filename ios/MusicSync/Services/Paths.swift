import Foundation
import MusicSyncCore

/// 端末内の保存場所
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MusicSync", isDirectory: true)
    }()
    static let audio = root.appendingPathComponent("Audio", isDirectory: true)
    static let artwork = root.appendingPathComponent("Artwork", isDirectory: true)
    static let libraryFile = root.appendingPathComponent("library.json")

    static func audioURL(for track: Track) -> URL { audio.appendingPathComponent(track.fileName) }

    static func artworkURL(for id: String) -> URL { artwork.appendingPathComponent("\(id).jpg") }

    static func prepare() {
        let fm = FileManager.default
        for dir in [root, audio, artwork] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // 音楽は PC から再同期できるので iCloud バックアップの容量を使わない
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var audioDir = audio
        try? audioDir.setResourceValues(values)
        var artDir = artwork
        try? artDir.setResourceValues(values)
    }

    static func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func usedBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in [audio, artwork] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for url in items {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
