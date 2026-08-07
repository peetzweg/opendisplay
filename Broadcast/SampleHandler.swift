// The broadcast upload extension's entry point (issue #123). iOS runs this in
// its own ~50MB process while the red recording indicator is up; ReplayKit
// delivers the whole screen here regardless of which app is frontmost — the
// only sanctioned way to capture beyond your own app on iOS.

import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {

    private var sender: BroadcastSender?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let target = BroadcastTarget.serviceName, !target.isEmpty else {
            // No target chosen (broadcast started straight from Control
            // Center before ever opening the app's send screen).
            finish("Open OpenDisplay and choose a device to send to first.")
            return
        }
        Log.info("broadcast started -> \(target)")
        let sender = BroadcastSender(targetService: target)
        sender.onFatal = { [weak self] message in self?.finish(message) }
        self.sender = sender
        sender.start()
    }

    override func broadcastPaused() {
        Log.info("broadcast paused")
        sender?.setPaused(true)
    }

    override func broadcastResumed() {
        Log.info("broadcast resumed")
        sender?.setPaused(false)
    }

    override func broadcastFinished() {
        Log.info("broadcast finished")
        sender?.stop()
        sender = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }   // no audio on this wire
        sender?.process(sampleBuffer)
    }

    /// End the broadcast with a message the system surfaces in its alert —
    /// the only user-visible channel an upload extension has.
    private func finish(_ message: String) {
        Log.info("finishing broadcast: \(message)")
        finishBroadcastWithError(NSError(
            domain: "OpenDisplay", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
