import AVFoundation
import Combine
import SwiftUI

@MainActor
final class VideoPlaybackController: ObservableObject {
    let primaryPlayer: AVQueuePlayer
    let secondaryPlayer: AVQueuePlayer

    @Published var primaryOpacity: Double = 1.0
    @Published var secondaryOpacity: Double = 0.0

    private var primaryLooper: AVPlayerLooper?
    private var secondaryLooper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var readinessObservation: NSKeyValueObservation?
    private var cleanupTask: Task<Void, Never>?
    private var currentLoopURL: URL?
    private var activeIsPrimary: Bool = true

    init() {
        primaryPlayer = AVQueuePlayer()
        secondaryPlayer = AVQueuePlayer()
        configure(player: primaryPlayer)
        configure(player: secondaryPlayer)
    }

    func playLoop(_ asset: VideoAsset) {
        debugLog("video playLoop \(asset.rawValue)")
        let url = asset.url
        if currentLoopURL == url, activePlayer.timeControlStatus != .paused {
            return
        }
        currentLoopURL = url
        clearObservers()

        let target = targetPlayerForNewPlayback()
        clearPlayer(target)
        let item = AVPlayerItem(url: url)
        setLooper(for: target, item: item)

        startWhenReady(player: target) { [weak self] in
            guard let self else { return }
            target.play()
            self.activatePlayer(target, animated: false)
        }
    }

    func playOnce(_ asset: VideoAsset, completion: (() -> Void)? = nil) {
        debugLog("video playOnce \(asset.rawValue)")
        currentLoopURL = nil
        clearObservers()

        let target = targetPlayerForNewPlayback()
        clearPlayer(target)

        let item = AVPlayerItem(url: asset.url)
        if let completion {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                completion()
            }
        }

        target.insert(item, after: nil)

        startWhenReady(player: target) { [weak self] in
            guard let self else { return }
            target.play()
            self.activatePlayer(target, animated: self.shouldAnimateTransition)
        }
    }

    func playOnceThenLoop(_ once: VideoAsset, loop: VideoAsset, onLoopStart: (() -> Void)? = nil) {
        debugLog("video playOnceThenLoop \(once.rawValue) -> \(loop.rawValue)")
        let onceURL = once.url
        let loopURL = loop.url
        if onceURL == loopURL {
            playLoop(loop)
            onLoopStart?()
            return
        }

        currentLoopURL = loopURL
        clearObservers()

        let target = targetPlayerForNewPlayback()
        clearPlayer(target)

        let onceItem = AVPlayerItem(url: onceURL)
        let loopItem = AVPlayerItem(url: loopURL)
        target.insert(onceItem, after: nil)
        target.insert(loopItem, after: onceItem)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: onceItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setLooper(for: target, item: loopItem)
                onLoopStart?()
            }
        }

        startWhenReady(player: target) { [weak self] in
            guard let self else { return }
            target.play()
            self.activatePlayer(target, animated: self.shouldAnimateTransition)
        }
    }

    func playSequence(_ assets: [VideoAsset], completion: (() -> Void)? = nil) {
        guard !assets.isEmpty else { return }
        debugLog("video playSequence \(assets.map { $0.rawValue }.joined(separator: ","))")
        currentLoopURL = nil
        clearObservers()

        let target = targetPlayerForNewPlayback()
        clearPlayer(target)

        let items = assets.map { AVPlayerItem(url: $0.url) }
        for item in items {
            target.insert(item, after: nil)
        }

        if let last = items.last, let completion {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: last,
                queue: .main
            ) { _ in
                completion()
            }
        }

        startWhenReady(player: target) { [weak self] in
            guard let self else { return }
            target.play()
            self.activatePlayer(target, animated: self.shouldAnimateTransition)
        }
    }

    func stop() {
        debugLog("video stop")
        primaryPlayer.pause()
        secondaryPlayer.pause()
    }

    private func configure(player: AVQueuePlayer) {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        player.volume = 0
    }

    private var activePlayer: AVQueuePlayer {
        activeIsPrimary ? primaryPlayer : secondaryPlayer
    }

    private var inactivePlayer: AVQueuePlayer {
        activeIsPrimary ? secondaryPlayer : primaryPlayer
    }

    private var shouldAnimateTransition: Bool {
        activePlayer.currentItem != nil
    }

    private func targetPlayerForNewPlayback() -> AVQueuePlayer {
        shouldAnimateTransition ? inactivePlayer : activePlayer
    }

    private func activatePlayer(_ player: AVQueuePlayer, animated: Bool) {
        let isPrimary = player === primaryPlayer
        let oldPlayer = activePlayer
        activeIsPrimary = isPrimary

        let update = {
            self.primaryOpacity = isPrimary ? 1.0 : 0.0
            self.secondaryOpacity = isPrimary ? 0.0 : 1.0
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.16)) {
                update()
            }
            if oldPlayer !== player {
                scheduleCleanup(for: oldPlayer)
            }
        } else {
            update()
            if oldPlayer !== player {
                clearPlayer(oldPlayer)
            }
        }
    }

    private func scheduleCleanup(for player: AVQueuePlayer) {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            await MainActor.run {
                self?.clearPlayer(player)
            }
        }
    }

    private func clearPlayer(_ player: AVQueuePlayer) {
        player.pause()
        player.removeAllItems()
        clearLooper(for: player)
    }

    private func setLooper(for player: AVQueuePlayer, item: AVPlayerItem) {
        clearLooper(for: player)
        if player === primaryPlayer {
            primaryLooper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            secondaryLooper = AVPlayerLooper(player: player, templateItem: item)
        }
    }

    private func clearLooper(for player: AVQueuePlayer) {
        if player === primaryPlayer {
            primaryLooper = nil
        } else {
            secondaryLooper = nil
        }
    }

    private func startWhenReady(player: AVQueuePlayer, onReady: @escaping () -> Void) {
        guard let item = player.currentItem else {
            onReady()
            return
        }

        if item.status == .readyToPlay {
            onReady()
            return
        }

        readinessObservation = item.observe(\.status, options: [.new, .initial]) { item, _ in
            if item.status == .readyToPlay || item.status == .failed {
                Task { @MainActor in
                    debugLog("video item status \(item.status.rawValue)")
                    onReady()
                }
            }
        }
    }

    private func clearObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        readinessObservation = nil
    }
}
