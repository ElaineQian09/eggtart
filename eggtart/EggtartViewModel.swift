import AVFoundation
import Combine
import SwiftUI

@MainActor
final class EggtartViewModel: ObservableObject {
    enum ConversationState {
        case sleeping
        case waking
        case idle
        case listeningIntro
        case listeningLoop
        case listeningOutro
        case speakingIntro
        case speakingLoop
        case speakingOutro
    }

    enum MicPermissionStatus: Equatable {
        case idle
        case requesting
        case granted
        case denied
        case timedOut
    }

    @Published var state: ConversationState = .sleeping
    @Published var micEnabled: Bool = false
    @Published var isProcessingAudio: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var hasBookUpdates: Bool = true
    @Published var showLibrary: Bool = false
    @Published var micPermissionStatus: MicPermissionStatus = .idle

    let video = VideoPlaybackController()
    let gemini = GeminiLiveClient()

    private var pendingResponse: Bool = false
    private var permissionTimeoutTask: Task<Void, Never>?

    init() {
        bindGeminiCallbacks()
        state = .waking
        video.playOnceThenLoop(.sleeptowake, loop: .default) { [weak self] in
            self?.state = .idle
        }
    }

    func onAppear() {
    }

    func requestMicPermission() {
        let currentPermission = AVAudioSession.sharedInstance().recordPermission
        switch currentPermission {
        case .granted:
            micPermissionStatus = .granted
            if micEnabled {
                gemini.startMicrophone()
            }
            return
        case .denied:
            micPermissionStatus = .denied
            micEnabled = false
            gemini.stopMicrophone()
            return
        case .undetermined:
            break
        @unknown default:
            micPermissionStatus = .denied
            micEnabled = false
            gemini.stopMicrophone()
            return
        }

        permissionTimeoutTask?.cancel()
        micPermissionStatus = .requesting
        permissionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if self.micPermissionStatus == .requesting {
                    self.micPermissionStatus = .timedOut
                    self.micEnabled = false
                    self.gemini.stopMicrophone()
                }
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    self.permissionTimeoutTask?.cancel()
                    if granted {
                        self.micPermissionStatus = .granted
                        if self.micEnabled {
                            self.gemini.startMicrophone()
                        }
                    } else {
                        self.micPermissionStatus = .denied
                        self.micEnabled = false
                        self.gemini.stopMicrophone()
                    }
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    self.permissionTimeoutTask?.cancel()
                    if granted {
                        self.micPermissionStatus = .granted
                        if self.micEnabled {
                            self.gemini.startMicrophone()
                        }
                    } else {
                        self.micPermissionStatus = .denied
                        self.micEnabled = false
                        self.gemini.stopMicrophone()
                    }
                }
            }
        }
    }

    var micPermissionBannerText: String? {
        switch micPermissionStatus {
        case .denied:
            return "Microphone permission denied"
        case .timedOut:
            return "Microphone permission timed out"
        default:
            return nil
        }
    }

    func connectGemini(apiKey: String) {
        let configuration = GeminiLiveClient.Configuration(apiKey: apiKey, model: "gemini-live-model")
        gemini.connect(configuration: configuration)
    }

    func handleTap(location: CGPoint, in size: CGSize) {
        let middleX = size.width / 3.0
        let topY = size.height / 3.0
        let midY = 2.0 * size.height / 3.0

        let inMiddleX = location.x >= middleX && location.x <= 2.0 * middleX
        guard inMiddleX else { return }

        if location.y <= topY {
            if state == .sleeping {
                wakeFromSleep()
            } else {
                playInteraction(.headtap)
            }
        } else if location.y <= midY {
            playInteraction(.midtap)
        } else {
            playInteraction(.bottomtap)
        }
    }

    func wakeFromSleep() {
        guard state == .sleeping else { return }
        state = .waking
        video.playOnceThenLoop(.sleeptowake, loop: .default) { [weak self] in
            self?.state = .idle
        }
    }

    func goToSleep() {
        state = .sleeping
        pendingResponse = false
        isProcessingAudio = false
        isSpeaking = false
        video.playOnceThenLoop(.waketosleep, loop: .sleep) { [weak self] in
            self?.state = .sleeping
        }
    }

    func resetToDefault() {
        pendingResponse = false
        isProcessingAudio = false
        isSpeaking = false
        state = .idle
        video.playLoop(.default)
    }

    func toggleMic() {
        if micEnabled {
            micEnabled = false
            micPermissionStatus = .idle
            permissionTimeoutTask?.cancel()
            gemini.stopMicrophone()
            stopListening()
        } else {
            let currentPermission = AVAudioSession.sharedInstance().recordPermission
            switch currentPermission {
            case .granted:
                micEnabled = true
                micPermissionStatus = .granted
                gemini.startMicrophone()
            case .undetermined:
                micEnabled = true
                requestMicPermission()
            case .denied:
                micEnabled = false
                micPermissionStatus = .denied
            @unknown default:
                micEnabled = false
                micPermissionStatus = .denied
            }
        }
    }

    func startListening() {
        guard state == .idle, micEnabled else { return }
        state = .listeningIntro
        isProcessingAudio = true
        video.playOnce(.listening1) { [weak self] in
            self?.state = .listeningLoop
            self?.video.playLoop(.listening2)
        }
    }

    func stopListening() {
        guard state == .listeningLoop || state == .listeningIntro else { return }
        state = .listeningOutro
        video.playOnce(.listening3) { [weak self] in
            guard let self else { return }
            if self.pendingResponse {
                self.startRespondingSequence()
            } else {
                self.isProcessingAudio = false
                self.state = .idle
                self.video.playLoop(.default)
            }
        }
    }

    func startRespondingSequence() {
        pendingResponse = false
        isProcessingAudio = true
        state = .speakingIntro
        video.playSequence([.listening3, .speaking1]) { [weak self] in
            self?.state = .speakingLoop
            self?.isSpeaking = true
            self?.video.playLoop(.speaking2)
        }
    }

    func finishSpeaking() {
        guard state == .speakingLoop || state == .speakingIntro else { return }
        state = .speakingOutro
        isSpeaking = false
        isProcessingAudio = false
        video.playOnceThenLoop(.speaking3, loop: .default) { [weak self] in
            self?.state = .idle
        }
    }

    func interrupt() {
        gemini.interrupt()
        pendingResponse = false
        isProcessingAudio = false
        isSpeaking = false
        state = .idle
        video.playLoop(.default)
    }

    func playEmotion(_ asset: VideoAsset) {
        guard state == .idle else { return }
        state = .idle
        video.playOnceThenLoop(asset, loop: .default)
    }

    private func playInteraction(_ asset: VideoAsset) {
        guard state == .idle else { return }
        state = .idle
        video.playOnceThenLoop(asset, loop: .default)
    }

    private func bindGeminiCallbacks() {
        gemini.onUserSpeechStart = { [weak self] in
            Task { @MainActor in
                self?.startListening()
            }
        }
        gemini.onUserSpeechEnd = { [weak self] in
            Task { @MainActor in
                self?.pendingResponse = false
                self?.stopListening()
            }
        }
        gemini.onResponseStart = { [weak self] in
            Task { @MainActor in
                self?.pendingResponse = true
                self?.isProcessingAudio = true
                if self?.state == .listeningOutro {
                    return
                }
                if self?.state == .listeningLoop || self?.state == .listeningIntro {
                    self?.stopListening()
                } else {
                    self?.startRespondingSequence()
                }
            }
        }
        gemini.onResponseEnd = { [weak self] in
            Task { @MainActor in
                self?.finishSpeaking()
            }
        }
    }
}
