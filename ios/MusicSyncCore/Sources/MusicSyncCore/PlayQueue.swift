import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    public var next: RepeatMode {
        switch self { case .off: return .all; case .all: return .one; case .one: return .off }
    }
}

/// 再生キュー（AVFoundation に依存しない純粋なロジック）
public struct PlayQueue: Equatable, Sendable {
    /// 元の並び
    public private(set) var original: [Track] = []
    /// 実際に再生する並び（シャッフル時は並べ替え済み）
    public private(set) var items: [Track] = []
    public private(set) var index: Int = 0
    public private(set) var isShuffled = false
    public var repeatMode: RepeatMode = .off

    public init() {}

    public var current: Track? { items.indices.contains(index) ? items[index] : nil }
    public var isEmpty: Bool { items.isEmpty }
    public var upNext: [Track] {
        guard !items.isEmpty, index + 1 < items.count else { return [] }
        return Array(items[(index + 1)...])
    }

    public mutating func start(_ tracks: [Track], at start: Int = 0, shuffle: Bool = false) {
        original = tracks
        items = tracks
        index = tracks.indices.contains(start) ? start : 0
        isShuffled = false
        if shuffle { setShuffle(true) }
    }

    /// シャッフル切替。再生中の曲は先頭に固定して途切れないようにする
    public mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using rng: inout G) {
        guard on != isShuffled else { return }
        let playing = current
        if on {
            var rest = original
            if let playing, let i = rest.firstIndex(where: { $0.id == playing.id }) { rest.remove(at: i) }
            rest.shuffle(using: &rng)
            items = (playing.map { [$0] } ?? []) + rest
            index = 0
        } else {
            items = original
            if let playing, let i = original.firstIndex(where: { $0.id == playing.id }) { index = i } else { index = 0 }
        }
        isShuffled = on
    }

    public mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    /// 曲が最後まで再生されたとき。次に再生する曲を返す（nil = 停止）
    public mutating func advanceAfterFinish() -> Track? {
        guard !items.isEmpty else { return nil }
        if repeatMode == .one { return current }
        return moveNext(wrap: repeatMode == .all)
    }

    /// 「次へ」ボタン。最後の曲なら先頭に戻る（停止はしない）
    public mutating func skipNext() -> Track? {
        guard !items.isEmpty else { return nil }
        return moveNext(wrap: true)
    }

    private mutating func moveNext(wrap: Bool) -> Track? {
        if index + 1 < items.count {
            index += 1
            return current
        }
        guard wrap else { return nil }
        index = 0
        return current
    }

    /// 「前へ」ボタン。3 秒以上再生していたら曲の頭に戻る
    public mutating func skipPrevious(elapsed: Double) -> (track: Track?, restart: Bool) {
        guard !items.isEmpty else { return (nil, false) }
        if elapsed > 3 || (index == 0 && repeatMode != .all) { return (current, true) }
        index = index > 0 ? index - 1 : items.count - 1
        return (current, false)
    }

    public mutating func jump(to i: Int) -> Track? {
        guard items.indices.contains(i) else { return nil }
        index = i
        return current
    }

    public mutating func playNext(_ track: Track) {
        if items.isEmpty { start([track]); return }
        items.insert(track, at: index + 1)
        if let o = original.firstIndex(where: { $0.id == current?.id }) {
            original.insert(track, at: o + 1)
        } else {
            original.append(track)
        }
    }

    public mutating func append(_ track: Track) {
        if items.isEmpty { start([track]); return }
        items.append(track)
        original.append(track)
    }

    /// ライブラリから曲が消えた／更新されたときにキューを追従させる。
    /// 再生中の曲が消えた場合は、その次の曲が現在位置になる。
    /// - Returns: 再生中の曲がキューから消えたら true
    @discardableResult
    public mutating func reconcile(with byId: [String: Track]) -> Bool {
        let wasPlaying = current
        let removedBefore = items.prefix(index).filter { byId[$0.id] == nil }.count
        original = original.compactMap { byId[$0.id] }
        items = items.compactMap { byId[$0.id] }
        index = max(0, min(index - removedBefore, items.count - 1))
        if items.isEmpty { index = 0 }
        guard let wasPlaying else { return false }
        return byId[wasPlaying.id] == nil
    }

    public mutating func clear() {
        original = []; items = []; index = 0; isShuffled = false
    }
}
