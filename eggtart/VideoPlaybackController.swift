import AVFoundation
import Combine
import SwiftUI

@MainActor
final class VideoPlaybackController: ObservableObject {
    let player: AVQueuePlayer

    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?

    init() {
        self.player = AVQueuePlayer()
        self.player.actionAtItemEnd = .none
        self.player.automaticallyWaitsToMinimizeStalling = true
    }

    func playLoop(_ asset: VideoAsset) {
        clearObservers()
        looper = nil
        player.removeAllItems()

        let item = AVPlayerItem(url: asset.url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    func playOnce(_ asset: VideoAsset, completion: (() -> Void)? = nil) {
        clearObservers()
        looper = nil
        player.removeAllItems()

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
        player.insert(item, after: nil)
        player.play()
    }

    func playOnceThenLoop(_ once: VideoAsset, loop: VideoAsset, onLoopStart: (() -> Void)? = nil) {
        clearObservers()
        looper = nil
        player.removeAllItems()

        let onceItem = AVPlayerItem(url: once.url)
        let loopItem = AVPlayerItem(url: loop.url)
        player.insert(onceItem, after: nil)
        player.insert(loopItem, after: onceItem)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: onceItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.looper = AVPlayerLooper(player: self.player, templateItem: loopItem)
                onLoopStart?()
            }
        }

        player.play()
    }

    func playSequence(_ assets: [VideoAsset], completion: (() -> Void)? = nil) {
        clearObservers()
        looper = nil
        player.removeAllItems()

        let items = assets.map { AVPlayerItem(url: $0.url) }
        for item in items {
            player.insert(item, after: nil)
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
        player.play()
    }

    func stop() {
        player.pause()
    }

    private func clearObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
