import XCTest
@testable import MusicSyncCore

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class PlayQueueTests: XCTestCase {
    let tracks = (1...5).map { Track(id: "\($0)", title: "T\($0)") }

    func testAdvanceStopsAtEndWithoutRepeat() {
        var q = PlayQueue()
        q.start(tracks, at: 3)
        XCTAssertEqual(q.advanceAfterFinish()?.id, "5")
        XCTAssertNil(q.advanceAfterFinish())
    }

    func testRepeatAllAndOne() {
        var q = PlayQueue()
        q.start(tracks, at: 4)
        q.repeatMode = .all
        XCTAssertEqual(q.advanceAfterFinish()?.id, "1")
        q.repeatMode = .one
        XCTAssertEqual(q.advanceAfterFinish()?.id, "1")
        XCTAssertEqual(q.skipNext()?.id, "2")  // 手動の「次へ」は 1 曲リピートでも進む
    }

    func testPrevious() {
        var q = PlayQueue()
        q.start(tracks, at: 2)
        XCTAssertEqual(q.skipPrevious(elapsed: 10).restart, true)
        let r = q.skipPrevious(elapsed: 1)
        XCTAssertEqual(r.track?.id, "2")
        XCTAssertFalse(r.restart)
        _ = q.jump(to: 0)
        XCTAssertTrue(q.skipPrevious(elapsed: 0).restart)
    }

    func testShuffleKeepsCurrentFirstAndRestores() {
        var q = PlayQueue()
        q.start(tracks, at: 2)
        var rng = SeededRNG(state: 42)
        q.setShuffle(true, using: &rng)
        XCTAssertEqual(q.current?.id, "3")
        XCTAssertEqual(q.index, 0)
        XCTAssertEqual(Set(q.items.map(\.id)), Set(tracks.map(\.id)))
        _ = q.skipNext()
        let playing = q.current!.id
        q.setShuffle(false, using: &rng)
        XCTAssertEqual(q.current?.id, playing)
        XCTAssertEqual(q.items.map(\.id), tracks.map(\.id))
    }

    func testPlayNextAndAppend() {
        var q = PlayQueue()
        q.start(Array(tracks.prefix(2)))
        q.playNext(tracks[4])
        q.append(tracks[3])
        XCTAssertEqual(q.items.map(\.id), ["1", "5", "2", "4"])
        var empty = PlayQueue()
        empty.append(tracks[0])
        XCTAssertEqual(empty.current?.id, "1")
    }

    func testReconcileRemovesDeletedTracks() {
        var q = PlayQueue()
        q.start(tracks, at: 2)  // 再生中 "3"
        var byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        byId["1"] = nil
        XCTAssertFalse(q.reconcile(with: byId))
        XCTAssertEqual(q.current?.id, "3")
        byId["3"] = nil
        XCTAssertTrue(q.reconcile(with: byId))
        XCTAssertEqual(q.current?.id, "4")  // 次の曲が現在位置に
        q.reconcile(with: [:])
        XCTAssertNil(q.current)
        XCTAssertTrue(q.isEmpty)
    }

    func testRemapKeepsPositionThenReconcileKeepsTrack() {
        var q = PlayQueue()
        q.start(tracks, at: 2)
        let moved = Track(id: "3b", title: "T3")
        q.remap(["3": moved])
        XCTAssertEqual(q.current?.id, "3b")
        var byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        byId["3"] = nil
        byId["3b"] = moved
        XCTAssertFalse(q.reconcile(with: byId))
        XCTAssertEqual(q.current?.id, "3b")
        XCTAssertEqual(q.items.count, 5)
    }

    func testReconcileWithDuplicates() {
        var q = PlayQueue()
        q.start([tracks[0], tracks[1], tracks[0]], at: 2)
        XCTAssertFalse(q.reconcile(with: ["1": tracks[0]]))
        XCTAssertEqual(q.items.map(\.id), ["1", "1"])
        XCTAssertEqual(q.index, 1)
    }
}
