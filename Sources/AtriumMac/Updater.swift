import AppKit
import AtriumCore
import Sparkle

/// Keeping an installed copy current.
///
/// Apple offers no auto-update mechanism for apps outside the App Store,
/// and this one can never ship there: the App Store requires sandboxing,
/// and a sandboxed process cannot create a CoreAudio process tap at all.
/// So updates are Sparkle's, served from a signed appcast.
///
/// ## The signature is what makes this safe, not the host
///
/// Sparkle's design assumes the server is hostile. Each update is signed
/// with an EdDSA key that lives in the login Keychain and never leaves
/// this Mac, and verified against `SUPublicEDKey` compiled into the app.
/// A compromised CDN — or a compromised GitHub account, which is the
/// case actually worth defending against — can serve whatever it likes
/// and the update is refused. That is why this key is separate from the
/// Developer ID: reusing it would put its private half wherever releases
/// are built, collapsing two failure modes into one.
///
/// ## Why this app cannot just relaunch
///
/// Sparkle installs an update by quitting and reopening the app. For
/// almost any other program that is a blink. Here it can destroy the
/// thing the program exists for.
final class Updater: NSObject, SPUUpdaterDelegate {

    private var controller: SPUStandardUpdaterController?

    /// Asked before relaunching. Returning `false` postpones.
    var isBusy: (() -> (busy: Bool, why: String))?

    func start() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        Log.write(
            "updates: checking \(controller?.updater.feedURL?.absoluteString ?? "no feed")"
                + " every \(Int(controller?.updater.updateCheckInterval ?? 0))s")
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    // MARK: - SPUUpdaterDelegate

    /// Never interrupt a recording, and never abandon a pending upload.
    ///
    /// A meeting this app fails to record cannot be recovered, and a
    /// failed upload's `.m4a` is the only copy of that conversation
    /// anywhere once Atrium PA sweeps its vault. An update can always
    /// wait; neither of those can.
    ///
    /// Sparkle re-asks rather than giving up, so postponing here means
    /// "later", not "never" — the update installs on the next check once
    /// the machine is idle.
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let state = isBusy?(), state.busy else { return false }
        Log.write("updates: postponing \(item.displayVersionString) — \(state.why)")
        // Held, not dropped. Sparkle hands over the install and waits;
        // `pendingInstall` runs it once the machine is quiet, so a
        // postponement is "after this meeting" rather than "never".
        pendingInstall = installHandler
        schedulePendingInstallCheck()
        return true
    }

    /// The install Sparkle handed over while a recording was running.
    private var pendingInstall: (() -> Void)?
    private var pendingTimer: Timer?

    /// Ask again every minute until it is safe, then install.
    ///
    /// A postponed update with nothing watching for the moment to resume
    /// is a postponement that lasts until the next launch — which for an
    /// app that starts at login and runs for weeks is indistinguishable
    /// from never updating at all.
    private func schedulePendingInstallCheck() {
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self] timer in
            guard let self, let install = self.pendingInstall else {
                timer.invalidate()
                return
            }
            guard let state = self.isBusy?(), state.busy else {
                timer.invalidate()
                self.pendingTimer = nil
                self.pendingInstall = nil
                Log.write("updates: no longer busy — installing the held update")
                install()
                return
            }
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Written synchronously, like everything in `Log`, because this
        // is the last moment before the process goes away — and "it
        // updated itself overnight" is otherwise indistinguishable from
        // "it crashed" when somebody reads the log the next morning.
        Log.write("updates: relaunching to install")
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Log.write("updates: feed has \(appcast.items.count) release(s)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Not an alert. A feed that cannot be reached is a normal
        // condition on a laptop, and a recorder that interrupts a
        // meeting to say so is worse than one that is a version behind.
        Log.write("updates: check failed — \(error.localizedDescription)")
    }
}
