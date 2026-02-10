import ReplayKit
import Foundation

final class SampleHandler: RPBroadcastSampleHandler {
    private let appGroupId = "group.eggtart.screenrecord"
    private let statusKey = "broadcast.status"
    private let startedAtKey = "broadcast.startedAt"
    private let stoppedAtKey = "broadcast.stoppedAt"

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        updateStatus("recording")
        UserDefaults(suiteName: appGroupId)?.set(Date().timeIntervalSince1970, forKey: startedAtKey)
        UserDefaults(suiteName: appGroupId)?.synchronize()

        // TODO:
        // 1) Initialize AVAssetWriter for screen video (CMSampleBuffer from .video).
        // 2) Optionally initialize audio writer input for app/mic audio.
        // 3) Persist output file URL to shared App Group container.
    }

    override func broadcastPaused() {
        updateStatus("paused")
    }

    override func broadcastResumed() {
        updateStatus("recording")
    }

    override func broadcastFinished() {
        updateStatus("finished")
        UserDefaults(suiteName: appGroupId)?.set(Date().timeIntervalSince1970, forKey: stoppedAtKey)
        UserDefaults(suiteName: appGroupId)?.synchronize()

        // TODO:
        // 1) Finish AVAssetWriter.
        // 2) Move output files into App Group shared container.
        // 3) Notify host app (UserDefaults flag / Darwin notification / shared file marker).
        // 4) Host app uploads audio_url + screen_recording_url, then PATCH /v1/events/{id}.
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // TODO: append video sampleBuffer to writer input
            break
        case .audioApp:
            // TODO: append app audio sampleBuffer if needed
            break
        case .audioMic:
            // TODO: append mic sampleBuffer if needed (can be optional)
            break
        @unknown default:
            break
        }
    }

    private func updateStatus(_ status: String) {
        UserDefaults(suiteName: appGroupId)?.set(status, forKey: statusKey)
        UserDefaults(suiteName: appGroupId)?.synchronize()
    }
}
