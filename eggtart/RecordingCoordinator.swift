import Combine
import SwiftUI
import UIKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    struct BroadcastUploadItem {
        let id: String
        let screenURL: URL
        let audioURL: URL?
        let durationSec: Int
        let reason: String
    }

    enum RecordingState {
        case idle
        case recording
        case processing
    }

    @Published var state: RecordingState = .idle
    @Published var permissionMessage: String?
    @Published var showsSettingsButton: Bool = false
    @Published var showBroadcastIntro: Bool = false
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onRecordingFinished: ((Int) -> Void)?
    var onBroadcastFilesReady: ((BroadcastUploadItem) -> Void)?
    var onProcessingFallback: (() -> Void)?

    private var autoStopTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var launchBroadcastPicker: (() -> Bool)?
    private var sharedPollTask: Task<Void, Never>?
    private var uploadingFallbackTask: Task<Void, Never>?
    private var bannerAutoClearTask: Task<Void, Never>?
    private let appGroupId = "group.eggtart.screenrecord"
    private let statusKey = "broadcast.status"
    private let pendingUploadsKey = "broadcast.pendingUploads"
    private let lastEventIdKey = "broadcast.lastEventId"
    private let lastUploadPhaseKey = "broadcast.lastUploadPhase"
    private let lastUploadErrorKey = "broadcast.lastUploadError"
    private let lastUploadUpdatedAtKey = "broadcast.lastUploadUpdatedAt"
    private var lastSeenStatus: String?
    private var lastUploadTraceFingerprint: String?
    private var appEntryCutoffEpoch: TimeInterval = 0
    let preferredBroadcastExtension = "luciayuanzhu.eggtart.BroadcastUpload"

    init() {
        startSharedPoll()
    }

    deinit {
        sharedPollTask?.cancel()
        uploadingFallbackTask?.cancel()
        bannerAutoClearTask?.cancel()
    }

    func handleMainRecordButton(startBroadcastPicker: @escaping () -> Bool) {
        debugLog("record button tapped (state=\(state))")
        permissionMessage = nil
        showsSettingsButton = false
        launchBroadcastPicker = startBroadcastPicker

        switch state {
        case .idle:
            showBroadcastIntro = true
        case .recording:
            let opened = startBroadcastPicker()
            if opened {
                stopRecording(reason: "Recording ended. We’re processing it into Eggbook. Check back later.")
            } else {
                permissionMessage = "Unable to open Broadcast picker to stop recording."
            }
        case .processing:
            // Avoid locking the record button when state is stale.
            consumePendingBroadcastUploads(force: true)
            showBroadcastIntro = true
        }
    }

    func confirmBroadcastIntro() {
        showBroadcastIntro = false
        guard let launchBroadcastPicker else {
            permissionMessage = "Broadcast picker is not available yet."
            return
        }
        let opened = launchBroadcastPicker()
        guard opened else {
            permissionMessage = "Unable to open Broadcast picker. Please make sure Broadcast Upload Extension is added to this app."
            return
        }
        startRecording()
    }

    func cancelBroadcastIntro() {
        showBroadcastIntro = false
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func consumePendingBroadcastUploadsNow() {
        consumePendingBroadcastUploads()
    }

    func discardAllPendingBroadcastUploads() {
        appEntryCutoffEpoch = Date().timeIntervalSince1970
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        let queue = defaults.array(forKey: pendingUploadsKey) as? [[String: Any]] ?? []
        defaults.removeObject(forKey: pendingUploadsKey)
        defaults.removeObject(forKey: lastEventIdKey)
        defaults.removeObject(forKey: lastUploadPhaseKey)
        defaults.removeObject(forKey: lastUploadErrorKey)
        defaults.removeObject(forKey: lastUploadUpdatedAtKey)

        let status = defaults.string(forKey: statusKey)
        if status == "pending_upload" || status == "uploading" {
            defaults.set("finished", forKey: statusKey)
        }
        defaults.synchronize()

        if state == .processing {
            state = .idle
        }
        if permissionMessage == "Upload pending. Open Eggtart later to retry upload." ||
            permissionMessage == "Uploading recording..." {
            permissionMessage = nil
        }
        debugLog("discard pending broadcast uploads count=\(queue.count) cutoff=\(Int(appEntryCutoffEpoch))")
    }

    var isRecording: Bool {
        state == .recording
    }

    var isProcessing: Bool {
        state == .processing
    }

    private func startRecording() {
        debugLog("startRecording")
        state = .recording
        recordingStartTime = Date()
        permissionMessage = "Screen recording started. You can leave the app and capture your screen now."
        showsSettingsButton = false
        onRecordingStarted?()
        scheduleAutoStop()
    }

    private func stopRecording(reason: String) {
        debugLog("stopRecording reason=\(reason)")
        autoStopTask?.cancel()
        state = .processing
        permissionMessage = reason
        showsSettingsButton = false
        onRecordingStopped?()
        let durationSec = max(1, Int(Date().timeIntervalSince(recordingStartTime ?? Date())))
        recordingStartTime = nil
        debugLog("stopRecording duration=\(durationSec)s")
        onRecordingFinished?(durationSec)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            self?.state = .idle
            if self?.permissionMessage == reason {
                self?.permissionMessage = nil
            }
        }

        // TODO: Placeholder for backend integration.
        print("recording stopped -> process into eggbook")
    }

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000_000)
            debugLog("autoStopTask fired")
            self?.stopRecording(reason: "Recording reached 30 minutes and stopped automatically. We’re processing it into Eggbook. Check back later.")
        }
    }

    private func startSharedPoll() {
        sharedPollTask?.cancel()
        sharedPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await MainActor.run {
                    self?.pollSharedBroadcastState()
                }
            }
        }
    }

    private func pollSharedBroadcastState() {
        let defaults = UserDefaults(suiteName: appGroupId)
        let status = defaults?.string(forKey: statusKey)
        if let status, status != lastSeenStatus {
            lastSeenStatus = status
            handleSharedStatus(status)
        }
        logUploadTraceIfChanged()
        consumePendingBroadcastUploads()
    }

    private func logUploadTraceIfChanged() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        let phase = defaults.string(forKey: lastUploadPhaseKey) ?? "unknown"
        let eventId = defaults.string(forKey: lastEventIdKey) ?? "nil"
        let error = defaults.string(forKey: lastUploadErrorKey) ?? ""
        let updatedAt = defaults.double(forKey: lastUploadUpdatedAtKey)
        guard updatedAt > 0 else { return }

        let fingerprint = "\(updatedAt)-\(phase)-\(eventId)-\(error)"
        guard fingerprint != lastUploadTraceFingerprint else { return }
        lastUploadTraceFingerprint = fingerprint

        let errorText = error.isEmpty ? "none" : error
        debugLog("broadcast upload trace phase=\(phase) eventId=\(eventId) error=\(errorText)")
        if eventId != "nil" {
            print("broadcast latest eventId:", eventId, "phase:", phase)
        }
    }

    private func handleSharedStatus(_ status: String) {
        debugLog("broadcast shared status -> \(status)")
        switch status {
        case "recording":
            cancelUploadingFallback()
            if state != .recording {
                state = .recording
                permissionMessage = "Screen recording is active."
                showsSettingsButton = false
                onRecordingStarted?()
            }
        case "uploading":
            state = .processing
            permissionMessage = "Uploading recording..."
            showsSettingsButton = false
            scheduleUploadingFallback()
        case "finished":
            cancelUploadingFallback()
            if state == .recording {
                state = .processing
                permissionMessage = "Recording ended. We’re processing it into Eggbook. Check back later."
                onRecordingStopped?()
            }
        case "uploaded":
            cancelUploadingFallback()
            state = .idle
            permissionMessage = "Recording uploaded. Processing into Eggbook."
            showsSettingsButton = false
            scheduleBannerClear(
                expectedMessage: "Recording uploaded. Processing into Eggbook.",
                afterNanoseconds: 3_000_000_000
            )
        case "pending_upload":
            cancelUploadingFallback()
            // Upload can be retried from app side; keep recording control usable.
            state = .idle
            permissionMessage = "Upload pending. Open Eggtart later to retry upload."
            showsSettingsButton = false
        default:
            break
        }
    }

    private func cancelUploadingFallback() {
        uploadingFallbackTask?.cancel()
        uploadingFallbackTask = nil
    }

    private func scheduleUploadingFallback() {
        uploadingFallbackTask?.cancel()
        uploadingFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self else { return }
            guard self.permissionMessage == "Uploading recording..." else { return }
            let defaults = UserDefaults(suiteName: self.appGroupId)
            let pendingCount = (defaults?.array(forKey: self.pendingUploadsKey) as? [[String: Any]])?.count ?? 0
            let status = defaults?.string(forKey: self.statusKey) ?? "nil"
            debugLog("uploading banner fallback fired; clearing stale uploading state pending=\(pendingCount) sharedStatus=\(status)")
            self.consumePendingBroadcastUploads(force: true)
            self.permissionMessage = "Recording ended. We’re processing it into Eggbook. Check back later."
            self.state = .idle
            self.showsSettingsButton = false
            self.onProcessingFallback?()
            self.scheduleBannerClear(
                expectedMessage: "Recording ended. We’re processing it into Eggbook. Check back later.",
                afterNanoseconds: 5_000_000_000
            )
        }
    }

    private func scheduleBannerClear(expectedMessage: String, afterNanoseconds: UInt64) {
        bannerAutoClearTask?.cancel()
        bannerAutoClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: afterNanoseconds)
            guard let self else { return }
            if self.permissionMessage == expectedMessage {
                self.permissionMessage = nil
            }
        }
    }

    private func consumePendingBroadcastUploads(force: Bool = false) {
        let defaults = UserDefaults(suiteName: appGroupId)
        guard let queue = defaults?.array(forKey: pendingUploadsKey) as? [[String: Any]], !queue.isEmpty else { return }
        if !force {
            let status = defaults?.string(forKey: statusKey)
            let lastUploadUpdatedAt = defaults?.double(forKey: lastUploadUpdatedAtKey) ?? 0
            let hasFreshUploadingSignal = status == "uploading" &&
                lastUploadUpdatedAt > 0 &&
                (Date().timeIntervalSince1970 - lastUploadUpdatedAt) < 60
            if hasFreshUploadingSignal {
                return
            }
        }

        var consumed: [BroadcastUploadItem] = []
        var remaining: [[String: Any]] = []
        var dropped = 0
        for item in queue {
            guard let id = item["id"] as? String,
                  let screenPath = item["screenPath"] as? String else {
                dropped += 1
                debugLog("drop invalid pending upload item: missing id/screenPath")
                continue
            }
            let endedAt = item["endedAt"] as? TimeInterval ?? 0
            if appEntryCutoffEpoch > 0, endedAt > 0, endedAt < appEntryCutoffEpoch {
                dropped += 1
                debugLog("drop stale pending upload id=\(id) endedAt=\(Int(endedAt)) before appEntryCutoff=\(Int(appEntryCutoffEpoch))")
                continue
            }
            let screenURL = URL(fileURLWithPath: screenPath)
            if !FileManager.default.fileExists(atPath: screenURL.path) {
                dropped += 1
                debugLog("drop stale pending upload id=\(id) missingScreen=\(screenPath)")
                continue
            }
            let screenSize = (try? screenURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if screenSize <= 0 {
                dropped += 1
                debugLog("drop stale pending upload id=\(id) emptyScreenFile=\(screenPath)")
                continue
            }
            let audioURL: URL?
            if let audioPath = item["audioPath"] as? String, FileManager.default.fileExists(atPath: audioPath) {
                audioURL = URL(fileURLWithPath: audioPath)
            } else {
                audioURL = nil
            }
            let duration = item["durationSec"] as? Int ?? 1
            let reason = item["reason"] as? String ?? "manual_or_system_stop"
            consumed.append(BroadcastUploadItem(id: id, screenURL: screenURL, audioURL: audioURL, durationSec: max(1, duration), reason: reason))
        }

        for item in queue {
            guard let id = item["id"] as? String else { continue }
            if consumed.contains(where: { $0.id == id }) {
                continue
            }
            if let screenPath = item["screenPath"] as? String {
                let screenURL = URL(fileURLWithPath: screenPath)
                if !FileManager.default.fileExists(atPath: screenURL.path) {
                    continue
                }
            }
            remaining.append(item)
        }

        defaults?.set(remaining, forKey: pendingUploadsKey)
        defaults?.synchronize()
        if dropped > 0 {
            debugLog("pending upload cleanup dropped=\(dropped) remaining=\(remaining.count)")
        }

        for item in consumed {
            debugLog("consume pending broadcast upload id=\(item.id) duration=\(item.durationSec)")
            permissionMessage = "Recording ended. We’re processing it into Eggbook. Check back later."
            state = .processing
            onRecordingFinished?(item.durationSec)
            onBroadcastFilesReady?(item)
        }

        if !consumed.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                self?.state = .idle
                if self?.permissionMessage == "Recording ended. We’re processing it into Eggbook. Check back later." {
                    self?.permissionMessage = nil
                }
            }
        }
    }
}
