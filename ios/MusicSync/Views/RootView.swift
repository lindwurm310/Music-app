import MusicSyncCore
import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case library, playlists, sync }

    @Environment(LibraryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .library
    @State private var showNowPlaying = false

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(goToSync: { tab = .sync })
                .miniPlayer(showNowPlaying: $showNowPlaying)
                .tabItem { Label("ライブラリ", systemImage: "music.note.list") }
                .tag(Tab.library)
            PlaylistsView()
                .miniPlayer(showNowPlaying: $showNowPlaying)
                .tabItem { Label("プレイリスト", systemImage: "music.note.house") }
                .tag(Tab.playlists)
            SyncView()
                .miniPlayer(showNowPlaying: $showNowPlaying)
                .tabItem { Label("同期", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.sync)
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.saveNow() }
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    @Environment(AudioPlayer.self) private var player
    @Binding var showNowPlaying: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayerView { showNowPlaying = true }
            }
        }
    }
}

extension View {
    func miniPlayer(showNowPlaying: Binding<Bool>) -> some View {
        modifier(MiniPlayerInset(showNowPlaying: showNowPlaying))
    }
}
