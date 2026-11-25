import XCTest
@testable import MusicSyncCore

final class SyncPlannerTests: XCTestCase {
    func t(_ id: String, sha: String = "s", title: String = "T", album: String = "A",
           track: Int = 1, art: String? = nil, size: Int64 = 100) -> Track {
        Track(id: id, size: size, sha256: sha, title: title, album: album, trackNumber: track, artworkId: art)
    }

    func testFreshSyncDownloadsEverythingInAlbumOrder() {
        let remote = [t("b", album: "Z", track: 1), t("a", album: "A", track: 2), t("c", album: "A", track: 1)]
        let plan = SyncPlanner.plan(remote: remote, local: [], presentFiles: [], presentArtwork: [])
        XCTAssertEqual(plan.downloads.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(plan.totalDownloadBytes, 300)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertFalse(plan.requiresDeletionConfirmation)
    }

    func testUnchangedIsNoop() {
        let tracks = [t("a"), t("b")]
        let plan = SyncPlanner.plan(remote: tracks, local: tracks, presentFiles: ["a", "b"], presentArtwork: [])
        XCTAssertTrue(plan.isEmpty)
    }

    func testChangedContentRedownloads() {
        let plan = SyncPlanner.plan(remote: [t("a", sha: "new")], local: [t("a", sha: "old")],
                                    presentFiles: ["a"], presentArtwork: [])
        XCTAssertEqual(plan.downloads.map(\.id), ["a"])
    }

    func testMissingFileRedownloads() {
        let plan = SyncPlanner.plan(remote: [t("a")], local: [t("a")], presentFiles: [], presentArtwork: [])
        XCTAssertEqual(plan.downloads.map(\.id), ["a"])
    }

    func testMetadataOnlyChange() {
        let plan = SyncPlanner.plan(remote: [t("a", title: "New", art: "x")], local: [t("a", title: "Old")],
                                    presentFiles: ["a"], presentArtwork: [])
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertEqual(plan.metadataUpdates.map(\.title), ["New"])
        XCTAssertEqual(plan.artworkDownloads, ["x"])
    }

    func testDeletionsAndArtworkCleanup() {
        let plan = SyncPlanner.plan(remote: [t("a", art: "keep")], local: [t("a", art: "keep"), t("b", art: "old")],
                                    presentFiles: ["a", "b"], presentArtwork: ["keep", "old"])
        XCTAssertEqual(plan.deletions, ["b"])
        XCTAssertEqual(plan.artworkDeletions, ["old"])
        XCTAssertTrue(plan.artworkDownloads.isEmpty)
        XCTAssertFalse(plan.requiresDeletionConfirmation)
    }

    func testEmptyServerRequiresConfirmation() {
        let plan = SyncPlanner.plan(remote: [], local: [t("a")], presentFiles: ["a"], presentArtwork: [])
        XCTAssertTrue(plan.requiresDeletionConfirmation)
    }

    func testMassDeletionRequiresConfirmation() {
        let local = (0..<20).map { t("id\($0)") }
        let plan = SyncPlanner.plan(remote: Array(local.prefix(5)), local: local,
                                    presentFiles: Set(local.map(\.id)), presentArtwork: [])
        XCTAssertEqual(plan.deletions.count, 15)
        XCTAssertTrue(plan.requiresDeletionConfirmation)
    }

    func testMovedFileIsRelocatedNotRedownloaded() {
        let local = (0..<20).map { t("old\($0)", sha: "h\($0)") }
        let remote = (0..<20).map { t("new\($0)", sha: "h\($0)") } + [t("fresh", sha: "zz")]
        let plan = SyncPlanner.plan(remote: remote, local: local,
                                    presentFiles: Set(local.map(\.id)), presentArtwork: [])
        XCTAssertEqual(plan.relocations.count, 20)
        XCTAssertEqual(plan.relocations.first { $0.fromId == "old3" }?.track.id, "new3")
        XCTAssertEqual(plan.downloads.map(\.id), ["fresh"])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertFalse(plan.requiresDeletionConfirmation)  // フォルダ名変更で確認ダイアログを出さない
    }

    func testRelocationNeedsLocalFile() {
        let plan = SyncPlanner.plan(remote: [t("new", sha: "h")], local: [t("old", sha: "h")],
                                    presentFiles: [], presentArtwork: [])
        XCTAssertTrue(plan.relocations.isEmpty)
        XCTAssertEqual(plan.downloads.map(\.id), ["new"])
        XCTAssertEqual(plan.deletions, ["old"])
    }

    func testDuplicateRemoteIdsIgnored() {
        let plan = SyncPlanner.plan(remote: [t("a"), t("a")], local: [], presentFiles: [], presentArtwork: [])
        XCTAssertEqual(plan.downloads.count, 1)
    }
}

final class PlaylistMergeTests: XCTestCase {
    func testLastWriterWinsAndServerWinsTies() {
        let server = [Playlist(id: "1", name: "srv", updatedAt: 10), Playlist(id: "2", name: "srv2", updatedAt: 10)]
        let local = [Playlist(id: "1", name: "mine", updatedAt: 11), Playlist(id: "2", name: "tie", updatedAt: 10),
                     Playlist(id: "3", name: "local only", updatedAt: 1)]
        let merged = Dictionary(uniqueKeysWithValues: PlaylistMerge.merge(local: local, server: server).map { ($0.id, $0) })
        XCTAssertEqual(merged["1"]?.name, "mine")
        XCTAssertEqual(merged["2"]?.name, "srv2")
        XCTAssertEqual(merged["3"]?.name, "local only")
    }

    func testTouchIsMonotonic() {
        var p = Playlist(name: "x", updatedAt: 5_000)
        p.touch(now: 1_000)  // 時計が戻っても
        XCTAssertEqual(p.updatedAt, 5_001)
        p.touch(now: 9_000)
        XCTAssertEqual(p.updatedAt, 9_000)
    }
}

final class ServerAddressTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try ServerAddress.parse("192.168.1.10").absoluteString, "http://192.168.1.10:8765")
        XCTAssertEqual(try ServerAddress.parse(" 192.168.1.10:9000 ").absoluteString, "http://192.168.1.10:9000")
        XCTAssertEqual(try ServerAddress.parse("http://mypc.local:8765/x?y").absoluteString, "http://mypc.local:8765")
        XCTAssertEqual(try ServerAddress.parse("１９２.１６８.１.２").absoluteString, "http://192.168.1.2:8765")
        XCTAssertThrowsError(try ServerAddress.parse(""))
        XCTAssertThrowsError(try ServerAddress.parse("ftp://x"))
        XCTAssertThrowsError(try ServerAddress.parse("http://:80"))
    }

    func testToken() {
        XCTAssertEqual(ServerAddress.normalizeToken(" ab12-cd34 ef "), "AB12CD34EF")
        XCTAssertEqual(ServerAddress.normalizeToken("ａｂｃ"), "ABC")
    }
}

final class LibraryIndexTests: XCTestCase {
    func testAlbumsGroupAndSort() {
        let tracks = [
            Track(id: "1", title: "B", artist: "X", album: "Alb", trackNumber: 2),
            Track(id: "2", title: "A", artist: "X", album: "Alb", trackNumber: 1, artworkId: "art"),
            Track(id: "3", title: "C", artist: "Y", album: "Other"),
            Track(id: "4", title: "D", artist: "ｘ", album: "ALB", trackNumber: 3),
        ]
        let albums = LibraryIndex.albums(tracks)
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].tracks.map(\.id), ["2", "1", "4"])
        XCTAssertEqual(albums[0].artworkId, "art")
        XCTAssertEqual(LibraryIndex.artists(tracks).map(\.trackCount), [3, 1])
    }

    func testSearch() {
        let t = Track(id: "1", title: "First Love", artist: "宇多田ヒカル", album: "First Love")
        XCTAssertTrue(LibraryText.matches(t, query: "first 宇多田"))
        XCTAssertTrue(LibraryText.matches(t, query: "ＦＩＲＳＴ"))
        XCTAssertFalse(LibraryText.matches(t, query: "automatic"))
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.duration(65), "1:05")
        XCTAssertEqual(Formatters.duration(3725), "1:02:05")
        XCTAssertEqual(Formatters.duration(.nan), "--:--")
        XCTAssertEqual(Formatters.bytes(512), "512 B")
        XCTAssertEqual(Formatters.bytes(1536), "1.5 KB")
    }

    func testFileNameIsSafe() {
        XCTAssertEqual(Track(id: "abc", title: "t", fileExtension: "m4a").fileName, "abc.m4a")
        XCTAssertEqual(Track(id: "abc", title: "t", fileExtension: "../x").fileName, "abc.x")
        XCTAssertEqual(Track(id: "abc", title: "t", fileExtension: "").fileName, "abc")
    }
}
