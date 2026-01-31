import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = EggtartViewModel()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VideoPlayerView(player: viewModel.video.player)
                .ignoresSafeArea()

            TapCaptureView { location, size in
                viewModel.handleTap(location: location, in: size)
            }

            VStack(spacing: 0) {
                EggtartTheme.topGradient
                    .frame(height: 180)
                Spacer()
                EggtartTheme.bottomGradient
                    .frame(height: 220)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                permissionBanner
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $viewModel.showLibrary) {
            LibraryView()
        }
        .onAppear {
            viewModel.onAppear()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                viewModel.showLibrary = true
            } label: {
                ZStack(alignment: .topLeading) {
                    Image(systemName: "book")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())

                    if viewModel.hasBookUpdates {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    viewModel.playEmotion(.friedegg)
                } label: {
                    Image(systemName: "face.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.playEmotion(.chicken)
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    viewModel.goToSleep()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if viewModel.isProcessingAudio || viewModel.isSpeaking || viewModel.state == .listeningLoop {
                Button {
                    viewModel.interrupt()
                } label: {
                    Text("interrupt")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 28) {
                Button {
                    viewModel.resetToDefault()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                RippleButton(isActive: viewModel.isProcessingAudio) {
                    viewModel.startListening()
                } content: {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.toggleMic()
                } label: {
                    Image(systemName: viewModel.micEnabled ? "mic.circle.fill" : "mic.slash.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(viewModel.micEnabled ? .white : .red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var permissionBanner: some View {
        Group {
            if let text = viewModel.micPermissionBannerText {
                HStack(spacing: 10) {
                    Text(text)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.9))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.micPermissionBannerText)
    }
}

struct TapCaptureView: View {
    var onTap: (CGPoint, CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            onTap(value.location, proxy.size)
                        }
                )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
