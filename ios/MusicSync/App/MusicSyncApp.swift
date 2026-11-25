import MusicSyncCore
import SwiftUI

@main
@MainActor
struct MusicSyncApp: App {
    @State private var settings: ServerSettings
    @State private var store: LibraryStore
    @State private var player: AudioPlayer
    @State private var sync: SyncEngine

    init() {
        let settings = ServerSettings()
        let store = LibraryStore()
        let player = AudioPlayer()
        let sync = SyncEngine(store: store, settings: settings)
        store.onTracksChanged = { [weak player] byId in player?.libraryChanged(byId) }
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _player = State(initialValue: player)
        _sync = State(initialValue: sync)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(store)
                .environment(player)
                .environment(sync)
        }
    }
}
