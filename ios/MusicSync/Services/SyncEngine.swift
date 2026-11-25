import CryptoKit
import Foundation
import MusicSyncCore
import Observation
import UIKit

/// サーバーとの同期処理。画面はこのオブジェクトの状態を表示するだけ。
@Observable
@MainActor
final class SyncEngine {
    enum Phase: Equatable {
        case idle
        case connecting
        case syncing
        case needsConfirmation(deletions: Int)
        case finished(Summary)
        case failed(String)
    }

    struct Summary: Equatable {
        var downloaded = 0
        var updated = 0
        var deleted = 0
        var failed = 0
        var bytes: Int64 = 0

        var text: String {
            if downloaded == 0 && updated == 0 && deleted == 0 && failed == 0 { return "最新の状態です" }
            var parts: [String] = []
            if downloaded > 0 { parts.append("\(downloaded) 曲追加") }
            if updated > 0 { parts.append("\(updated) 曲更新") }
            if deleted > 0 { parts.append("\(deleted) 曲削除") }
            if failed > 0 { parts.append("\(failed) 曲失敗") }
            return parts.joined(separator: " / ")
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var currentTitle = ""

    var isBusy: Bool { phase == .connecting || phase == .syncing }
    var progress: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    private let store: LibraryStore
    private let settings: ServerSettings
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var playlistPushTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static let maxConcurrentDownloads = 3

    init(store: LibraryStore, settings: ServerSettings) {
        self.store = store
        self.settings = settings
        store.onPlaylistsEdited = { [weak self] in self?.schedulePlaylistPush() }
    }

    // MARK: - 公開操作

    func start(confirmDeletions: Bool = false) {
        guard !isBusy else { return }
        phase = .connecting  // 連打で二重に開始しないよう、ここで同期的に状態を変える
        task = Task { await run(confirmDeletions: confirmDeletions) }
    }

    func cancel() {
        task?.cancel()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func dismissResult() {
        if !isBusy { phase = .idle }
    }

    /// 端末でプレイリストを編集したら、少し待ってからサーバーへ送る（失敗しても次回同期で送られる）
    func schedulePlaylistPush() {
        guard settings.isConfigured else { return }
        playlistPushTask?.cancel()
        playlistPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, !self.isBusy, let client = self.settings.client() else { return }
            if let merged = try? await client.syncPlaylists(self.store.allPlaylists) {
                self.store.applyServerPlaylists(merged)
            }
        }
    }

    // MARK: - 本体

    private func run(confirmDeletions: Bool) async {
        guard let client = settings.client() else {
            phase = .failed("先にサーバーを設定してください")
            return
        }
        phase = .connecting
        completedCount = 0; totalCount = 0; completedBytes = 0; totalBytes = 0; currentTitle = ""

        let app = UIApplication.shared
        // バックグラウンドに回っても少しの間は続ける。時間切れなら中止して途中まで保存
        backgroundTask = app.beginBackgroundTask(withName: "MusicSync") { [weak self] in
            self?.cancel()
            self?.endBackgroundTask()
        }
        app.isIdleTimerDisabled = true  // 同期中は画面ロックしない
        defer {
            app.isIdleTimerDisabled = false
            endBackgroundTask()
        }

        do {
            let manifest = try await client.manifest()
            store.setServer(manifest.serverId)

            // 1) プレイリスト（軽いので先に）
            let merged = try await client.syncPlaylists(store.allPlaylists)
            store.applyServerPlaylists(merged)

            // 2) 差分計算
            let local = Array(store.tracksById.values)
            let present = Set(local.filter { FileManager.default.fileExists(atPath: Paths.audioURL(for: $0).path) }.map(\.id))
            let plan = SyncPlanner.plan(remote: manifest.tracks, local: local,
                                        presentFiles: present, presentArtwork: Self.presentArtwork())
            if plan.requiresDeletionConfirmation && !confirmDeletions {
                phase = .needsConfirmation(deletions: plan.deletions.count)
                return
            }
            phase = .syncing
            var summary = Summary()

            // 3) 移動の付け替え・削除（先に空き容量を作る）・タグ更新
            summary.updated += store.relocate(plan.relocations)
            store.remove(plan.deletions)
            summary.deleted = plan.deletions.count
            store.upsert(plan.metadataUpdates)
            summary.updated += plan.metadataUpdates.count

            // 4) 容量チェック
            if let free = Paths.availableCapacity(), plan.totalDownloadBytes > free - 200_000_000 {
                throw APIError.other("iPhone の空き容量が足りません（必要: \(Formatters.bytes(plan.totalDownloadBytes)) / 空き: \(Formatters.bytes(max(0, free))))")
            }

            // 5) アートワーク（小さいので曲より先に。表示がすぐ揃う）
            await downloadArtwork(plan.artworkDownloads, client: client)
            for id in plan.artworkDeletions {
                try? FileManager.default.removeItem(at: Paths.artworkURL(for: id))
                ArtworkCache.shared.remove(id)
            }

            // 6) 曲のダウンロード
            totalCount = plan.downloads.count
            totalBytes = plan.totalDownloadBytes
            let result = try await downloadTracks(plan.downloads, client: client)
            summary.downloaded = result.ok
            summary.failed = result.failed
            summary.bytes = completedBytes

            store.markSynced()
            phase = .finished(summary)
            // ダウンロード中に端末で編集されたプレイリストを送る
            schedulePlaylistPush()
        } catch is CancellationError {
            store.saveNow()
            phase = .failed("同期を中止しました（ダウンロード済みの曲は残ります）")
        } catch {
            store.saveNow()
            phase = .failed(error.localizedDescription)
        }
    }

    private static func presentArtwork() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.artwork.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
    }

    private func downloadArtwork(_ ids: [String], client: APIClient) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            func addNext() -> Bool {
                guard let id = iterator.next() else { return false }
                group.addTask {
                    guard let data = try? await client.artwork(id), !data.isEmpty else { return }
                    try? data.write(to: Paths.artworkURL(for: id), options: .atomic)
                }
                return true
            }
            for _ in 0..<4 { if !addNext() { break } }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                _ = addNext()
            }
        }
    }

    private enum DownloadOutcome: Sendable {
        case success(Track, Int64)
        case failure(Track)
    }

    private func downloadTracks(_ tracks: [Track], client: APIClient) async throws -> (ok: Int, failed: Int) {
        var ok = 0, failed = 0
        var pending: [Track] = []
        var lastFlush = Date()

        // 中止・エラー時もダウンロード済みの曲は必ず登録する
        defer { store.upsert(pending) }
        try await withThrowingTaskGroup(of: DownloadOutcome.self) { group in
            var iterator = tracks.makeIterator()
            func addNext() -> Bool {
                guard let track = iterator.next() else { return false }
                group.addTask { await Self.download(track, client: client) }
                return true
            }
            for _ in 0..<Self.maxConcurrentDownloads { if !addNext() { break } }

            while let outcome = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case .success(let track, let bytes):
                    ok += 1
                    completedBytes += bytes
                    currentTitle = track.title
                    pending.append(track)
                case .failure(let track):
                    failed += 1
                    completedBytes += track.size
                }
                completedCount += 1
                // 画面更新と保存の負荷を抑えるため、まとめて登録する
                if pending.count >= 20 || Date().timeIntervalSince(lastFlush) > 2 {
                    store.upsert(pending)
                    pending.removeAll()
                    lastFlush = Date()
                }
                _ = addNext()
            }
        }
        return (ok, failed)
    }

    /// 1 曲をダウンロード → SHA-256 検証 → 本来の場所へ移動（MainActor 外で実行）
    nonisolated private static func download(_ track: Track, client: APIClient) async -> DownloadOutcome {
        let fm = FileManager.default
        for attempt in 1...2 {
            if Task.isCancelled { return .failure(track) }
            do {
                let temp = try await client.downloadTrack(track.id)
                defer { try? fm.removeItem(at: temp) }
                guard try sha256(of: temp) == track.sha256 else {
                    throw APIError.other("ハッシュ不一致")
                }
                let dest = Paths.audioURL(for: track)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: dest)
                }
                return .success(track, track.size)
            } catch is CancellationError {
                return .failure(track)
            } catch {
                if attempt == 2 { print("ダウンロード失敗 \(track.title): \(error.localizedDescription)") }
            }
        }
        return .failure(track)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
