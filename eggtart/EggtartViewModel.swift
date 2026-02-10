import AVFoundation
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class EggtartViewModel: ObservableObject {
    struct DemoEggbookPayload {
        let ideaTitle: String
        let ideaDetail: String
        let todoItems: [String]
    }

    private enum LiveSetupProfile {
        case minimal
        case withSpeechAndMedia
        case full
    }
    enum ConversationState {
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

    @Published var state: ConversationState = .idle
    @Published var micEnabled: Bool = false
    @Published var isProcessingAudio: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var hasBookUpdates: Bool = false
    @Published var showLibrary: Bool = false
    @Published var micPermissionStatus: MicPermissionStatus = .idle
    @Published private(set) var userId: String?
    @Published var hasInputToday: Bool = false
    @Published var activeSecondsToday: Int = 0
    @Published var commentsGenerating: Bool = false
    @Published var commentsReadyToday: Bool = false
    @Published var hasProcessingEvents: Bool = false
    @Published var hasUploadProcessingPending: Bool = false
    @Published var callEndedMessage: String?
    @Published var demoSyncBannerText: String?
    @Published var demoPayloadVersion: Int = 0

    let video = VideoPlaybackController()
    let gemini = GeminiLiveClient()

    private var pendingResponse: Bool = false
    private var permissionTimeoutTask: Task<Void, Never>?
    private var activeTimerTask: Task<Void, Never>?
    private var processingBannerTask: Task<Void, Never>?
    private var callEndedTask: Task<Void, Never>?
    private var voiceIdleTask: Task<Void, Never>?
    private var demoSyncTask: Task<Void, Never>?
    private var currentDayKey: String = EggtartViewModel.dayKey(for: Date())
    private static var didRunDebugApis: Bool = false
    private static let enableDebugApiSuite = ProcessInfo.processInfo.environment["EGGTART_RUN_DEBUG_APIS"] == "1"
    private let deviceId: String = DeviceIdManager.shared.loadOrCreateDeviceId()
    private var voiceEventId: String?
    private var voiceEventIdPendingUpload: String?
    private var voiceDurationSecPendingUpload: Int?
    private var voiceEventStart: Date?
    private var voiceHadSpeech: Bool = false
    private var voiceHadSpeechPendingUpload: Bool = false
    private var voiceEventsUploading: Set<String> = []
    private var voiceEventsFinalized: Set<String> = []
    private let liveSetupProfile: LiveSetupProfile = .minimal
    private let appGroupId = "group.eggtart.screenrecord"
    private let sharedAuthTokenKey = "shared.authToken"
    private let sharedDeviceIdKey = "shared.deviceId"
    private let notificationPermissionRequestedKey = "eggtart.notificationPermissionRequested"
    private let uploadProcessingPendingKey = "eggtart.uploadProcessingPending"
    private(set) var demoEggbookPayload: DemoEggbookPayload?
    private static let defaultDemoEggbookPayload = DemoEggbookPayload(
        ideaTitle: "Xiaohongshu (小红书) UI/UX Design Reference",
        ideaDetail: "You are analyzing Xiaohongshu's signature two-column masonry grid, focusing on how it balances high-density information with a clean aesthetic. You noted the specific alignment of the cover images, the 'neat' typographic hierarchy of the titles, and the placement of interaction cues like the 'like' icon and user avatars. You plan to replicate this organized visual rhythm to ensure your app feels intuitive and professional.",
        todoItems: [
            "Identify and adapt specific Xiaohongshu UI components for your project's wireframes."
        ]
    )

    init() {
        hasUploadProcessingPending = UserDefaults.standard.bool(forKey: uploadProcessingPendingKey)
        bindGeminiCallbacks()
        bindAudioUploadCallbacks()
        video.playOnceThenLoop(.sleeptowake, loop: .default) { [weak self] in
            self?.state = .idle
        }
    }

    func onAppear() {
        ensureDemoEggbookSeeded()
        requestNotificationPermissionIfNeeded()
        syncBroadcastSharedCredentials()
        bootstrapIdentity()
        setAppActive(true)
    }

    func requestMicPermission() {
        permissionTimeoutTask?.cancel()
        micPermissionStatus = .requesting
        permissionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if self.micPermissionStatus == .requesting {
                    self.micPermissionStatus = .timedOut
                    self.micEnabled = false
                    self.endVoiceSession(showBanner: false)
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
                        self.endVoiceSession(showBanner: false)
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
                        self.endVoiceSession(showBanner: false)
                    }
                }
            }
        }
    }

    var micPermissionBannerText: String? {
        switch micPermissionStatus {
        case .denied:
            return "Microphone permission denied. Open Settings > Privacy & Security > Microphone > Eggtart."
        case .timedOut:
            return "Microphone permission timed out. Open Settings > Privacy & Security > Microphone > Eggtart."
        default:
            return nil
        }
    }

    func bootstrapIdentity() {
        print("deviceId:", deviceId)
        syncBroadcastSharedCredentials()

        Task {
            do {
                let userId = try await fetchUserId(deviceId: deviceId)
                await MainActor.run {
                    self.userId = userId
                    print("userId:", userId)
                    self.printAuthTokenIfDebug(context: "bootstrapIdentity")
                    self.syncBroadcastSharedCredentials()
                    self.connectGeminiLive()
                }
                await ensureDeviceRegistration()
                await refreshEggbookSyncStatusOnAppEntry()
                await testBackendConnection()
#if DEBUG
                if Self.enableDebugApiSuite {
                    await runDebugApiSuite(deviceId: deviceId)
                }
#endif
            } catch {
                print("userId fetch failed:", error.localizedDescription)
                await MainActor.run {
                    self.syncBroadcastSharedCredentials()
                }
            }
        }
    }

    private func ensureDeviceRegistration() async {
        do {
            _ = try await APIClient.shared.registerDevice(deviceId: deviceId)
            print("device registration ok:", deviceId)
        } catch {
            print("device registration failed, self-heal auth retry:", error.localizedDescription)
            do {
                let auth = try await APIClient.shared.authenticateAnonymous(deviceId: deviceId)
                await MainActor.run {
                    self.userId = auth.userId
                    self.printAuthTokenIfDebug(context: "deviceSelfHeal")
                    self.syncBroadcastSharedCredentials()
                }
                _ = try await APIClient.shared.registerDevice(deviceId: deviceId)
                print("device self-heal registration ok:", deviceId)
            } catch {
                print("device self-heal registration failed:", error.localizedDescription)
            }
        }
    }

    private func syncBroadcastSharedCredentials() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(deviceId, forKey: sharedDeviceIdKey)
        if let token = APIClient.shared.currentToken(), !token.isEmpty {
            defaults.set(token, forKey: sharedAuthTokenKey)
            debugLog("broadcast shared credentials synced token=yes")
            printAuthTokenIfDebug(context: "syncBroadcastSharedCredentials")
        } else {
            debugLog("broadcast shared credentials synced token=no")
        }
        defaults.synchronize()
    }

    private func printAuthTokenIfDebug(context: String) {
#if DEBUG
        if let token = APIClient.shared.currentToken(), !token.isEmpty {
            print("authToken[\(context)]:", token)
        } else {
            print("authToken[\(context)]: nil")
        }
#endif
    }

    func refreshEggbookSyncStatusOnAppEntry() async {
        await refreshEggbookSyncStatus(clearBadgeWhenIdle: false)
    }

    func refreshEggbookSyncStatusAfterManualRefresh() async {
        await refreshEggbookSyncStatus(clearBadgeWhenIdle: true)
    }

    private func refreshEggbookSyncStatus(clearBadgeWhenIdle: Bool) async {
        guard APIClient.shared.currentToken() != nil else { return }
        do {
            let status = try await APIClient.shared.getEggbookSyncStatus()
            let isProcessing = status.isProcessing ?? false
            let hasUpdates = status.hasUpdates ?? false
            hasProcessingEvents = isProcessing
            if !isProcessing {
                setUploadProcessingPending(false)
            }
            if isProcessing {
                hasBookUpdates = true
            } else if hasUpdates {
                hasBookUpdates = true
            } else if clearBadgeWhenIdle {
                hasBookUpdates = false
            }
            debugLog("eggbook sync status processing=\(isProcessing) updates=\(hasUpdates)")
        } catch {
            debugLog("eggbook sync status failed: \(error.localizedDescription)")
            if clearBadgeWhenIdle && !hasProcessingEvents {
                hasBookUpdates = false
            }
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: notificationPermissionRequestedKey) else { return }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("notification permission request failed:", error.localizedDescription)
                    } else {
                        print("notification permission granted:", granted)
                    }
                }
            }
        }
        defaults.set(true, forKey: notificationPermissionRequestedKey)
    }

    func connectGeminiLive() {
        ensureGeminiConnected()
    }

    func handleTap(location: CGPoint, in size: CGSize) {
        let middleX = size.width / 3.0
        let topY = size.height / 3.0
        let midY = 2.0 * size.height / 3.0

        let inMiddleX = location.x >= middleX && location.x <= 2.0 * middleX
        guard inMiddleX else { return }

        if location.y <= topY {
            playInteraction(.headtap)
        } else if location.y <= midY {
            playInteraction(.midtap)
        } else {
            playInteraction(.bottomtap)
        }
    }

    func resetToDefault() {
        endVoiceSession(showBanner: false)
    }

    func toggleMic() {
        debugLog("toggleMic -> \(micEnabled ? "off" : "on")")
        if micEnabled {
            micPermissionStatus = .idle
            permissionTimeoutTask?.cancel()
            endVoiceSession(showBanner: false)
        } else {
            micEnabled = true
            cancelVoiceIdleTimeout()
            ensureGeminiConnected()
            startListening()
            requestMicPermission()
        }
    }

    private func fetchUserId(deviceId: String) async throws -> String {
        if let token = APIClient.shared.currentToken(), !token.isEmpty {
            do {
                let who = try await APIClient.shared.whoAmI()
                if let userId = who.userId, !userId.isEmpty {
                    print("whoami bootstrap userId:", userId)
                    return userId
                }
                print("whoami bootstrap returned empty userId, fallback to anonymous auth")
            } catch {
                print("whoami bootstrap failed, fallback to anonymous auth:", error.localizedDescription)
            }
        } else {
            print("whoami bootstrap skipped: no token, fallback to anonymous auth")
        }

        let response = try await APIClient.shared.authenticateAnonymous(deviceId: deviceId)
        return response.userId
    }

    private func testBackendConnection() async {
        do {
            let ideas = try await APIClient.shared.getIdeas()
            print("ideas count:", ideas.count)
        } catch {
            print("ideas fetch failed:", error.localizedDescription)
        }
    }

    func uploadAudioRecordingOnly(fileURL: URL, durationSec: Int) async {
        guard userId != nil else {
            print("audio note upload skipped: user not authenticated")
            return
        }
        var eventId: String?
        do {
            let event = try await APIClient.shared.createEvent(
                deviceId: deviceId,
                transcript: nil,
                recordingUrl: nil,
                audioUrl: nil,
                screenRecordingUrl: nil,
                durationSec: durationSec
            )
            eventId = event.eventId
            let sizeBytes = fileSizeBytes(fileURL)
            let upload = try await APIClient.shared.requestUpload(
                contentType: "audio/m4a",
                filename: fileURL.lastPathComponent,
                sizeBytes: sizeBytes
            )
            try await APIClient.shared.uploadFile(
                uploadUrl: upload.uploadUrl,
                fileUrl: fileURL,
                contentType: "audio/m4a"
            )
            _ = try await APIClient.shared.patchEvent(
                eventId: event.eventId,
                transcript: nil,
                recordingUrl: upload.fileUrl,
                audioUrl: upload.fileUrl,
                screenRecordingUrl: nil,
                durationSec: durationSec
            )
            print("audio note uploaded:", event.eventId, "file:", upload.fileUrl)
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            print("audio note upload failed:", error.localizedDescription, "eventId:", eventId ?? "nil")
        }
    }

    func uploadScreenRecording(
        screenURL: URL,
        micURL: URL?,
        durationSec: Int,
        reason: String
    ) async {
        guard userId != nil else {
            print("screen recording upload skipped: user not authenticated")
            return
        }

        var uploadedScreenURL: String?
        var uploadedAudioURL: String?
        var eventId: String?

        defer {
            try? FileManager.default.removeItem(at: screenURL)
            if let micURL {
                try? FileManager.default.removeItem(at: micURL)
            }
        }

        do {
            let event = try await APIClient.shared.createEvent(
                deviceId: deviceId,
                transcript: nil,
                recordingUrl: nil,
                audioUrl: nil,
                screenRecordingUrl: nil,
                durationSec: durationSec
            )
            eventId = event.eventId

            let screenUpload = try await APIClient.shared.requestUpload(
                contentType: "video/mp4",
                filename: screenURL.lastPathComponent,
                sizeBytes: fileSizeBytes(screenURL)
            )
            try await APIClient.shared.uploadFile(
                uploadUrl: screenUpload.uploadUrl,
                fileUrl: screenURL,
                contentType: "video/mp4"
            )
            uploadedScreenURL = screenUpload.fileUrl

            if let micURL,
               FileManager.default.fileExists(atPath: micURL.path),
               (fileSizeBytes(micURL) ?? 0) > 0 {
                let audioUpload = try await APIClient.shared.requestUpload(
                    contentType: "audio/m4a",
                    filename: micURL.lastPathComponent,
                    sizeBytes: fileSizeBytes(micURL)
                )
                try await APIClient.shared.uploadFile(
                    uploadUrl: audioUpload.uploadUrl,
                    fileUrl: micURL,
                    contentType: "audio/m4a"
                )
                uploadedAudioURL = audioUpload.fileUrl
            }

            if let eventId {
                _ = try await APIClient.shared.patchEvent(
                    eventId: eventId,
                    transcript: nil,
                    recordingUrl: uploadedScreenURL ?? uploadedAudioURL,
                    audioUrl: uploadedAudioURL,
                    screenRecordingUrl: uploadedScreenURL,
                    durationSec: durationSec
                )
                setUploadProcessingPending(true)
                hasProcessingEvents = true
                hasBookUpdates = true
                print("screen event updated:", eventId, "screen:", uploadedScreenURL ?? "nil", "audio:", uploadedAudioURL ?? "nil")
                print("SCREEN_UPLOAD_FINAL_OK eventId=\(eventId) screen=\(uploadedScreenURL ?? "nil") audio=\(uploadedAudioURL ?? "nil") reason=\(reason)")
            }
        } catch {
            print("screen recording upload failed:", error.localizedDescription, "eventId:", eventId ?? "nil")
            print("SCREEN_UPLOAD_FINAL_FAIL eventId=\(eventId ?? "nil") error=\(error.localizedDescription) reason=\(reason)")
        }
    }

    private func uploadVoiceRecording(fileURL: URL, durationSec: Int) async {
        guard userId != nil else {
            print("voice recording upload skipped: user not authenticated")
            return
        }
        guard voiceHadSpeechPendingUpload else {
            try? FileManager.default.removeItem(at: fileURL)
            print("voice recording upload skipped: no speech detected")
            return
        }
        do {
            let existingEventId = voiceEventIdPendingUpload ?? voiceEventId
            let finalDurationSec = voiceDurationSecPendingUpload ?? durationSec
            let sizeBytes = fileSizeBytes(fileURL)
            let contentType = contentTypeForAudio(fileURL)
            let eventIdForPatch: String
            if let existingEventId {
                eventIdForPatch = existingEventId
            } else {
                let event = try await APIClient.shared.createEvent(
                    deviceId: deviceId,
                    transcript: nil,
                    recordingUrl: nil,
                    audioUrl: nil,
                    screenRecordingUrl: nil,
                    durationSec: finalDurationSec
                )
                eventIdForPatch = event.eventId
            }
            if voiceEventsFinalized.contains(eventIdForPatch) {
                print("voice event patch skipped: already finalized", eventIdForPatch)
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            if voiceEventsUploading.contains(eventIdForPatch) {
                print("voice event patch skipped: upload already in flight", eventIdForPatch)
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            voiceEventsUploading.insert(eventIdForPatch)
            defer { voiceEventsUploading.remove(eventIdForPatch) }
            let upload = try await APIClient.shared.requestUpload(
                contentType: contentType,
                filename: fileURL.lastPathComponent,
                sizeBytes: sizeBytes
            )
            try await APIClient.shared.uploadFile(
                uploadUrl: upload.uploadUrl,
                fileUrl: fileURL,
                contentType: contentType
            )
            _ = try await APIClient.shared.patchEvent(
                eventId: eventIdForPatch,
                transcript: nil,
                recordingUrl: upload.fileUrl,
                audioUrl: upload.fileUrl,
                screenRecordingUrl: nil,
                durationSec: finalDurationSec
            )
            setUploadProcessingPending(true)
            hasProcessingEvents = true
            hasBookUpdates = true
            print("voice event updated:", eventIdForPatch, "file:", upload.fileUrl)
            print("VOICE_UPLOAD_FINAL_OK eventId=\(eventIdForPatch) file=\(upload.fileUrl)")
            voiceEventsFinalized.insert(eventIdForPatch)
            voiceEventIdPendingUpload = nil
            voiceDurationSecPendingUpload = nil
            voiceHadSpeechPendingUpload = false
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            print("voice recording upload failed:", error.localizedDescription)
            let failedEventId = voiceEventIdPendingUpload ?? voiceEventId ?? "nil"
            print("VOICE_UPLOAD_FINAL_FAIL eventId=\(failedEventId) error=\(error.localizedDescription)")
        }
    }

    private func fileSizeBytes(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }

    private func contentTypeForAudio(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m4a":
            return "audio/m4a"
        case "caf":
            return "audio/x-caf"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }

    private func beginVoiceEvent() {
        guard userId != nil else {
            print("voice event skipped: user not authenticated")
            return
        }
        guard voiceEventId == nil else { return }
        voiceHadSpeech = true
        voiceEventStart = Date()

        Task { [weak self] in
            guard let self else { return }
            do {
            let response = try await APIClient.shared.createEvent(
                deviceId: self.deviceId,
                transcript: nil,
                recordingUrl: nil,
                audioUrl: nil,
                screenRecordingUrl: nil,
                durationSec: nil
            )
                await MainActor.run {
                    self.voiceEventId = response.eventId
                }
            } catch {
                print("voice event create failed:", error.localizedDescription)
            }
        }
    }

    private func endVoiceEvent() {
        guard voiceEventId != nil || voiceEventStart != nil else { return }
        guard userId != nil else {
            print("voice event skipped: user not authenticated")
            return
        }

        let durationSec: Int?
        if let start = voiceEventStart {
            durationSec = max(1, Int(Date().timeIntervalSince(start)))
        } else {
            durationSec = nil
        }

        let eventId = voiceEventId
        voiceEventStart = nil
        voiceEventId = nil
        voiceEventIdPendingUpload = eventId
        voiceDurationSecPendingUpload = durationSec
        debugLog("voice event finalize deferred until upload eventId=\(eventId ?? "nil") duration=\(durationSec ?? 0)")
    }

    private func scheduleVoiceIdleTimeout() {
        debugLog("scheduleVoiceIdleTimeout")
        voiceIdleTask?.cancel()
        voiceIdleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard let self else { return }
                debugLog("voiceIdleTimeout fired micEnabled=\(self.micEnabled) hadSpeech=\(self.voiceHadSpeech)")
                guard self.micEnabled else { return }
                let shouldShow = self.voiceHadSpeech
                self.endVoiceSession(showBanner: shouldShow)
            }
        }
    }

    private func cancelVoiceIdleTimeout() {
        voiceIdleTask?.cancel()
        voiceIdleTask = nil
    }

    private func endVoiceSession(showBanner: Bool) {
        debugLog("endVoiceSession showBanner=\(showBanner) micEnabled=\(micEnabled) hadSpeech=\(voiceHadSpeech)")
        cancelVoiceIdleTimeout()
        voiceHadSpeechPendingUpload = voiceHadSpeech
        voiceHadSpeech = false
        endVoiceEvent()
        micEnabled = false
        gemini.stopMicrophone()
        pendingResponse = false
        isProcessingAudio = false
        isSpeaking = false
        state = .idle
        video.playLoop(.default)
        if showBanner {
            showCallEndedBanner()
        }
    }

    private func showCallEndedBanner() {
        callEndedTask?.cancel()
        callEndedMessage = "Call ended."
        callEndedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                self?.callEndedMessage = nil
            }
        }
    }

#if DEBUG
    private func runDebugApiSuite(deviceId: String) async {
        guard !Self.didRunDebugApis else { return }
        Self.didRunDebugApis = true

        do {
            _ = try await APIClient.shared.registerDevice(deviceId: deviceId)
        } catch {
            print("debug devices failed:", error.localizedDescription)
        }

        do {
            _ = try await APIClient.shared.createMemory(type: "note", content: "debug memory", importance: 0.2)
        } catch {
            print("debug memory failed:", error.localizedDescription)
        }

        var eventId: String?
        do {
            let event = try await APIClient.shared.createEvent(
                deviceId: deviceId,
                transcript: "debug transcript",
                recordingUrl: nil,
                durationSec: 12
            )
            eventId = event.eventId
        } catch {
            print("debug create event failed:", error.localizedDescription)
        }

        if let eventId {
            do {
                _ = try await APIClient.shared.patchEvent(
                    eventId: eventId,
                    transcript: "debug transcript updated",
                    recordingUrl: nil,
                    durationSec: 20
                )
            } catch {
                print("debug patch event failed:", error.localizedDescription)
            }

            do {
                _ = try await APIClient.shared.getEventStatus(eventId: eventId)
            } catch {
                print("debug event status failed:", error.localizedDescription)
            }
        }

        var ideaId: String?
        do {
            let idea = try await APIClient.shared.createIdea(title: "Debug idea", content: "idea detail")
            ideaId = idea.id
        } catch {
            print("debug create idea failed:", error.localizedDescription)
        }

        if let ideaId {
            do {
                _ = try await APIClient.shared.deleteIdea(id: ideaId)
            } catch {
                print("debug delete idea failed:", error.localizedDescription)
            }
        }

        do {
            _ = try await APIClient.shared.getTodos()
        } catch {
            print("debug get todos failed:", error.localizedDescription)
        }

        var todoId: String?
        do {
            let todo = try await APIClient.shared.createTodo(title: "debug todo")
            todoId = todo.id
        } catch {
            print("debug create todo failed:", error.localizedDescription)
        }

        if let todoId {
            do {
                _ = try await APIClient.shared.acceptTodo(id: todoId)
            } catch {
                print("debug accept todo failed:", error.localizedDescription)
            }

            do {
                _ = try await APIClient.shared.deleteTodo(id: todoId)
            } catch {
                print("debug delete todo failed:", error.localizedDescription)
            }
        }

        do {
            _ = try await APIClient.shared.getNotifications()
        } catch {
            print("debug get notifications failed:", error.localizedDescription)
        }

        var notificationId: String?
        do {
            let notification = try await APIClient.shared.createNotification(
                title: "debug notification",
                notifyAt: isoDateTime(afterMinutes: 60),
                todoId: todoId
            )
            notificationId = notification.id
        } catch {
            print("debug create notification failed:", error.localizedDescription)
        }

        if let notificationId {
            do {
                _ = try await APIClient.shared.updateNotification(
                    id: notificationId,
                    notifyAt: isoDateTime(afterMinutes: 120)
                )
            } catch {
                print("debug update notification failed:", error.localizedDescription)
            }

            do {
                _ = try await APIClient.shared.deleteNotification(id: notificationId)
            } catch {
                print("debug delete notification failed:", error.localizedDescription)
            }
        }

        let today = dayString(for: Date())
        do {
            _ = try await APIClient.shared.getComments(date: today, days: 7)
        } catch {
            print("debug get comments failed:", error.localizedDescription)
        }

        do {
            _ = try await APIClient.shared.createComment(
                content: "debug comment",
                date: today,
                isCommunity: false
            )
        } catch {
            print("debug create comment failed:", error.localizedDescription)
        }
    }

    private func isoDateTime(afterMinutes minutes: Int) -> String {
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
#endif
    func startListening() {
        ensureGeminiConnected()
        guard state == .idle, micEnabled else { return }
        debugLog("startListening (listening animation disabled)")
        pendingResponse = false
        isProcessingAudio = false
        isSpeaking = false
        state = .idle
        video.playLoop(.default)
    }

    func stopListening() {
        debugLog("stopListening (listening animation disabled)")
        if state != .speakingIntro && state != .speakingLoop {
            isProcessingAudio = false
            state = .idle
            video.playLoop(.default)
        }
    }

    func startRespondingSequence() {
        guard micEnabled else { return }
        guard state != .speakingIntro && state != .speakingLoop else { return }
        pendingResponse = false
        isProcessingAudio = true
        isSpeaking = true
        state = .speakingLoop
        video.playLoop(.speaking1)
    }

    func finishSpeaking() {
        guard state == .speakingLoop || state == .speakingIntro else { return }
        state = .idle
        isSpeaking = false
        isProcessingAudio = false
        video.playLoop(.default)
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
                self?.cancelVoiceIdleTimeout()
                self?.beginVoiceEvent()
            }
        }
        gemini.onUserSpeechEnd = { [weak self] in
            Task { @MainActor in
                self?.registerUserInput(source: "voice")
                self?.pendingResponse = false
                self?.scheduleVoiceIdleTimeout()
            }
        }
        gemini.onResponseStart = { [weak self] in
            Task { @MainActor in
                self?.pendingResponse = true
                self?.isProcessingAudio = true
                self?.startRespondingSequence()
            }
        }
        gemini.onResponseEnd = { [weak self] in
            Task { @MainActor in
                self?.finishSpeaking()
            }
        }
    }

    private func bindAudioUploadCallbacks() {
        gemini.onAudioFileReady = { [weak self] url, duration in
            Task { await self?.uploadVoiceRecording(fileURL: url, durationSec: duration) }
        }
    }

    private func ensureGeminiConnected() {
        guard !gemini.isConnected else { return }
        guard let wsURL = APIClient.shared.realtimeWebSocketURL() else {
            print("Gemini WS url missing (token not ready)")
            return
        }
        let liveModel = "models/gemini-2.5-flash-native-audio-preview-12-2025"
        let allowAudioStreaming = true
        let voiceName: String?
        let mediaResolution: String?
        let contextWindowTriggerTokens: Int?
        let contextWindowTargetTokens: Int?
        switch liveSetupProfile {
        case .minimal:
            voiceName = nil
            mediaResolution = nil
            contextWindowTriggerTokens = nil
            contextWindowTargetTokens = nil
        case .withSpeechAndMedia:
            voiceName = "Zephyr"
            mediaResolution = "MEDIA_RESOLUTION_MEDIUM"
            contextWindowTriggerTokens = nil
            contextWindowTargetTokens = nil
        case .full:
            voiceName = "Zephyr"
            mediaResolution = "MEDIA_RESOLUTION_MEDIUM"
            contextWindowTriggerTokens = 25600
            contextWindowTargetTokens = 12800
        }
        let configuration = GeminiLiveClient.Configuration(
            webSocketURL: wsURL,
            model: liveModel,
            responseModalities: ["AUDIO"],
            authToken: APIClient.shared.currentToken(),
            inputAudioMimeType: nil,
            outputAudioMimeType: nil,
            realtimeChunkMimeType: "audio/pcm;rate=16000",
            voiceName: voiceName,
            mediaResolution: mediaResolution,
            contextWindowTriggerTokens: contextWindowTriggerTokens,
            contextWindowTargetTokens: contextWindowTargetTokens,
            allowAudioStreaming: allowAudioStreaming
        )
        gemini.connect(configuration: configuration)
    }
}

extension EggtartViewModel {
    var canManualGenerateComments: Bool {
        !commentsGenerating
    }

    func registerUserInput(source: String) {
        updateDayIfNeeded()
        hasInputToday = true
        print("input recorded:", source)
    }

    func triggerCommentsGeneration(manual: Bool) {
        updateDayIfNeeded()
        guard !commentsGenerating else { return }
        if !manual && commentsReadyToday { return }
        if !manual && activeSecondsToday < 3600 { return }
        commentsGenerating = true
        print("comments generating:", manual ? "manual" : "auto")

        Task { [weak self] in
            guard let self else { return }
            let today = Self.dayKey(for: Date())
            do {
                try await APIClient.shared.triggerCommentsGeneration(date: today, manual: manual)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await self.refreshEggbookSyncStatusAfterManualRefresh()
                await MainActor.run {
                    self.commentsGenerating = false
                    self.commentsReadyToday = true
                    print("comments ready - request sent to backend")
                }
            } catch {
                await MainActor.run {
                    self.commentsGenerating = false
                    self.commentsReadyToday = false
                    print("comments generation request failed:", error.localizedDescription)
                }
            }
        }
    }

    func markProcessingEvent() {
        hasProcessingEvents = true
        processingBannerTask?.cancel()
        processingBannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            await MainActor.run {
                self?.hasProcessingEvents = false
            }
        }
    }

    func triggerEggbookProcessingFallbackDemo() {
        demoSyncTask?.cancel()
        setUploadProcessingPending(true)
        hasProcessingEvents = true
        hasBookUpdates = true

        demoSyncTask = Task { [weak self] in
            guard let self else { return }
            for second in stride(from: 10, through: 1, by: -1) {
                await MainActor.run {
                    self.demoSyncBannerText = "New items are processing... \(second)s"
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let payload = Self.defaultDemoEggbookPayload

            await MainActor.run {
                self.demoEggbookPayload = payload
                self.demoPayloadVersion += 1
                self.setUploadProcessingPending(false)
                self.hasProcessingEvents = false
                self.demoSyncBannerText = "Updated."
                self.hasBookUpdates = true
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if self.demoSyncBannerText == "Updated." {
                    self.demoSyncBannerText = nil
                }
            }
        }
    }

    private func ensureDemoEggbookSeeded() {
        guard demoEggbookPayload == nil else { return }
        demoEggbookPayload = Self.defaultDemoEggbookPayload
        demoPayloadVersion += 1
    }

    private func setUploadProcessingPending(_ pending: Bool) {
        hasUploadProcessingPending = pending
        UserDefaults.standard.set(pending, forKey: uploadProcessingPendingKey)
    }

    func setAppActive(_ active: Bool) {
        if active {
            startActiveTimer()
        } else {
            activeTimerTask?.cancel()
            activeTimerTask = nil
        }
    }

    private func startActiveTimer() {
        guard activeTimerTask == nil else { return }
        activeTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    self.updateDayIfNeeded()
                    self.activeSecondsToday += 1
                    if self.hasInputToday && self.activeSecondsToday >= 3600 {
                        self.triggerCommentsGeneration(manual: false)
                    }
                }
            }
        }
    }

    private func updateDayIfNeeded() {
        let newKey = Self.dayKey(for: Date())
        guard newKey != currentDayKey else { return }
        currentDayKey = newKey
        hasInputToday = false
        activeSecondsToday = 0
        commentsGenerating = false
        commentsReadyToday = false
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
