import Foundation

/// サーバーの manifest と端末の状態から「何をすべきか」を計算する（副作用なし）。
public struct SyncPlan: Equatable, Sendable {
    /// PC でフォルダ移動・名前変更された曲（内容は同じ）。再ダウンロードせず端末内で付け替える
    public struct Relocation: Equatable, Sendable {
        public var fromId: String
        public var track: Track
    }

    /// 新規・内容が変わった曲（ダウンロードが必要）
    public var downloads: [Track] = []
    /// ファイルは同じでタグやアートだけ変わった曲
    public var metadataUpdates: [Track] = []
    /// サーバーから消えた曲（端末から削除）
    public var deletions: [String] = []
    public var relocations: [Relocation] = []
    /// 取得が必要なアートワーク ID
    public var artworkDownloads: [String] = []
    /// どの曲からも参照されなくなったアートワーク ID
    public var artworkDeletions: [String] = []

    public var totalDownloadBytes: Int64 { downloads.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool {
        downloads.isEmpty && metadataUpdates.isEmpty && deletions.isEmpty && relocations.isEmpty
            && artworkDownloads.isEmpty && artworkDeletions.isEmpty
    }

    /// 大量削除の前にユーザーに確認すべきか（PC 側の外付けディスク未接続などの事故防止）
    public var requiresDeletionConfirmation: Bool = false
}

public enum SyncPlanner {
    /// 削除がこの割合を超え、かつ一定数以上なら確認を求める
    public static let massDeletionRatio = 0.5
    public static let massDeletionMinimum = 10

    /// - Parameters:
    ///   - remote: サーバーの曲一覧
    ///   - local: 端末に記録されている曲一覧
    ///   - presentFiles: 端末に実ファイルが存在する曲 ID
    ///   - presentArtwork: 端末に保存済みのアートワーク ID
    public static func plan(remote: [Track], local: [Track],
                            presentFiles: Set<String>, presentArtwork: Set<String>) -> SyncPlan {
        var plan = SyncPlan()
        var localById: [String: Track] = [:]
        for t in local { localById[t.id] = t }
        var remoteIds = Set<String>()

        for track in remote {
            guard remoteIds.insert(track.id).inserted else { continue }  // 重複 ID は無視
            if let existing = localById[track.id], presentFiles.contains(track.id),
               existing.sha256 == track.sha256 {
                if existing.metadataDiffers(from: track) {
                    plan.metadataUpdates.append(track)
                }
            } else {
                plan.downloads.append(track)
            }
        }

        let deletions = Array(Set(local.map(\.id).filter { !remoteIds.contains($0) })).sorted()

        // 消える曲と同じ内容（SHA-256）の新曲があれば、ファイルを付け替えるだけで済む
        var deletableByHash: [String: [String]] = [:]
        for id in deletions where presentFiles.contains(id) {
            if let sha = localById[id]?.sha256, !sha.isEmpty { deletableByHash[sha, default: []].append(id) }
        }
        var relocatedFrom = Set<String>()
        var relocations: [SyncPlan.Relocation] = []
        var downloads: [Track] = []
        for track in plan.downloads {
            if var candidates = deletableByHash[track.sha256], !candidates.isEmpty {
                let from = candidates.removeFirst()
                deletableByHash[track.sha256] = candidates
                relocatedFrom.insert(from)
                relocations.append(SyncPlan.Relocation(fromId: from, track: track))
            } else {
                downloads.append(track)
            }
        }
        plan.downloads = downloads
        plan.relocations = relocations
        plan.deletions = deletions.filter { !relocatedFrom.contains($0) }

        let neededArtwork = Set(remote.compactMap(\.artworkId))
        plan.artworkDownloads = neededArtwork.subtracting(presentArtwork).sorted()
        plan.artworkDeletions = presentArtwork.subtracting(neededArtwork).sorted()

        // アルバム順にダウンロードすると途中で止まっても聴ける単位で揃う
        plan.downloads.sort { a, b in
            (LibraryText.sortKey(a.albumArtistOrArtist), LibraryText.sortKey(a.album), a.discNumber, a.trackNumber, a.id)
                < (LibraryText.sortKey(b.albumArtistOrArtist), LibraryText.sortKey(b.album), b.discNumber, b.trackNumber, b.id)
        }

        let localCount = localById.count
        if localCount > 0 {
            let ratio = Double(plan.deletions.count) / Double(localCount)
            plan.requiresDeletionConfirmation =
                remote.isEmpty || (plan.deletions.count >= massDeletionMinimum && ratio > massDeletionRatio)
        }
        return plan
    }
}

/// プレイリストの Last-Writer-Wins マージ（サーバーと同じ規則。同時刻はサーバー優先）
public enum PlaylistMerge {
    public static func merge(local: [Playlist], server: [Playlist]) -> [Playlist] {
        var result: [String: Playlist] = [:]
        for p in server { result[p.id] = p }
        for p in local {
            if let s = result[p.id] {
                if p.updatedAt > s.updatedAt { result[p.id] = p }
            } else {
                result[p.id] = p
            }
        }
        return result.values.sorted { a, b in
            let ka = LibraryText.sortKey(a.name), kb = LibraryText.sortKey(b.name)
            return ka != kb ? ka < kb : a.id < b.id
        }
    }
}
