import XCTest
@testable import MusicSyncCore

/// Python サーバーが実際に出力した manifest を Swift 側で読めることを確認する
final class ContractTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    func testDecodeServerManifest() throws {
        let m = try JSONDecoder().decode(Manifest.self, from: fixture("manifest.json"))
        XCTAssertEqual(m.protocolVersion, 1)
        XCTAssertEqual(m.serverName, "test-pc")
        XCTAssertEqual(m.tracks.first?.title, "夜明け")
        XCTAssertNil(m.tracks.first?.artworkId)
        XCTAssertEqual(m.tracks.first?.fileName, "\(m.tracks[0].id).mp3")
        XCTAssertEqual(m.playlists.first?.name, "ドライブ")
        XCTAssertEqual(m.playlists.first?.trackIds, [m.tracks[0].id])
    }

    func testPlaylistRoundTripUsesServerKeys() throws {
        let p = Playlist(id: "x", name: "n", trackIds: ["a"], updatedAt: 5, deleted: true)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any]
        XCTAssertEqual(Set(obj?.keys.map { $0 } ?? []), ["id", "name", "trackIds", "updatedAt", "deleted"])
    }
}
