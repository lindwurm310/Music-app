import MusicSyncCore
import SwiftUI

struct PlaylistsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showCreate = false
    @State private var newName = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Label("新規プレイリスト", systemImage: "plus")
                }
                ForEach(store.playlists) { playlist in
                    NavigationLink(value: playlist.id) {
                        PlaylistRow(playlist: playlist)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.playlists[$0].id }
                    ids.forEach(store.deletePlaylist)
                }
            }
            .listStyle(.plain)
            .navigationTitle("プレイリスト")
            .navigationDestination(for: String.self) { PlaylistDetailView(playlistId: $0) }
            .overlay {
                if store.playlists.isEmpty {
                    ContentUnavailableView("プレイリストがありません", systemImage: "music.note.list",
                                           description: Text("「新規プレイリスト」から作成できます。PC で作ったプレイリストも同期されます。"))
                        .allowsHitTesting(false)
                }
            }
            .alert("新規プレイリスト", isPresented: $showCreate) {
                TextField("名前", text: $newName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") {
                    if let p = store.createPlaylist(name: newName) { path.append(p.id) }
                }
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let tracks = store.tracks(of: playlist)
        HStack(spacing: 12) {
            PlaylistArtwork(tracks: tracks, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text("\(tracks.count) 曲").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// プレイリストのジャケット（先頭 4 枚のアルバムアートを並べる）
struct PlaylistArtwork: View {
    let tracks: [Track]
    let size: CGFloat

    var body: some View {
        var seen = Set<String>()
        let arts = tracks.compactMap(\.artworkId).filter { seen.insert($0).inserted }.prefix(4)
        return Group {
            if arts.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(artworkId: arts[arts.startIndex], size: half, cornerRadius: 0)
                        ArtworkView(artworkId: arts[arts.startIndex + 1], size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(artworkId: arts[arts.startIndex + 2], size: half, cornerRadius: 0)
                        ArtworkView(artworkId: arts[arts.startIndex + 3], size: half, cornerRadius: 0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ArtworkView(artworkId: arts.first, size: size)
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(LibraryStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showAddTracks = false
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""
    @State private var addToPlaylist: Track?

    var body: some View {
        if let playlist = store.playlist(playlistId) {
            content(playlist)
        } else {
            ContentUnavailableView("プレイリストは削除されました", systemImage: "trash")
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let tracks = store.tracks(of: playlist)
        let missing = playlist.trackIds.count - tracks.count
        return List {
            Section {
                VStack(spacing: 8) {
                    PlaylistArtwork(tracks: tracks, size: 200)
                    Text(playlist.name).font(.title3.bold()).multilineTextAlignment(.center)
                    let total = tracks.reduce(0) { $0 + $1.duration }
                    Text("\(tracks.count) 曲、\(Formatters.duration(total))")
                        .font(.caption).foregroundStyle(.secondary)
                    PlayShuffleButtons(tracks: tracks).padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    Button { player.play(tracks, startAt: index) } label: { TrackRow(track: track) }
                        .buttonStyle(.plain)
                        .trackMenu(track, addToPlaylist: $addToPlaylist)
                }
                .onDelete { store.removeTracks(atVisible: $0, from: playlist.id) }
                .onMove { store.moveTracks(atVisible: $0, to: $1, in: playlist.id) }
                Button { showAddTracks = true } label: { Label("曲を追加", systemImage: "plus.circle") }
            } footer: {
                if missing > 0 {
                    Text("この iPhone にまだ無い曲が \(missing) 曲あります（同期すると表示されます）")
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Menu {
                    Button { showAddTracks = true } label: { Label("曲を追加", systemImage: "plus") }
                    Button {
                        renameText = playlist.name
                        showRename = true
                    } label: { Label("名前を変更", systemImage: "pencil") }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("プレイリストを削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("その他")
                }
            }
        }
        .sheet(isPresented: $showAddTracks) {
            AddTracksSheet(playlistId: playlist.id)
        }
        .sheet(item: $addToPlaylist) { AddToPlaylistSheet(trackIds: [$0.id]) }
        .alert("名前を変更", isPresented: $showRename) {
            TextField("名前", text: $renameText)
            Button("キャンセル", role: .cancel) {}
            Button("保存") { store.renamePlaylist(playlist.id, to: renameText) }
        }
        .confirmationDialog("「\(playlist.name)」を削除しますか？", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                store.deletePlaylist(playlist.id)
                dismiss()
            }
        } message: {
            Text("曲そのものは削除されません。")
        }
    }
}

/// プレイリストに曲をまとめて追加する（検索 + 複数選択）
struct AddTracksSheet: View {
    let playlistId: String
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: [String] = []  // 選んだ順に追加する

    var body: some View {
        let inPlaylist = Set(store.playlist(playlistId)?.trackIds ?? [])
        let tracks = store.sortedTracks.filter { LibraryText.matches($0, query: query) }
        NavigationStack {
            List(tracks) { track in
                Button {
                    if let i = selected.firstIndex(of: track.id) { selected.remove(at: i) } else { selected.append(track.id) }
                } label: {
                    HStack {
                        TrackRow(track: track)
                        Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(track.id) ? Color.accentColor : .secondary)
                            .font(.title3)
                    }
                    .opacity(inPlaylist.contains(track.id) && !selected.contains(track.id) ? 0.5 : 1)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "曲を検索")
            .navigationTitle("曲を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "完了" : "\(selected.count) 曲を追加") {
                        store.addTracks(selected, to: playlistId)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

/// 曲（複数可）を既存または新規プレイリストに追加
struct AddToPlaylistSheet: View {
    let trackIds: [String]
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    showCreate = true
                } label: { Label("新規プレイリスト…", systemImage: "plus") }
                ForEach(store.playlists) { playlist in
                    Button {
                        store.addTracks(trackIds, to: playlist.id)
                        dismiss()
                    } label: {
                        PlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle(trackIds.count == 1 ? "プレイリストに追加" : "\(trackIds.count) 曲を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .alert("新規プレイリスト", isPresented: $showCreate) {
                TextField("名前", text: $newName)
                Button("キャンセル", role: .cancel) {}
                Button("作成して追加") {
                    if store.createPlaylist(name: newName, trackIds: trackIds) != nil { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
