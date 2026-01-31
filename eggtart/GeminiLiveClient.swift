import AVFoundation
import Combine
import Foundation

final class GeminiLiveClient: ObservableObject {
    struct Configuration {
        var apiKey: String
        var model: String
    }

    @Published private(set) var isConnected: Bool = false

    var onUserSpeechStart: (() -> Void)?
    var onUserSpeechEnd: (() -> Void)?
    var onResponseStart: (() -> Void)?
    var onResponseEnd: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private var socketTask: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)

    func connect(configuration: Configuration) {
        guard socketTask == nil else { return }

        // Replace this placeholder URL with the official Gemini Live API WebSocket endpoint.
        let placeholderURL = URL(string: "wss://example.com/gemini-live")!
        let request = URLRequest(url: placeholderURL)
        socketTask = urlSession.webSocketTask(with: request)
        socketTask?.resume()
        isConnected = true

        listenForMessages()
    }

    func disconnect() {
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        isConnected = false
    }

    func startMicrophone() {
        guard !audioEngine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else { return }
        do {
            let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try session.setActive(true)
        } catch {
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.sendAudioBuffer(buffer, format: format)
        }

        do {
            try audioEngine.start()
        } catch {
            return
        }
    }

    func stopMicrophone() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func sendText(_ text: String) {
        guard let socketTask else { return }
        let payload = URLSessionWebSocketTask.Message.string(text)
        socketTask.send(payload) { _ in }
    }

    func interrupt() {
        onResponseEnd?()
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard socketTask != nil else { return }
        // TODO: Convert the PCM buffer to the format required by Gemini Live API
        // and send it as a binary WebSocket message.
    }

    private func listenForMessages() {
        socketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.listenForMessages()
            case .failure:
                self.disconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        // TODO: Parse Gemini Live API event payloads and trigger the callbacks below.
        // onUserSpeechStart?(), onUserSpeechEnd?(), onResponseStart?(), onResponseEnd?()
        switch message {
        case .string:
            break
        case .data:
            break
        @unknown default:
            break
        }
    }
}
