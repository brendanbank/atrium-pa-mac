import AppKit

/// Get back to the main thread in a way a modal session will run.
///
/// `MainActor.run` and `DispatchQueue.main.async` are delivered when the
/// main run loop is in its default mode. `NSApp.runModal` puts it in
/// `NSModalPanelRunLoopMode` instead, and libdispatch's main queue is
/// **not** drained there — so a block hopped that way from inside a
/// `Task` simply never runs until the modal session ends.
///
/// Measured: the naming window went application-modal and every row sat
/// on "Looking…" with its spinner turning. The requests had completed;
/// their callbacks were queued behind a run loop that was not going to
/// look at them. Nothing errored, which is what made it look like a
/// network problem rather than a run-loop mode.
///
/// `RunLoop.perform(inModes:)` names the modes explicitly, so the block
/// runs whether or not something modal is up.
func onMainThread(_ work: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking], block: work)
}
