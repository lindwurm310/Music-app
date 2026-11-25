import MusicSyncCore
import SwiftUI

struct LibraryView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case songs = "曲", albums = "アルバム", artists = "アーティスト"
        var id: String { rawValue }
    }

    var goToSync: () -> Void

    @Environment(LibraryStore.self) private var store
    @AppStorage("library.section") private var section: Mode = .albums
    @State private var query = ""
    @State private var addToPlaylist: Track?

    var body: some View {
        NavigationStack {
            Group {
                if store.isEmpty {
                    ContentUnavailableView {
                        Label("音楽がありません", systemImage: "music.note")
                    } description: {
                        Text("PC で MusicSync サーバーを起動して、同期してください。")
                    } actions: {
                        Button("同期の設定へ", action: goToSync).buttonStyle(.borderedProminent)
                    }
                } else if !query.isEmpty {
                    searchResults
                } else {
                    switch section {
                    case .songs: SongsList(tracks: store.sortedTracks, addToPlaylist: $addToPlaylist)
                    case .albums: AlbumsGrid(albums: store.albums)
                    case .artists: ArtistsList(artists: store.artists)
                    }
                }
            }
            .navigationTitle("ライブラリ")
            .toolbar {
                if !store.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Picker("表示", selection: $section) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                }
            }
            .searchable(text: $query, prompt: "曲・アーティスト・アルバム")
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .sheet(item: $addToPlaylist) { AddToPlaylistSheet(trackIds: [$0.id]) }
        }
    }

    private var searchResults: some View {
        let hits = store.sortedTracks.filter { LibraryText.matches($0, query: query) }
        return Group {
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                SongsList(tracks: hits, addToPlaylist: $addToPlaylist)
            }
        }
    }
}

struct SongsList: View {
    let tracks: [Track]
    @Binding var addToPlaylist: Track?
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        List {
            Section {
                PlayShuffleButtons(tracks: tracks)
                    .listRowSeparator(.hidden)
            }
            Section("\(tracks.count) 曲") {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button { player.play(tracks, startAt: index) } label: { TrackRow(track: track) }
                        .buttonStyle(.plain)
                        .trackMenu(track, addToPlaylist: $addToPlaylist)
                }
            }
        }
        .listStyle(.plain)
    }
}

struct AlbumsGrid: View {
    let albums: [Album]
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            FlexibleArtworkView(artworkId: album.artworkId)
                            Text(album.title).font(.subheadline).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding()
        }
    }
}

struct AlbumDetailView: View {
    let album: Album
    @Environment(LibraryStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @State private var addToPlaylist: Track?
    @State private var addAlbum = false

    /// 同期でアルバムが更新されても最新を表示する
    private var current: Album { store.albums.first { $0.id == album.id } ?? album }

    var body: some View {
        let album = current
        List {
            Section {
                VStack(spacing: 8) {
                    ArtworkView(artworkId: album.artworkId, size: 240, cornerRadius: 10)
                        .shadow(radius: 8, y: 4)
                    Text(album.title).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(album.artist).foregroundStyle(Color.accentColor)
                    if album.year > 0 {
                        Text(verbatim: "\(album.year)").font(.caption).foregroundStyle(.secondary)
                    }
                    PlayShuffleButtons(tracks: album.tracks).padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                    Button { player.play(album.tracks, startAt: index) } label: {
                        TrackRow(track: track, showTrackNumber: true)
                    }
                    .buttonStyle(.plain)
                    .trackMenu(track, addToPlaylist: $addToPlaylist)
                }
            } footer: {
                let total = album.tracks.reduce(0) { $0 + $1.duration }
                Text("\(album.tracks.count) 曲、\(Formatters.duration(total))")
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { addAlbum = true } label: { Label("プレイリストに追加", systemImage: "text.badge.plus") }
        }
        .sheet(item: $addToPlaylist) { AddToPlaylistSheet(trackIds: [$0.id]) }
        .sheet(isPresented: $addAlbum) { AddToPlaylistSheet(trackIds: album.tracks.map(\.id)) }
    }
}

struct ArtistsList: View {
    let artists: [Artist]

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtworkView(artworkId: artist.albums.first?.artworkId, size: 44, cornerRadius: 22)
                    VStack(alignment: .leading) {
                        Text(artist.name).lineLimit(1)
                        Text("\(artist.albums.count) アルバム・\(artist.trackCount) 曲")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct ArtistDetailView: View {
    let artist: Artist
    @Environment(LibraryStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var current: Artist { store.artists.first { $0.id == artist.id } ?? artist }

    var body: some View {
        let artist = current
        ScrollView {
            PlayShuffleButtons(tracks: artist.albums.flatMap(\.tracks)).padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(artist.albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            FlexibleArtworkView(artworkId: album.artworkId)
                            Text(album.title).font(.subheadline).lineLimit(1)
                            if album.year > 0 {
                                Text(verbatim: "\(album.year)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(artist.name)
    }
}
