import Foundation
import MusicSyncCore
import Observation
import SwiftUI  // Array.move(fromOffsets:toOffset:)

/// 端末内の音楽ライブラリとプレイリスト。すべて MainActor で扱う。
@Observable
@MainActor
final class LibraryStore {
    private struct Snapshot: Codable {
        var version: Int = 1
        var serverId: String?
        var tracks: [Track]
        var playlists: [Playlist]
        var lastSync: Date?
    }

    private(set) var tracksById: [String: Track] = [:]
    /// 削除済み (tombstone) も含む全プレイリスト
    private(set) var allPlaylists: [Playlist] = []
    private(set) var serverId: String?
    private(set) var lastSync: Date?

    /// 並び替え済みキャッシュ（画面表示用）
    private(set) var sortedTracks: [Track] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []

    /// 曲が追加・削除されたときに呼ばれる（プレイヤーのキュー追従用）
    @ObservationIgnored var onTracksChanged: (([String: Track]) -> Void)?
    /// プレイリストを端末で編集したときに呼ばれる（サーバーへの送信用）
    @ObservationIgnored var onPlaylistsEdited: (() -> Void)?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        Paths.prepare()
        load()
    }

    var playlists: [Playlist] { allPlaylists.filter { !$0.deleted } }
    var isEmpty: Bool { tracksById.isEmpty }

    func track(_ id: String) -> Track? { tracksById[id] }

    func tracks(of playlist: Playlist) -> [Track] {
        LibraryIndex.resolve(playlist, in: tracksById)
    }

    func playlist(_ id: String) -> Playlist? {
        allPlaylists.first { $0.id == id && !$0.deleted }
    }

    // MARK: - 永続化

    private func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile) else { return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            serverId = snap.serverId
            lastSync = snap.lastSync
            allPlaylists = snap.playlists
            // 実ファイルが無い曲は読み込まない（次回同期で再取得される）
            let fm = FileManager.default
            tracksById = Dictionary(
                snap.tracks.filter { fm.fileExists(atPath: Paths.audioURL(for: $0).path) }.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            rebuildIndex()
        } catch {
            // 壊れたファイルは退避して空から始める（音声ファイルは次の同期で再利用される）
            try? FileManager.default.moveItem(at: Paths.libraryFile,
                                              to: Paths.libraryFile.appendingPathExtension("corrupt"))
        }
    }

    /// 連続した変更をまとめて 0.5 秒後に保存
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snap = Snapshot(serverId: serverId, tracks: Array(tracksById.values),
                            playlists: allPlaylists, lastSync: lastSync)
        do {
            let data = try JSONEncoder().encode(snap)
            try data.write(to: Paths.libraryFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("ライブラリ保存失敗: \(error)")
        }
    }

    private func rebuildIndex() {
        let values = Array(tracksById.values)
        sortedTracks = LibraryIndex.sortedTracks(values)
        albums = LibraryIndex.albums(values)
        artists = LibraryIndex.artists(values)
    }

    private func tracksDidChange() {
        rebuildIndex()
        onTracksChanged?(tracksById)
        scheduleSave()
    }

    // MARK: - 同期から呼ばれる操作

    func setServer(_ id: String) {
        serverId = id
        scheduleSave()
    }

    func markSynced() {
        lastSync = Date()
        saveNow()
    }

    /// ダウンロード済みの曲を登録（多数の曲を追加する時は batch で）
    func upsert(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        for t in tracks { tracksById[t.id] = t }
        tracksDidChange()
    }

    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let fm = FileManager.default
        for id in ids {
            if let t = tracksById.removeValue(forKey: id) {
                try? fm.removeItem(at: Paths.audioURL(for: t))
            }
        }
        tracksDidChange()
    }

    /// PC で移動された曲のファイルを付け替える（失敗した曲は次回の同期でダウンロードされる）
    func relocate(_ items: [SyncPlan.Relocation]) {
        guard !items.isEmpty else { return }
        let fm = FileManager.default
        for r in items {
            guard let old = tracksById.removeValue(forKey: r.fromId) else { continue }
            let src = Paths.audioURL(for: old), dst = Paths.audioURL(for: r.track)
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
                tracksById[r.track.id] = r.track
            } catch {
                try? fm.removeItem(at: src)
            }
        }
        tracksDidChange()
    }

    /// サーバーでマージ済みのプレイリストを反映（同期中に端末で編集された分は LWW で残す）
    func applyServerPlaylists(_ server: [Playlist]) {
        allPlaylists = PlaylistMerge.merge(local: allPlaylists, server: server)
        scheduleSave()
    }

    /// 端末の音楽を全削除（プレイリストは残す）
    func removeAllMusic() {
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.audio)
        try? fm.removeItem(at: Paths.artwork)
        Paths.prepare()
        ArtworkCache.shared.removeAll()
        tracksById = [:]
        serverId = nil
        lastSync = nil
        tracksDidChange()
        saveNow()
    }

    // MARK: - プレイリスト編集（端末側）

    private func editPlaylist(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let i = allPlaylists.firstIndex(where: { $0.id == id && !$0.deleted }) else { return }
        change(&allPlaylists[i])
        allPlaylists[i].touch()
        playlistsEdited()
    }

    private func playlistsEdited() {
        scheduleSave()
        onPlaylistsEdited?()
    }

    @discardableResult
    func createPlaylist(name: String, trackIds: [String] = []) -> Playlist? {
        let trimmed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty else { return nil }
        let p = Playlist(name: String(trimmed.prefix(200)), trackIds: trackIds)
        allPlaylists.append(p)
        allPlaylists.sort { LibraryText.sortKey($0.name) < LibraryText.sortKey($1.name) }
        playlistsEdited()
        return p
    }

    func renamePlaylist(_ id: String, to name: String) {
        let trimmed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty else { return }
        editPlaylist(id) { $0.name = String(trimmed.prefix(200)) }
    }

    func deletePlaylist(_ id: String) {
        editPlaylist(id) {
            $0.deleted = true
            $0.trackIds = []
        }
    }

    func addTracks(_ trackIds: [String], to id: String) {
        guard !trackIds.isEmpty else { return }
        editPlaylist(id) { $0.trackIds.append(contentsOf: trackIds) }
    }

    /// 表示中の行（端末に存在する曲だけの並び）の位置で削除する
    func removeTracks(atVisible offsets: IndexSet, from id: String) {
        editPlaylist(id) { p in
            let visible = visibleIndices(of: p)
            let targets = Set(offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil })
            p.trackIds = p.trackIds.enumerated().filter { !targets.contains($0.offset) }.map(\.element)
        }
    }

    /// 表示中の行の並べ替え。端末に無い曲（未同期）の位置は保ったまま入れ替える
    func moveTracks(atVisible source: IndexSet, to destination: Int, in id: String) {
        editPlaylist(id) { p in
            let visible = visibleIndices(of: p)
            var visibleIds = visible.map { p.trackIds[$0] }
            visibleIds.move(fromOffsets: source, toOffset: destination)
            for (slot, newId) in zip(visible, visibleIds) { p.trackIds[slot] = newId }
        }
    }

    private func visibleIndices(of p: Playlist) -> [Int] {
        p.trackIds.indices.filter { tracksById[p.trackIds[$0]] != nil }
    }
}
