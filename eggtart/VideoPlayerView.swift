import AVFoundation
import SwiftUI

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            return AVPlayerLayer()
        }
        return layer
    }
}

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

struct DualVideoPlayerView: View {
    @ObservedObject var controller: VideoPlaybackController

    var body: some View {
        ZStack {
            VideoPlayerView(player: controller.primaryPlayer)
                .opacity(controller.primaryOpacity)

            VideoPlayerView(player: controller.secondaryPlayer)
                .opacity(controller.secondaryOpacity)
        }
    }
}
