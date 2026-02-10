import ReplayKit
import Foundation
import AVFoundation
import UserNotifications

final class SampleHandler: RPBroadcastSampleHandler {
    private let appGroupId = "group.eggtart.screenrecord"
    private let statusKey = "broadcast.status"
    private let startedAtKey = "broadcast.startedAt"
    private let stoppedAtKey = "broadcast.stoppedAt"
    private let pendingUploadsKey = "broadcast.pendingUploads"
    private let sharedAuthTokenKey = "shared.authToken"
    private let sharedDeviceIdKey = "shared.deviceId"
    private let lastEventIdKey = "broadcast.lastEventId"
    private let lastUploadPhaseKey = "broadcast.lastUploadPhase"
    private let lastUploadErrorKey = "broadcast.lastUploadError"
    private let lastUploadUpdatedAtKey = "broadcast.lastUploadUpdatedAt"
    private let backendBaseURL = "https://eggtart-backend-production-2361.up.railway.app"
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    private var screenWriter: AVAssetWriter?
    private var screenVideoInput: AVAssetWriterInput?
    private var screenStartTime: CMTime?
    private var screenURL: URL?

    private var micWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var micStartTime: CMTime?
    private var micURL: URL?

    private var startedAt: Date?
    private var autoStopTimer: DispatchSourceTimer?
    private let maxDurationSeconds: TimeInterval = 30 * 60
    private var stopReason: String = "manual_or_system_stop"
    private var didLogWriterFailure = false
    private var finalizeHandled = false

    private struct SharedCredentials {
        let token: String
        let deviceId: String
    }

    private struct PreparedUploadContext {
        let queuedUploadId: String
        let reason: String
        let duration: Int
        let screenFileURL: URL
        let audioFileURL: URL?
        let credentials: SharedCredentials?
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        updateStatus("recording")
        stopReason = "manual_or_system_stop"
        startedAt = Date()
        UserDefaults(suiteName: appGroupId)?.set(startedAt?.timeIntervalSince1970, forKey: startedAtKey)
        UserDefaults(suiteName: appGroupId)?.set("none", forKey: stoppedAtKey)
        prepareWriters()
        scheduleAutoStop()
        UserDefaults(suiteName: appGroupId)?.synchronize()
    }

    override func broadcastPaused() {
        updateStatus("paused")
    }

    override func broadcastResumed() {
        updateStatus("recording")
    }

    override func broadcastFinished() {
        autoStopTimer?.cancel()
        autoStopTimer = nil
        updateStatus("finished")
        writeUploadTrace(phase: "broadcast_finished", eventId: nil, error: nil)
        UserDefaults(suiteName: appGroupId)?.set(Date().timeIntervalSince1970, forKey: stoppedAtKey)
        finalizeWriters(reason: stopReason)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch sampleBufferType {
        case .video:
            appendVideo(sampleBuffer)
        case .audioApp:
            // Keeping app audio out of upload for now.
            break
        case .audioMic:
            appendMic(sampleBuffer)
        @unknown default:
            break
        }
    }

    private func updateStatus(_ status: String) {
        UserDefaults(suiteName: appGroupId)?.set(status, forKey: statusKey)
        UserDefaults(suiteName: appGroupId)?.synchronize()
        writeUploadTrace(phase: status, eventId: nil, error: nil)
    }

    private func writeUploadTrace(phase: String, eventId: String?, error: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(phase, forKey: lastUploadPhaseKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastUploadUpdatedAtKey)
        if let eventId, !eventId.isEmpty {
            defaults.set(eventId, forKey: lastEventIdKey)
        }
        if let error, !error.isEmpty {
            defaults.set(error, forKey: lastUploadErrorKey)
        } else {
            defaults.removeObject(forKey: lastUploadErrorKey)
        }
        defaults.synchronize()
    }

    private func prepareWriters() {
        let id = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
        screenURL = tempDir.appendingPathComponent("screen-\(id).mp4")
        micURL = tempDir.appendingPathComponent("mic-\(id).m4a")
        print("BroadcastUpload writer targets screen:", screenURL?.path ?? "nil", "audio:", micURL?.path ?? "nil")
        if let screenURL {
            try? FileManager.default.removeItem(at: screenURL)
            screenWriter = try? AVAssetWriter(url: screenURL, fileType: .mp4)
        }
        if let micURL {
            try? FileManager.default.removeItem(at: micURL)
            micWriter = try? AVAssetWriter(url: micURL, fileType: .m4a)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let screenWriter else { return }
        if screenVideoInput == nil {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let width = evenDimension(Int(dimensions.width))
            let height = evenDimension(Int(dimensions.height))
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            if screenWriter.canAdd(input) {
                screenWriter.add(input)
                screenVideoInput = input
            }
        }
        guard let screenVideoInput else { return }

        if screenWriter.status == .unknown {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            screenStartTime = ts
            screenWriter.startWriting()
            screenWriter.startSession(atSourceTime: ts)
        }
        if screenWriter.status == .writing && screenVideoInput.isReadyForMoreMediaData {
            screenVideoInput.append(sampleBuffer)
        }
        if screenWriter.status == .failed, !didLogWriterFailure {
            didLogWriterFailure = true
            let reason = screenWriter.error?.localizedDescription ?? "unknown"
            print("BroadcastUpload video writer failed:", reason)
            writeUploadTrace(phase: "writer_failed", eventId: nil, error: reason)
        }
    }

    private func appendMic(_ sampleBuffer: CMSampleBuffer) {
        guard let micWriter else { return }
        if micInput == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if micWriter.canAdd(input) {
                micWriter.add(input)
                micInput = input
            }
        }
        guard let micInput else { return }

        if micWriter.status == .unknown {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            micStartTime = ts
            micWriter.startWriting()
            micWriter.startSession(atSourceTime: ts)
        }
        if micWriter.status == .writing && micInput.isReadyForMoreMediaData {
            micInput.append(sampleBuffer)
        }
    }

    private func finalizeWriters(reason: String) {
        writeUploadTrace(phase: "finalize_begin", eventId: nil, error: nil)
        finalizeHandled = false
        screenVideoInput?.markAsFinished()
        micInput?.markAsFinished()

        let screenStatus = screenWriter?.status.rawValue ?? -1
        let micStatus = micWriter?.status.rawValue ?? -1
        print("BroadcastUpload finalize writers status screen:", screenStatus, "mic:", micStatus)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            if self.finalizeHandled { return }
            self.finalizeHandled = true
            self.writeUploadTrace(phase: "finalize_timeout", eventId: nil, error: "finishWriting timeout")
            print("BroadcastUpload finalize timeout, forcing upload path")
            self.prepareAndStartUpload(reason: reason)
        }

        let group = DispatchGroup()
        if let screenWriter, screenWriter.status == .writing || screenWriter.status == .unknown {
            group.enter()
            screenWriter.finishWriting {
                group.leave()
            }
        }
        if let micWriter, micWriter.status == .writing || micWriter.status == .unknown {
            group.enter()
            micWriter.finishWriting {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if self.finalizeHandled { return }
            self.finalizeHandled = true
            let screenPath = self.screenURL?.path ?? "nil"
            let screenExists = self.screenURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let screenSize = self.screenURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
            print("BroadcastUpload finalize screen exists:", screenExists, "size:", screenSize, "path:", screenPath)
            self.writeUploadTrace(phase: "finalize_done", eventId: nil, error: nil)
            self.prepareAndStartUpload(reason: reason)
        }
    }

    @discardableResult
    private func enqueuePendingUpload(reason: String, uploadId: String? = nil) -> String? {
        guard let screenURL else { return nil }
        let duration = Int((Date().timeIntervalSince(startedAt ?? Date())).rounded(.up))
        let id = uploadId ?? UUID().uuidString
        var payload: [String: Any] = [
            "id": id,
            "screenPath": screenURL.path,
            "durationSec": max(1, duration),
            "reason": reason,
            "endedAt": Date().timeIntervalSince1970
        ]
        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            payload["audioPath"] = micURL.path
        }
        let defaults = UserDefaults(suiteName: appGroupId)
        var queue = defaults?.array(forKey: pendingUploadsKey) as? [[String: Any]] ?? []
        queue.append(payload)
        defaults?.set(queue, forKey: pendingUploadsKey)
        defaults?.synchronize()
        print("BroadcastUpload queued item:", id, "reason:", reason, "duration:", duration)
        print("BroadcastUpload queued paths screen:", screenURL.path, "audio:", (payload["audioPath"] as? String) ?? "nil")
        print("BROADCAST_UPLOAD_QUEUED uploadId=\(id) reason=\(reason) duration=\(duration)")
        return id
    }

    private func removePendingUpload(uploadId: String?) {
        guard let uploadId, !uploadId.isEmpty else { return }
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        var queue = defaults.array(forKey: pendingUploadsKey) as? [[String: Any]] ?? []
        queue.removeAll { item in
            (item["id"] as? String) == uploadId
        }
        defaults.set(queue, forKey: pendingUploadsKey)
        defaults.synchronize()
        print("BroadcastUpload removed queued item:", uploadId)
        print("BROADCAST_UPLOAD_QUEUE_CLEARED uploadId=\(uploadId)")
    }

    private func loadSharedCredentials() -> SharedCredentials? {
        let defaults = UserDefaults(suiteName: appGroupId)
        guard let token = defaults?.string(forKey: sharedAuthTokenKey), !token.isEmpty else { return nil }
        guard let deviceId = defaults?.string(forKey: sharedDeviceIdKey), !deviceId.isEmpty else { return nil }
        return SharedCredentials(token: token, deviceId: deviceId)
    }

    private func prepareAndStartUpload(reason: String) {
        guard let context = prepareUploadContext(reason: reason) else {
            resetWriters()
            return
        }
        guard context.credentials != nil else {
            resetWriters()
            return
        }
        Task.detached(priority: .background) { [weak self] in
            await self?.performImmediateUpload(context: context)
        }
    }

    private func prepareUploadContext(reason: String) -> PreparedUploadContext? {
        writeUploadTrace(phase: "upload_entry", eventId: nil, error: nil)
        let duration = max(1, Int((Date().timeIntervalSince(startedAt ?? Date())).rounded(.up)))
        guard screenURL != nil else {
            writeUploadTrace(phase: "upload_entry_no_screen_url", eventId: nil, error: nil)
            return nil
        }
        guard let promoted = promoteMediaFilesToAppGroup() else {
            updateStatus("pending_upload")
            writeUploadTrace(phase: "promote_failed", eventId: nil, error: "promote media to app group failed")
            print("BROADCAST_UPLOAD_FINAL_FAIL uploadId=nil error=promote media to app group failed")
            return nil
        }
        let screenFileURL = promoted.screen
        let audioFileURL = promoted.audio
        screenURL = screenFileURL
        micURL = audioFileURL

        let queuedUploadId = enqueuePendingUpload(reason: reason)
        writeUploadTrace(phase: "queued_local", eventId: nil, error: nil)

        guard let queuedUploadId else {
            writeUploadTrace(phase: "queue_failed", eventId: nil, error: "enqueue failed")
            return nil
        }

        guard let credentials = loadSharedCredentials() else {
            print("BroadcastUpload immediate upload skipped: missing shared credentials")
            updateStatus("pending_upload")
            print("BROADCAST_UPLOAD_HANDOFF_OK uploadId=\(queuedUploadId) reason=\(reason)")
            postLocalNotification(
                title: "Eggtart recording saved",
                body: "Open Eggtart to upload and process this recording."
            )
            return PreparedUploadContext(
                queuedUploadId: queuedUploadId,
                reason: reason,
                duration: duration,
                screenFileURL: screenFileURL,
                audioFileURL: audioFileURL,
                credentials: nil
            )
        }

        updateStatus("uploading")
        writeUploadTrace(phase: "uploading_start", eventId: nil, error: nil)
        return PreparedUploadContext(
            queuedUploadId: queuedUploadId,
            reason: reason,
            duration: duration,
            screenFileURL: screenFileURL,
            audioFileURL: audioFileURL,
            credentials: credentials
        )
    }

    private func performImmediateUpload(context: PreparedUploadContext) async {
        guard let credentials = context.credentials else {
            return
        }
        print("BroadcastUpload immediate upload start reason:", context.reason)
        do {
            _ = try await registerDevice(credentials: credentials)

            let eventId = try await createEvent(
                credentials: credentials,
                transcript: nil,
                durationSec: context.duration
            )
            writeUploadTrace(phase: "event_created", eventId: eventId, error: nil)

            let screenRemoteURL = try await uploadMediaFile(
                credentials: credentials,
                fileURL: context.screenFileURL,
                contentType: "video/mp4"
            )
            writeUploadTrace(phase: "screen_uploaded", eventId: eventId, error: nil)

            var audioRemoteURL: String?
            if let audioFileURL = context.audioFileURL,
               FileManager.default.fileExists(atPath: audioFileURL.path),
               (try? audioFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 {
                audioRemoteURL = try await uploadMediaFile(
                    credentials: credentials,
                    fileURL: audioFileURL,
                    contentType: "audio/m4a"
                )
                writeUploadTrace(phase: "audio_uploaded", eventId: eventId, error: nil)
            }

            _ = try await patchEvent(
                credentials: credentials,
                eventId: eventId,
                transcript: nil,
                screenRecordingURL: screenRemoteURL,
                audioURL: audioRemoteURL,
                durationSec: context.duration
            )
            writeUploadTrace(phase: "event_patched", eventId: eventId, error: nil)
            removePendingUpload(uploadId: context.queuedUploadId)
            updateStatus("uploaded")

            try? FileManager.default.removeItem(at: context.screenFileURL)
            if let audioFileURL = context.audioFileURL {
                try? FileManager.default.removeItem(at: audioFileURL)
            }
            print("BroadcastUpload immediate upload ok eventId:", eventId, "reason:", context.reason)
            print("BROADCAST_UPLOAD_FINAL_OK eventId=\(eventId) reason=\(context.reason)")
            postLocalNotification(
                title: "Eggtart upload complete",
                body: "Your recording was uploaded and is being processed into Eggbook."
            )
        } catch {
            print("BroadcastUpload immediate upload failed:", error.localizedDescription)
            writeUploadTrace(phase: "upload_failed", eventId: nil, error: error.localizedDescription)
            updateStatus("pending_upload")
            print("BROADCAST_UPLOAD_FINAL_FAIL uploadId=\(context.queuedUploadId) error=\(error.localizedDescription)")
            postLocalNotification(
                title: "Eggtart upload pending",
                body: "Upload failed just now. Open Eggtart later to retry."
            )
        }
        resetWriters()
    }

    private func registerDevice(credentials: SharedCredentials) async throws -> String {
        guard let url = URL(string: "\(backendBaseURL)/v1/devices") else {
            throw NSError(domain: "eggtart.broadcast", code: -2010, userInfo: [NSLocalizedDescriptionKey: "invalid devices url"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "device_id": credentials.deviceId,
            "device_model": "iPhone",
            "os": "iOS",
            "language": Locale.preferredLanguages.first ?? "en",
            "timezone": TimeZone.current.identifier
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "eggtart.broadcast", code: -2011, userInfo: [NSLocalizedDescriptionKey: "invalid register device response"])
        }
        if 200..<300 ~= http.statusCode {
            return credentials.deviceId
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "eggtart.broadcast", code: -2012, userInfo: [NSLocalizedDescriptionKey: "register device failed \(http.statusCode) \(text)"])
    }

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "eggtart.broadcast.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("BroadcastUpload local notification failed:", error.localizedDescription)
            }
        }
    }

    private func uploadMediaFile(
        credentials: SharedCredentials,
        fileURL: URL,
        contentType: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "\(backendBaseURL)/v1/uploads/recording")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "content_type": contentType,
            "filename": fileURL.lastPathComponent,
            "size_bytes": (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "eggtart.broadcast", code: -2001, userInfo: [NSLocalizedDescriptionKey: "request upload failed \(text)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadURLString = json["uploadUrl"] as? String,
              let fileURLString = json["fileUrl"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            throw NSError(domain: "eggtart.broadcast", code: -2002, userInfo: [NSLocalizedDescriptionKey: "invalid upload response"])
        }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, putResponse) = try await urlSession.upload(for: put, fromFile: fileURL)
        guard let putHTTP = putResponse as? HTTPURLResponse, 200..<300 ~= putHTTP.statusCode else {
            throw NSError(domain: "eggtart.broadcast", code: -2003, userInfo: [NSLocalizedDescriptionKey: "upload file failed"])
        }
        return fileURLString
    }

    private func createEvent(
        credentials: SharedCredentials,
        transcript: String?,
        durationSec: Int
    ) async throws -> String {
        await logWhoAmIBeforeEventMutation(credentials: credentials, action: "POST /v1/events (BroadcastUpload)")
        var request = URLRequest(url: URL(string: "\(backendBaseURL)/v1/events")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any?] = [
            "device_id": credentials.deviceId,
            "transcript": transcript,
            "duration_sec": durationSec
        ]
        let compact = body.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: compact)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "eggtart.broadcast", code: -2004, userInfo: [NSLocalizedDescriptionKey: "create event failed \(text)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = json["eventId"] as? String else {
            throw NSError(domain: "eggtart.broadcast", code: -2005, userInfo: [NSLocalizedDescriptionKey: "invalid event response"])
        }
        return eventId
    }

    private func patchEvent(
        credentials: SharedCredentials,
        eventId: String,
        transcript: String?,
        screenRecordingURL: String,
        audioURL: String?,
        durationSec: Int
    ) async throws -> String {
        await logWhoAmIBeforeEventMutation(credentials: credentials, action: "PATCH /v1/events/\(eventId) (BroadcastUpload)")
        var request = URLRequest(url: URL(string: "\(backendBaseURL)/v1/events/\(eventId)")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any?] = [
            "recording_url": screenRecordingURL,
            "audio_url": audioURL,
            "screen_recording_url": screenRecordingURL,
            "transcript": transcript,
            "duration_sec": durationSec
        ]
        let compact = body.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: compact)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "eggtart.broadcast", code: -2006, userInfo: [NSLocalizedDescriptionKey: "patch event failed \(text)"])
        }
        return eventId
    }

    private func logWhoAmIBeforeEventMutation(credentials: SharedCredentials, action: String) async {
        guard let url = URL(string: "\(backendBaseURL)/v1/auth/whoami") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("BroadcastUpload whoami failed before", action, "- invalid response")
                return
            }
            if 200..<300 ~= http.statusCode {
                let text = String(data: data, encoding: .utf8) ?? ""
                print("BroadcastUpload whoami before", action, "status:", http.statusCode, "body:", text)
            } else {
                let text = String(data: data, encoding: .utf8) ?? ""
                print("BroadcastUpload whoami failed before", action, "status:", http.statusCode, "body:", text)
            }
        } catch {
            print("BroadcastUpload whoami error before", action, ":", error.localizedDescription)
        }
    }

    private func resetWriters() {
        screenWriter = nil
        screenVideoInput = nil
        screenStartTime = nil
        screenURL = nil
        micWriter = nil
        micInput = nil
        micStartTime = nil
        micURL = nil
        startedAt = nil
        didLogWriterFailure = false
        finalizeHandled = false
    }

    private func promoteMediaFilesToAppGroup() -> (screen: URL, audio: URL?)? {
        writeUploadTrace(phase: "promote_begin", eventId: nil, error: nil)
        guard let currentScreenURL = screenURL else { return nil }
        guard FileManager.default.fileExists(atPath: currentScreenURL.path) else {
            print("BroadcastUpload promote failed: screen file missing at", currentScreenURL.path)
            return nil
        }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            print("BroadcastUpload promote failed: app group container unavailable")
            return nil
        }

        let destScreenURL = containerURL.appendingPathComponent(currentScreenURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destScreenURL)
        do {
            try FileManager.default.moveItem(at: currentScreenURL, to: destScreenURL)
        } catch {
            do {
                try FileManager.default.copyItem(at: currentScreenURL, to: destScreenURL)
            } catch {
                print("BroadcastUpload promote failed copying screen:", error.localizedDescription)
                return nil
            }
        }

        var destAudioURL: URL?
        if let currentMicURL = micURL, FileManager.default.fileExists(atPath: currentMicURL.path) {
            let candidate = containerURL.appendingPathComponent(currentMicURL.lastPathComponent)
            try? FileManager.default.removeItem(at: candidate)
            do {
                try FileManager.default.moveItem(at: currentMicURL, to: candidate)
                destAudioURL = candidate
            } catch {
                do {
                    try FileManager.default.copyItem(at: currentMicURL, to: candidate)
                    destAudioURL = candidate
                } catch {
                    print("BroadcastUpload promote audio copy failed:", error.localizedDescription)
                }
            }
        }

        let screenSize = (try? destScreenURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let audioSize = destAudioURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        print("BroadcastUpload promoted to app group screen:", destScreenURL.path, "size:", screenSize, "audio:", destAudioURL?.path ?? "nil", "audioSize:", audioSize)
        writeUploadTrace(phase: "promote_done", eventId: nil, error: nil)
        return (destScreenURL, destAudioURL)
    }

    private func evenDimension(_ raw: Int) -> Int {
        let clamped = max(2, raw)
        return clamped % 2 == 0 ? clamped : clamped - 1
    }

    private func scheduleAutoStop() {
        autoStopTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + maxDurationSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.updateStatus("auto_stopping")
            self.stopReason = "auto_timeout_30min"
            self.finishBroadcastWithError(
                NSError(
                    domain: "eggtart.broadcast",
                    code: 30_000,
                    userInfo: [NSLocalizedDescriptionKey: "Broadcast reached 30 minutes and stopped automatically."]
                )
            )
        }
        autoStopTimer = timer
        timer.resume()
    }
}
