import AVFoundation
import MediaPlayer
import MusicSyncCore
import Observation
import UIKit

/// 再生エンジン。ロック画面・コントロールセンター・イヤホン操作に対応。
@Observable
@MainActor
final class AudioPlayer {
    private(set) var queue = PlayQueue()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    var current: Track? { queue.current }
    var repeatMode: RepeatMode { queue.repeatMode }
    var isShuffled: Bool { queue.isShuffled }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var isSeeking = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = false  // ローカルファイルなので待たない
        configureSession()
        configureRemoteCommands()
        observeTime()
        observeSystemEvents()
    }

    // MARK: - 操作

    func play(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        queue.start(tracks, at: index, shuffle: shuffle)
        load(queue.current, autoplay: true)
    }

    func playNext(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.playNext(track)
        if wasEmpty { load(queue.current, autoplay: true) }
    }

    func addToQueue(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.append(track)
        if wasEmpty { load(queue.current, autoplay: true) }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard player.currentItem != nil else {
            if let t = queue.current { load(t, autoplay: true) }
            return
        }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        currentTime = player.currentTime().seconds.finiteOrZero
        updateNowPlaying()
    }

    func next() {
        load(queue.skipNext(), autoplay: isPlaying || player.currentItem == nil)
    }

    func previous() {
        let result = queue.skipPrevious(elapsed: currentTime)
        if result.restart {
            seek(to: 0)
        } else {
            load(result.track, autoplay: isPlaying)
        }
    }

    func jump(to index: Int) {
        load(queue.jump(to: index), autoplay: true)
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = target
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlaying()
            }
        }
    }

    func toggleShuffle() {
        queue.setShuffle(!queue.isShuffled)
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue.clear()
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 同期で曲が削除・更新されたときにキューを追従させる
    func libraryChanged(_ byId: [String: Track]) {
        guard !queue.isEmpty else { return }
        let removedCurrent = queue.reconcile(with: byId)
        if queue.isEmpty {
            stop()
        } else if removedCurrent {
            load(queue.current, autoplay: isPlaying)
        } else {
            updateNowPlaying()
        }
    }

    // MARK: - 内部

    private func load(_ track: Track?, autoplay: Bool, skipsLeft: Int? = nil) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        guard let track else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            currentTime = 0
            updateNowPlaying()
            return
        }
        let url = Paths.audioURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // ファイルが無い（同期途中など）→ 次の曲へ。全曲無ければ止める
            let remaining = (skipsLeft ?? queue.items.count) - 1
            if remaining > 0, let nextTrack = queue.skipNext() {
                load(nextTrack, autoplay: autoplay, skipsLeft: remaining)
            } else {
                load(nil, autoplay: false)
            }
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        duration = track.duration
        currentTime = 0
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemFinished() }
        }
        if autoplay {
            activateSession()
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        updateNowPlaying()
        Task { [weak self] in
            // タグの再生時間が不正確なことがあるので実際の長さで上書き
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite, d > 0 {
                self?.duration = d
                self?.updateNowPlaying()
            }
        }
    }

    private func itemFinished() {
        let next = queue.advanceAfterFinish()
        if let next, next.id == current?.id, queue.repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            load(next, autoplay: next != nil)
        }
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            print("AudioSession 設定失敗: \(error)")
        }
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking else { return }
                self.currentTime = time.seconds.finiteOrZero
            }
        }
    }

    private func observeSystemEvents() {
        let nc = NotificationCenter.default
        // 電話・アラームなどの割り込み
        notificationTokens.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                    self.updateNowPlaying()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
                    if options.contains(.shouldResume) { self.resume() }
                @unknown default:
                    break
                }
            }
        })
        // イヤホンが抜けたら一時停止
        notificationTokens.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let reasonRaw, AVAudioSession.RouteChangeReason(rawValue: reasonRaw) == .oldDeviceUnavailable else { return }
                self?.pause()
            }
        })
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = queue.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queue.index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.items.count,
        ]
        if let artId = track.artworkId, let image = ArtworkCache.shared.image(for: artId) {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension AudioPlayer {
    /// MPMediaItemArtwork のハンドラはバックグラウンドスレッドから呼ばれるので MainActor 外で作る
    nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
