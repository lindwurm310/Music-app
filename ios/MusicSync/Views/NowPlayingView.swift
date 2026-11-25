import MusicSyncCore
import SwiftUI

struct MiniPlayerView: View {
    var open: () -> Void
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkView(artworkId: track.artworkId, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline).lineLimit(1)
                    Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("次の曲")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: 2)
                }
                .frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAction(named: "再生画面を開く", open)
        }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, player.currentTime / player.duration)))
    }
}

struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showQueue = false
    @State private var addToPlaylist: Track?

    var body: some View {
        VStack(spacing: 20) {
            if let track = player.current {
                Spacer(minLength: 8)
                if showQueue {
                    QueueList()
                } else {
                    FlexibleArtworkView(artworkId: track.artworkId, cornerRadius: 12)
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                        .scaleEffect(player.isPlaying ? 1 : 0.88)
                        .animation(.spring(duration: 0.35), value: player.isPlaying)
                        .padding(.horizontal, 12)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.title3.bold()).lineLimit(1)
                        Text(track.displayArtist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button { addToPlaylist = track } label: { Label("プレイリストに追加…", systemImage: "music.note.list") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2)
                    }
                    .accessibilityLabel("その他")
                }
                progressSection
                controls
                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
                    }
                    .accessibilityLabel(player.isShuffled ? "シャッフル: オン" : "シャッフル: オフ")
                    Spacer()
                    Button { withAnimation { showQueue.toggle() } } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(showQueue ? Color.accentColor : .secondary)
                    }
                    .accessibilityLabel("次に再生")
                    Spacer()
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
                    }
                    .accessibilityLabel(repeatLabel)
                }
                .font(.title3)
                .padding(.horizontal, 24)
                Spacer(minLength: 8)
            } else {
                ContentUnavailableView("再生していません", systemImage: "music.note")
                    .onAppear { dismiss() }
            }
        }
        .padding(.horizontal, 24)
        .sheet(item: $addToPlaylist) { AddToPlaylistSheet(trackIds: [$0.id]) }
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "リピート: オフ"
        case .all: return "リピート: すべて"
        case .one: return "リピート: 1 曲"
        }
    }

    private var progressSection: some View {
        let duration = max(player.duration, 0.1)
        let value = scrubbing ?? min(player.currentTime, duration)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { value }, set: { scrubbing = $0 }), in: 0...duration, onEditingChanged: { editing in
                if !editing, let s = scrubbing {
                    player.seek(to: s)
                    scrubbing = nil
                }
            })
            .accessibilityLabel("再生位置")
            .accessibilityValue(Formatters.duration(value))
            HStack {
                Text(Formatters.duration(value))
                Spacer()
                Text("-" + Formatters.duration(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("前の曲")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 64, height: 64)
            }
            .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("次の曲")
        }
        .font(.title)
        .buttonStyle(.plain)
    }
}

struct QueueList: View {
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        let items = player.queue.items
        let current = player.queue.index
        ScrollViewReader { proxy in
            List {
                ForEach(Array(items.enumerated()), id: \.offset) { index, track in
                    Button { player.jump(to: index) } label: { TrackRow(track: track) }
                        .buttonStyle(.plain)
                        .opacity(index < current ? 0.45 : 1)
                        .id(index)
                }
            }
            .listStyle(.plain)
            .onAppear { proxy.scrollTo(current, anchor: .top) }
        }
        .frame(maxHeight: .infinity)
    }
}
