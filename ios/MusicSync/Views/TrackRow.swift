import MusicSyncCore
import SwiftUI

struct TrackRow: View {
    let track: Track
    var showArtwork = true
    var showTrackNumber = false

    @Environment(AudioPlayer.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            if showTrackNumber {
                Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "–")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            } else if showArtwork {
                ArtworkView(artworkId: track.artworkId, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(player.current?.id == track.id ? Color.accentColor : .primary)
                Text(showTrackNumber ? track.displayArtist : "\(track.displayArtist) — \(track.displayAlbum)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if player.current?.id == track.id {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("再生中")
            }
            Text(Formatters.duration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// 曲の長押しメニュー（次に再生 / キューに追加 / プレイリストに追加）
struct TrackContextMenu: ViewModifier {
    let track: Track
    @Binding var addToPlaylist: Track?
    @Environment(AudioPlayer.self) private var player

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { player.playNext(track) } label: { Label("次に再生", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("最後に再生", systemImage: "text.append") }
            Button { addToPlaylist = track } label: { Label("プレイリストに追加…", systemImage: "music.note.list") }
        }
    }
}

extension View {
    func trackMenu(_ track: Track, addToPlaylist: Binding<Track?>) -> some View {
        modifier(TrackContextMenu(track: track, addToPlaylist: addToPlaylist))
    }
}

/// 「再生」「シャッフル」の大きいボタン
struct PlayShuffleButtons: View {
    let tracks: [Track]
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(tracks) } label: {
                Label("再生", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { player.play(tracks, shuffle: true) } label: {
                Label("シャッフル", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(tracks.isEmpty)
    }
}
