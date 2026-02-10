import SwiftUI
import UIKit
import ReplayKit
import Combine

struct ContentView: View {
    @StateObject private var viewModel = EggtartViewModel()
    @StateObject private var recording = RecordingCoordinator()
    @StateObject private var broadcastPickerProxy = BroadcastPickerProxy()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            DualVideoPlayerView(controller: viewModel.video)
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
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)

            VStack(spacing: 8) {
                permissionBanner
                callEndedBanner
                recordingStatusBanner
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            HiddenBroadcastPickerView(
                proxy: broadcastPickerProxy,
                preferredExtension: recording.preferredBroadcastExtension
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)

            if recording.showBroadcastIntro {
                broadcastIntroOverlay
            }
        }
        .sheet(isPresented: $viewModel.showLibrary) {
            LibraryView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.onAppear()
            recording.discardAllPendingBroadcastUploads()
            recording.onRecordingStarted = {
                viewModel.video.playLoop(.default)
            }
            recording.onRecordingStopped = {
                viewModel.video.playLoop(.default)
            }
            recording.onBroadcastFilesReady = { item in
                Task {
                    await viewModel.uploadScreenRecording(
                        screenURL: item.screenURL,
                        micURL: item.audioURL,
                        durationSec: item.durationSec,
                        reason: item.reason
                    )
                }
            }
            recording.onProcessingFallback = {
                viewModel.triggerEggbookProcessingFallbackDemo()
            }
            recording.consumePendingBroadcastUploadsNow()
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.setAppActive(newPhase == .active)
            if newPhase == .active {
                recording.discardAllPendingBroadcastUploads()
                Task {
                    await viewModel.refreshEggbookSyncStatusOnAppEntry()
                }
            }
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
                    Text("👻")
                        .font(.system(size: 21))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.playEmotion(.chicken)
                } label: {
                    Text("🥚")
                        .font(.system(size: 21))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

            }
        }
    }

    private var bottomBar: some View {
        let controlSize: CGFloat = 52
        return VStack(spacing: 16) {
            HStack {
                Button {
                    recording.handleMainRecordButton {
                        broadcastPickerProxy.presentPicker()
                    }
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }

            HStack(spacing: 28) {
                Button {
                    viewModel.resetToDefault()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.94))
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.62))
                    }
                    .frame(width: controlSize, height: controlSize)
                }
                .buttonStyle(.plain)

                RippleButton(
                    isActive: viewModel.isProcessingAudio,
                    action: { viewModel.startListening() },
                    content: {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                            Image(systemName: "waveform")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.72))
                        }
                    },
                    size: controlSize
                )
                .buttonStyle(.plain)

                Button {
                    viewModel.toggleMic()
                } label: {
                    ZStack {
                        Circle()
                            .fill(viewModel.micEnabled ? Color.white : Color.red)
                        Image(systemName: viewModel.micEnabled ? "mic.fill" : "mic.slash.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(viewModel.micEnabled ? .black.opacity(0.72) : .white)
                    }
                    .frame(width: controlSize, height: controlSize)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var broadcastIntroOverlay: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("Screen Recording Mode")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Tap the record button to start screen recording. You can speak your ideas while recording, or stay silent and we will still analyze your capture.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))

                Text("Each recording is limited to 30 minutes and will stop automatically. Once finished, your recording will be processed into ideas and tasks in egg book.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))

                Text("After tapping Got it!, choose Eggtart in the system broadcast sheet, then leave the app to record on the Home Screen.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 10) {
                    Button("Not now") {
                        recording.cancelBroadcastIntro()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.85))

                    Button("Got it!") {
                        recording.confirmBroadcastIntro()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 22)
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
                        recording.openSettings()
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

    private var recordingStatusBanner: some View {
        Group {
            if let text = recording.permissionMessage {
                HStack(spacing: 10) {
                    Text(text)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)

                    if recording.showsSettingsButton {
                        Button {
                            recording.openSettings()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recording.permissionMessage)
    }

    private var callEndedBanner: some View {
        Group {
            if let text = viewModel.callEndedMessage {
                Text(text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.callEndedMessage)
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

@MainActor
final class BroadcastPickerProxy: ObservableObject {
    fileprivate weak var pickerView: RPSystemBroadcastPickerView?

    func presentPicker() -> Bool {
        guard let pickerView else { return false }
        guard let button = pickerView.subviews.compactMap({ $0 as? UIButton }).first else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }
}

struct HiddenBroadcastPickerView: UIViewRepresentable {
    @ObservedObject var proxy: BroadcastPickerProxy
    var preferredExtension: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .init(x: 0, y: 0, width: 1, height: 1))
        picker.showsMicrophoneButton = true
        picker.preferredExtension = preferredExtension
        proxy.pickerView = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = preferredExtension
        proxy.pickerView = uiView
    }
}

#Preview {
    ContentView()
}
