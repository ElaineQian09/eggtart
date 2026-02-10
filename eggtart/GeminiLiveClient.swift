import AVFoundation
import Combine
import Foundation
import QuartzCore

final class GeminiLiveClient: NSObject, ObservableObject {
    struct Configuration {
        var webSocketURL: URL
        var model: String
        var responseModalities: [String]
        var authToken: String?
        var inputAudioMimeType: String?
        var outputAudioMimeType: String?
        var realtimeChunkMimeType: String?
        var voiceName: String?
        var mediaResolution: String?
        var contextWindowTriggerTokens: Int?
        var contextWindowTargetTokens: Int?
        var allowAudioStreaming: Bool
    }

    @Published private(set) var isConnected: Bool = false

    var onUserSpeechStart: (() -> Void)?
    var onUserSpeechEnd: (() -> Void)?
    var onResponseStart: (() -> Void)?
    var onResponseEnd: (() -> Void)?
    var onAudioFileReady: ((URL, Int) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let playbackNode = AVAudioPlayerNode()
    private let targetSampleRate: Double = 16000
    private let targetChannelCount: AVAudioChannelCount = 1
    private var audioConverter: AVAudioConverter?
    private var converterSourceSampleRate: Double = 0
    private var converterSourceChannelCount: AVAudioChannelCount = 0
    private var isResponseActive: Bool = false
    private var lastResponseTextAt: CFTimeInterval = 0
    private var receivedMessageCount: Int = 0
    private var isReadyToSendAudio: Bool = false
    private var setupFallbackTask: Task<Void, Never>?
    private var loggedFirstMessage: Bool = false
    private var sentAudioChunkCount: Int = 0
    private var receivedAudioChunkCount: Int = 0
    private var audioChunkMimeType: String = "audio/pcm"
    private let setupOnlyDelayNanoseconds: UInt64 = 100_000_000
    private var allowAudioStreaming: Bool = true
    private var socketTask: URLSessionWebSocketTask?
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }()
    private var pendingConfiguration: Configuration?
    private var recordingFile: AVAudioFile?
    private var recordingRawURL: URL?
    private var recordingStartTime: Date?
    private var isUserSpeakingLocal: Bool = false
    private var lastSpeechTime: CFTimeInterval = 0
    private var speechAboveSince: CFTimeInterval?
    private var playbackOutputFormat: AVAudioFormat?
    private var playbackConverters: [String: AVAudioConverter] = [:]
    private var pendingAudioBuffers: Int = 0
    private var pendingTurnComplete: Bool = false
    private let localSpeechThreshold: Float = 0.02
    private let localSpeechSilenceDuration: CFTimeInterval = 1.0
    private let localSpeechMinDuration: CFTimeInterval = 0.25

    override init() {
        super.init()
        setupPlaybackEngine()
    }

    func connect(configuration: Configuration) {
        guard socketTask == nil else { return }
        debugLog("Gemini connect \(redactToken(in: configuration.webSocketURL.absoluteString))")

        isReadyToSendAudio = false
        setupFallbackTask?.cancel()
        loggedFirstMessage = false
        sentAudioChunkCount = 0
        if let chunkMime = configuration.realtimeChunkMimeType, !chunkMime.isEmpty {
            audioChunkMimeType = chunkMime
        } else if let inputMime = configuration.inputAudioMimeType, !inputMime.isEmpty {
            audioChunkMimeType = inputMime
        } else {
            audioChunkMimeType = "audio/pcm"
        }
        allowAudioStreaming = configuration.allowAudioStreaming
        pendingConfiguration = configuration
        var request = URLRequest(url: configuration.webSocketURL)
        if let token = configuration.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        socketTask = urlSession.webSocketTask(with: request)
        socketTask?.resume()
    }

    func disconnect() {
        debugLog("Gemini disconnect")
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        isConnected = false
        isResponseActive = false
        pendingConfiguration = nil
        isReadyToSendAudio = false
        setupFallbackTask?.cancel()
        setupFallbackTask = nil
        loggedFirstMessage = false
        sentAudioChunkCount = 0
        stopPlayback()
    }

    func startMicrophone() {
        debugLog("Gemini startMicrophone")
        resetVAD()
        guard !audioEngine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else { return }
        do {
            // Prefer high-quality playback routes and avoid forcing HFP call profile.
            let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            // Prefer built-in mic when available to avoid Bluetooth HFP crackle.
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
        } catch {
            return
        }

        let input = audioEngine.inputNode
        let hwInputFormat = input.inputFormat(forBus: 0)
        let outputFormat = input.outputFormat(forBus: 0)
        // Use hardware input format for tap creation. On some routes (e.g. HFP),
        // inputFormat and outputFormat may differ (24k vs 48k), causing -10868.
        let inputFormat = hwInputFormat
        debugLog("Gemini mic format hw=\(formatLabel(hwInputFormat)) out=\(formatLabel(outputFormat)) tap=\(formatLabel(inputFormat))")
        converterSourceSampleRate = 0
        converterSourceChannelCount = 0
        audioConverter = nil
        // Defensive cleanup: route/sample-rate changes can leave a stale tap format.
        input.removeTap(onBus: 0)
        setupAudioRecording(format: inputFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.sendAudioBuffer(buffer, inputFormat: buffer.format)
            self?.writeAudioBuffer(buffer)
            self?.detectLocalSpeech(buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            return
        }
    }

    func stopMicrophone() {
        debugLog("Gemini stopMicrophone")
        resetVAD()
        let durationSec = recordingStartTime.map { max(1, Int(Date().timeIntervalSince($0))) } ?? 0
        let rawURL = recordingRawURL
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recordingFile = nil
        recordingRawURL = nil
        recordingStartTime = nil

        if let rawURL {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.onAudioFileReady?(rawURL, max(1, durationSec))
            }
        }
    }

    func sendText(_ text: String) {
        guard let socketTask else { return }
        let payload = URLSessionWebSocketTask.Message.string(text)
        socketTask.send(payload) { _ in }
    }

    func interrupt() {
        onResponseEnd?()
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard allowAudioStreaming else { return }
        guard let socketTask, isConnected, isReadyToSendAudio else { return }
        guard let converter = ensureAudioConverter(inputFormat: inputFormat) else { return }
        guard let outputBuffer = convertPCM(buffer, converter: converter, inputFormat: inputFormat) else { return }
        guard let data = pcmData(from: outputBuffer), !data.isEmpty else { return }

        let payload: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": audioChunkMimeType,
                        "data": data.base64EncodedString()
                    ]
                ]
            ]
        ]
        sentAudioChunkCount += 1
        if sentAudioChunkCount <= 5 {
            debugLog("Gemini send audio chunk \(sentAudioChunkCount) bytes=\(data.count)")
        }
        sendJSON(payload, through: socketTask)
    }

    private func ensureAudioConverter(inputFormat: AVAudioFormat) -> AVAudioConverter? {
        if audioConverter == nil
            || converterSourceSampleRate != inputFormat.sampleRate
            || converterSourceChannelCount != inputFormat.channelCount {
            audioConverter = makeConverter(inputFormat: inputFormat)
            converterSourceSampleRate = inputFormat.sampleRate
            converterSourceChannelCount = inputFormat.channelCount
        }
        return audioConverter
    }

    private func detectLocalSpeech(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let data = channelData[channel]
            var i = 0
            while i < frameLength {
                let sample = data[i]
                sum += sample * sample
                i += 1
            }
        }

        let mean = sum / Float(frameLength * max(channelCount, 1))
        let rms = sqrt(mean)
        let now = CACurrentMediaTime()

        if rms > localSpeechThreshold {
            if speechAboveSince == nil {
                speechAboveSince = now
            }
            lastSpeechTime = now
            if !isUserSpeakingLocal, let started = speechAboveSince, now - started >= localSpeechMinDuration {
                isUserSpeakingLocal = true
                debugLog("VAD speech start (rms=\(rms))")
                onUserSpeechStart?()
            }
        } else {
            speechAboveSince = nil
            if isUserSpeakingLocal, now - lastSpeechTime > localSpeechSilenceDuration {
                isUserSpeakingLocal = false
                debugLog("VAD speech end (rms=\(rms))")
                onUserSpeechEnd?()
            }
        }
    }

    private func resetVAD() {
        isUserSpeakingLocal = false
        speechAboveSince = nil
        lastSpeechTime = 0
    }

    private func setupAudioRecording(format: AVAudioFormat) {
        let filename = "voice-\(UUID().uuidString).caf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            recordingFile = try AVAudioFile(forWriting: url, settings: format.settings)
            recordingRawURL = url
            recordingStartTime = Date()
        } catch {
            recordingFile = nil
            recordingRawURL = nil
            recordingStartTime = nil
            print("audio recording setup failed:", error.localizedDescription)
        }
    }

    private func writeAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let file = recordingFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            print("audio recording write failed:", error.localizedDescription)
        }
    }

    private func exportToM4A(rawURL: URL, durationSec: Int) {
        guard fileSizeBytes(rawURL) ?? 0 > 0 else {
            print("audio export skipped: empty file")
            try? FileManager.default.removeItem(at: rawURL)
            return
        }
        let asset = AVURLAsset(url: rawURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            Task { [weak self] in
                do {
                    try await exporter.export(to: outputURL, as: .m4a)
                    await MainActor.run {
                        self?.onAudioFileReady?(outputURL, max(1, durationSec))
                    }
                } catch {
                    let nsError = error as NSError
                    print("audio export failed:", nsError.localizedDescription, "code:", nsError.code, "domain:", nsError.domain)
                }
                try? FileManager.default.removeItem(at: rawURL)
            }
        } else {
            exporter.exportAsynchronously { [weak self] in
                guard let self else { return }
                if exporter.status == .completed {
                    self.onAudioFileReady?(outputURL, max(1, durationSec))
                } else if let error = exporter.error {
                    let nsError = error as NSError
                    print("audio export failed:", nsError.localizedDescription, "code:", nsError.code, "domain:", nsError.domain)
                }
                try? FileManager.default.removeItem(at: rawURL)
            }
        }
    }

    private func fileSizeBytes(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }

    private func listenForMessages() {
        socketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.listenForMessages()
            case .failure(let error):
                let nsError = error as NSError
                debugLog("Gemini receive error: \(nsError.localizedDescription) code=\(nsError.code) domain=\(nsError.domain)")
                self.isConnected = false
                self.isResponseActive = false
                self.socketTask = nil
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handlePayload(text: text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handlePayload(text: text)
            }
        @unknown default:
            break
        }
    }

    private func handlePayload(text: String) {
        receivedMessageCount += 1
        if !loggedFirstMessage {
            loggedFirstMessage = true
            let preview = text.prefix(1200)
            debugLog("Gemini first message: \(preview)")
        }
        if receivedMessageCount <= 5 {
            let preview = text.prefix(800)
            debugLog("Gemini recv \(receivedMessageCount): \(preview)")
        }
        if !isReadyToSendAudio {
            isReadyToSendAudio = true
        }
        guard let data = text.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let audioChunks = extractInlineAudioChunks(from: json)
        if !audioChunks.isEmpty {
            if !isResponseActive {
                isResponseActive = true
                onResponseStart?()
            }
            lastResponseTextAt = CACurrentMediaTime()
            for chunk in audioChunks {
                playInlineAudioChunk(data: chunk.data, mimeType: chunk.mimeType)
            }
        }
        if let responseText = extractResponseText(from: json), !responseText.isEmpty {
            if !isResponseActive {
                isResponseActive = true
                onResponseStart?()
            }
            lastResponseTextAt = CACurrentMediaTime()
        }
        if isTurnComplete(json) {
            pendingTurnComplete = true
            endResponseIfNeededIfReady()
        } else if isResponseActive {
            debounceResponseEnd()
        }
    }

    private func debounceResponseEnd() {
        guard pendingAudioBuffers == 0 else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastResponseTextAt
        if elapsed > 1.0 {
            endResponseIfNeeded()
        }
    }

    private func endResponseIfNeededIfReady() {
        guard pendingTurnComplete else { return }
        guard pendingAudioBuffers == 0 else { return }
        pendingTurnComplete = false
        endResponseIfNeeded()
    }

    private func endResponseIfNeeded() {
        guard isResponseActive else { return }
        isResponseActive = false
        onResponseEnd?()
    }

    private func isTurnComplete(_ json: [String: Any]) -> Bool {
        if let serverContent = json["serverContent"] as? [String: Any] {
            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                return true
            }
        }
        if let eventType = json["eventType"] as? String {
            let normalized = eventType.lowercased()
            if normalized.contains("turn_complete") || normalized.contains("turncomplete") {
                return true
            }
        }
        if let done = json["done"] as? Bool, done {
            return true
        }
        return false
    }

    private func extractResponseText(from json: [String: Any]) -> String? {
        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty {
                return texts.joined()
            }
        }
        if let text = json["text"] as? String {
            return text
        }
        if let candidates = json["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                if let content = candidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    let texts = parts.compactMap { $0["text"] as? String }
                    if !texts.isEmpty {
                        return texts.joined()
                    }
                }
            }
        }
        return nil
    }

    private func extractInlineAudioChunks(from json: [String: Any]) -> [(mimeType: String, data: Data)] {
        guard let serverContent = json["serverContent"] as? [String: Any],
              let modelTurn = serverContent["modelTurn"] as? [String: Any],
              let parts = modelTurn["parts"] as? [[String: Any]] else {
            return []
        }
        var chunks: [(mimeType: String, data: Data)] = []
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any],
                  let base64 = inline["data"] as? String,
                  let data = Data(base64Encoded: base64),
                  !data.isEmpty else {
                continue
            }
            let mimeType = (inline["mimeType"] as? String) ?? "audio/pcm;rate=24000"
            chunks.append((mimeType: mimeType, data: data))
        }
        return chunks
    }

    private func makeConverter(inputFormat: AVAudioFormat) -> AVAudioConverter? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: true
        ) else {
            return nil
        }
        return AVAudioConverter(from: inputFormat, to: targetFormat)
    }

    private func convertPCM(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let outputFormat = converter.outputFormat
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if let error {
                print("audio convert failed:", error.localizedDescription)
            }
            return nil
        }
        return outputBuffer
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return nil }
        return Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
    }

    private func sendSetup(configuration: Configuration) {
        guard let socketTask else { return }
        var generationConfig: [String: Any] = [
            "responseModalities": configuration.responseModalities
        ]
        if let voiceName = configuration.voiceName, !voiceName.isEmpty {
            generationConfig["speechConfig"] = [
                "voiceConfig": [
                    "prebuiltVoiceConfig": [
                        "voiceName": voiceName
                    ]
                ]
            ]
        }
        if let mediaResolution = configuration.mediaResolution, !mediaResolution.isEmpty {
            generationConfig["mediaResolution"] = mediaResolution
        }
        if let triggerTokens = configuration.contextWindowTriggerTokens,
           let targetTokens = configuration.contextWindowTargetTokens {
            generationConfig["contextWindowCompression"] = [
                "triggerTokens": triggerTokens,
                "slidingWindow": [
                    "targetTokens": targetTokens
                ]
            ]
        }
        var setup: [String: Any] = [
            "model": configuration.model,
            "generationConfig": generationConfig
        ]
        if let mimeType = configuration.inputAudioMimeType, !mimeType.isEmpty {
            setup["inputAudioConfig"] = ["mimeType": mimeType]
        }
        if let outputMime = configuration.outputAudioMimeType, !outputMime.isEmpty {
            setup["outputAudioConfig"] = ["mimeType": outputMime]
        }
        let payload: [String: Any] = ["setup": setup]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            debugLog("Gemini setup: \(text)")
        }
        sendJSON(payload, through: socketTask)
    }

    private func redactToken(in url: String) -> String {
        guard let range = url.range(of: "token=") else { return url }
        let prefix = url[..<range.upperBound]
        return "\(prefix)REDACTED"
    }

    private func sendJSON(_ payload: [String: Any], through socketTask: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        socketTask.send(.string(text)) { _ in }
    }

    private func setupPlaybackEngine() {
        if playbackNode.engine == nil {
            playbackEngine.attach(playbackNode)
        }
        playbackEngine.disconnectNodeOutput(playbackNode)
        playbackEngine.connect(playbackNode, to: playbackEngine.mainMixerNode, format: nil)
        playbackOutputFormat = playbackEngine.mainMixerNode.outputFormat(forBus: 0)
        playbackConverters.removeAll()
    }

    private func ensurePlaybackEngineRunning() {
        if playbackOutputFormat == nil {
            setupPlaybackEngine()
        }
        if !playbackEngine.isRunning {
            do {
                try playbackEngine.start()
            } catch {
                let nsError = error as NSError
                debugLog("Gemini playback start failed: \(nsError.localizedDescription) code=\(nsError.code)")
                return
            }
        }
        if !playbackNode.isPlaying {
            playbackNode.play()
        }
    }

    private func playInlineAudioChunk(data: Data, mimeType: String) {
        let sampleRate = sampleRateFromMimeType(mimeType) ?? 24000
        ensurePlaybackEngineRunning()
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { return }
        guard let outputFormat = playbackOutputFormat else { return }
        let frameCount = data.count / 2
        guard frameCount > 0 else { return }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        let audioBuffer = sourceBuffer.mutableAudioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        data.copyBytes(to: mData.assumingMemoryBound(to: UInt8.self), count: data.count)
        sourceBuffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(data.count)

        let bufferToPlay: AVAudioPCMBuffer
        if sourceFormat == outputFormat {
            bufferToPlay = sourceBuffer
        } else {
            guard let converted = convertPlaybackBuffer(sourceBuffer, from: sourceFormat, to: outputFormat) else {
                return
            }
            bufferToPlay = converted
        }

        pendingAudioBuffers += 1
        receivedAudioChunkCount += 1
        if receivedAudioChunkCount <= 5 {
            debugLog("Gemini play audio chunk \(receivedAudioChunkCount) bytes=\(data.count) mime=\(mimeType)")
        }
        playbackNode.scheduleBuffer(bufferToPlay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.pendingAudioBuffers = max(0, self.pendingAudioBuffers - 1)
                self.endResponseIfNeededIfReady()
            }
        }
    }

    private func sampleRateFromMimeType(_ mimeType: String) -> Double? {
        let lower = mimeType.lowercased()
        guard let range = lower.range(of: "rate=") else { return nil }
        let suffix = lower[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    private func convertPlaybackBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let key = "\(Int(sourceFormat.sampleRate))-\(sourceFormat.channelCount)-\(sourceFormat.commonFormat.rawValue)->\(Int(outputFormat.sampleRate))-\(outputFormat.channelCount)-\(outputFormat.commonFormat.rawValue)"
        let converter: AVAudioConverter
        if let cached = playbackConverters[key] {
            converter = cached
        } else {
            guard let created = AVAudioConverter(from: sourceFormat, to: outputFormat) else { return nil }
            playbackConverters[key] = created
            converter = created
        }

        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 8
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            if let error {
                debugLog("Gemini playback convert failed: \(error.localizedDescription) code=\(error.code)")
            }
            return nil
        }
        if outBuffer.frameLength == 0 {
            return nil
        }
        return outBuffer
    }

    private func stopPlayback() {
        playbackNode.stop()
        if playbackEngine.isRunning {
            playbackEngine.stop()
        }
        playbackConverters.removeAll()
        pendingAudioBuffers = 0
        pendingTurnComplete = false
    }

    private func formatLabel(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat.rawValue)"
    }
}

extension GeminiLiveClient: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        debugLog("Gemini WS didOpen")
        isConnected = true
        receivedMessageCount = 0
        loggedFirstMessage = false
        sentAudioChunkCount = 0
        receivedAudioChunkCount = 0
        pendingTurnComplete = false
        pendingAudioBuffers = 0
        if let configuration = pendingConfiguration {
            sendSetup(configuration: configuration)
        }
        isReadyToSendAudio = false
        setupFallbackTask?.cancel()
        setupFallbackTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.setupOnlyDelayNanoseconds)
            await MainActor.run {
                if self.allowAudioStreaming && self.isConnected && !self.isReadyToSendAudio {
                    debugLog("Gemini audio streaming enabled after setup-only window")
                    self.isReadyToSendAudio = true
                }
            }
        }
        listenForMessages()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        debugLog("Gemini WS didClose code=\(closeCode.rawValue) reason=\(reasonText) sentChunks=\(sentAudioChunkCount)")
        isConnected = false
        isResponseActive = false
        socketTask = nil
        isReadyToSendAudio = false
        loggedFirstMessage = false
        stopPlayback()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            debugLog("Gemini WS error: \(nsError.localizedDescription) code=\(nsError.code) domain=\(nsError.domain)")
        }
        isConnected = false
        isResponseActive = false
        socketTask = nil
        isReadyToSendAudio = false
        loggedFirstMessage = false
        stopPlayback()
    }
}
