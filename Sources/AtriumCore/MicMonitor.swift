import CoreAudio
import Foundation

/// A process that has started or stopped capturing microphone input.
public struct MicEvent {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let executable: String
    public let capturing: Bool

    public init(
        objectID: AudioObjectID, pid: pid_t, bundleID: String?, executable: String,
        capturing: Bool
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.executable = executable
        self.capturing = capturing
    }

    public var label: String {
        if let bundleID { return "\(executable) [\(bundleID)] pid=\(pid)" }
        return "\(executable) pid=\(pid)"
    }
}

/// Watches every audio process for microphone acquire / release.
///
/// This needs **no TCC permission at all** — it observes the same state
/// that drives the orange dot in the menu bar. Only *capturing* audio is
/// gated; observing who is capturing is not.
///
/// Implementation is push *and* poll. A listener on the process-object
/// list catches new processes, a per-process listener on
/// `kAudioProcessPropertyIsRunningInput` catches the acquire/release
/// edge — and a slow timer reconciles what we believe against what is
/// true, because a notification that never arrives leaves no trace and
/// this app has already lost a meeting to exactly that.
public final class MicMonitor {

    public init() {}

    private let queue = DispatchQueue(label: "com.atrium-mac.mic-monitor")
    private var lastKnown: [AudioObjectID: Bool] = [:]
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var reconciler: DispatchSourceTimer?
    private var isRecording = false

    /// How often to check the world against what we believe about it.
    ///
    /// **This is the mechanism, not the backstop.** It was written as a
    /// backstop at 30 seconds, on the assumption that the per-process
    /// listeners did the work and answered in milliseconds. Measured on
    /// macOS 26.5, over a whole session's log: listener-delivered mic
    /// events, **zero**. Every acquire and release — WhatsApp starting a
    /// call, this app's own capture, corespeechd — arrived here. So the
    /// interval *is* the detection latency, and a WhatsApp call took up
    /// to half a minute to start recording.
    ///
    /// The listeners are still installed. They cost nothing while they
    /// do not fire, and if a later macOS starts delivering them the
    /// "found by reconciliation" line will simply stop appearing.
    ///
    /// ## Why two intervals
    ///
    /// A pass is not free: measured at **58 ms for 46 audio processes**,
    /// essentially all of it the per-process property read — listing
    /// them costs 0.0 ms. Polling every three seconds all day is ~2% of
    /// a core on a laptop that is mostly asleep.
    ///
    /// It only buys something while we are *waiting* for a meeting.
    /// Once one is running, the event being waited for is the release,
    /// and a late release costs nothing at all: `SessionPolicy` debounces
    /// the end by 45 seconds anyway.
    ///
    /// These are back to backstop intervals — 10 s and 30 s — because
    /// `watchInputDevice()` restored an instant edge that works:
    /// measured, the device said "in use" **166 ms** after capture
    /// began, where the poll would have taken up to its full interval.
    /// The poll now catches only what a device-level edge cannot see,
    /// which is a process starting or stopping while the device is
    /// already running for somebody else.
    public var reconcileInterval: TimeInterval = 10

    /// Used instead while a recording is running. See above: the cost is
    /// the same, and the benefit is not.
    public var reconcileIntervalWhileRecording: TimeInterval = 30

    /// Called on the monitor's private queue for every acquire/release.
    public var onEvent: ((MicEvent) -> Void)?

    public func start() {
        queue.sync { scan(.launch) }
        watchProcessList()
        watchInputDevice()
        watchDefaultInputDeviceChanges()
        startReconciling()
    }

    /// Slow the poll down while a recording is running, and speed it up
    /// again when one is not.
    public func setRecording(_ recording: Bool) {
        queue.async {
            guard self.isRecording != recording else { return }
            self.isRecording = recording
            self.startReconciling()
        }
    }

    public func stop() {
        reconciler?.cancel()
        reconciler = nil
        queue.sync {
            for (object, block) in listeners {
                var addr = CA.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
            }
            listeners.removeAll()
            lastKnown.removeAll()

            if let listListener {
                var addr = CA.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &addr, queue, listListener)
                self.listListener = nil
            }
        }
    }

    /// Processes currently holding the mic. Useful for the menu-bar UI.
    public func currentlyCapturing() -> [MicEvent] {
        queue.sync {
            CA.processObjectIDs()
                .filter { CA.isRunningInput($0) }
                .map { event(for: $0, capturing: true) }
        }
    }

    // MARK: - Private

    private func event(for object: AudioObjectID, capturing: Bool) -> MicEvent {
        let pid = CA.pid(object) ?? -1
        return MicEvent(
            objectID: object,
            pid: pid,
            bundleID: CA.bundleID(object),
            executable: pid > 0 ? CA.executableName(pid: pid) : "?",
            capturing: capturing
        )
    }

    /// Passes so far, so the one that gets measured is representative.
    private var scanCount = 0

    /// Why this pass is happening, so the log says which mechanism
    /// noticed a change rather than crediting them all to the poll.
    private enum Trigger: String {
        case launch = "at launch"
        case poll = "by the poll"
        case device = "when the input device started or stopped"
        case processList = "when the audio process list changed"
    }

    private func scan(_ trigger: Trigger = .poll) {
        let started = DispatchTime.now()
        let ids = Set(CA.processObjectIDs())
        let listed = DispatchTime.now()

        for object in ids where listeners[object] == nil {
            let capturing = CA.isRunningInput(object)
            lastKnown[object] = capturing
            attachListener(to: object)

            // Emit for *any* newly discovered process that is already
            // capturing, whether that is at launch or mid-run.
            //
            // This used to be suppressed mid-run, on the reasoning that
            // a process object appearing while we watch must have
            // appeared because it started audio, so its listener would
            // report it. That is wrong, and it cost a Teams meeting.
            // The listener fires on *changes*, and the line above has
            // just recorded the current state as `lastKnown`, so a
            // process that arrives already capturing matches its own
            // stored state and never fires at all.
            //
            // Teams is precisely this case: joining a meeting spawns a
            // fresh WebView helper that is holding the microphone by the
            // time its process object exists. The orange dot came on and
            // nothing recorded.
            if capturing {
                Log.write("mic: \(event(for: object, capturing: true).label) appeared capturing")
                onEvent?(event(for: object, capturing: true))
            }
        }

        for (object, block) in listeners where !ids.contains(object) {
            var addr = CA.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
            if lastKnown[object] == true {
                // Logged like every other emission. This one was silent,
                // which made a release of unknown provenance impossible
                // to tell from a bug — and provenance is the only thing
                // that showed the listeners were dead.
                let gone = event(for: object, capturing: false)
                Log.write("mic: \(gone.label) released — its audio process ended")
                onEvent?(gone)
            }
            listeners[object] = nil
            lastKnown[object] = nil
        }

        reconcile(ids, trigger)

        // The *second* pass, not the first: the first attaches a
        // listener to every audio process on the machine and is not
        // representative of the one that repeats. This runs every few
        // seconds now, so "is that expensive?" is a fair question and
        // deserves a number rather than a reassurance.
        scanCount += 1
        if scanCount == 2 {
            func ms(_ from: DispatchTime, _ to: DispatchTime) -> Double {
                Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000
            }
            let now = DispatchTime.now()
            Log.write(
                String(
                    format: "mic: reconcile pass over %d processes — %.1f ms "
                        + "listing, %.1f ms checking, %.1f ms total; "
                        + "%d listener(s) attached, %d refused",
                    ids.count, ms(started, listed), ms(listed, now), ms(started, now),
                    listeners.count, attachFailures))
        }
    }

    /// Compare belief against fact for every process already watched.
    ///
    /// The two loops above handle a process arriving and a process
    /// going away. Neither covers the third case: a process we are
    /// already watching flips its flag and the listener does not fire —
    /// or fires while we are not there to hear it. Nothing else would
    /// ever notice, because `lastKnown` and the listener agree with each
    /// other while both disagree with the machine.
    ///
    /// That is not hypothetical. Missing an *acquire* is how a Teams
    /// meeting went unrecorded with the orange dot lit; missing a
    /// *release* leaves a session running against a call that ended,
    /// and nothing arrives later to end it, because the edge has already
    /// been and gone.
    private func reconcile(_ ids: Set<AudioObjectID>, _ trigger: Trigger) {
        for object in ids where listeners[object] != nil {
            let actual = CA.isRunningInput(object)
            guard actual != (lastKnown[object] ?? false) else { continue }
            lastKnown[object] = actual
            let event = event(for: object, capturing: actual)
            // Logged distinctly from the listener's own line. If these
            // start appearing regularly, the listeners are unreliable on
            // this machine and that is worth knowing rather than
            // silently papering over.
            Log.write(
                "mic: \(event.label) \(actual ? "acquired" : "released") "
                    + "— noticed \(trigger.rawValue)")
            onEvent?(event)
        }
    }

    private func startReconciling() {
        reconciler?.cancel()
        let interval =
            isRecording ? reconcileIntervalWhileRecording : reconcileInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this is a poll, not a deadline, and letting
        // the system coalesce it with other timers is most of what keeps
        // it cheap on battery.
        timer.schedule(
            deadline: .now() + interval, repeating: interval,
            leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        reconciler = timer
    }

    /// Attaches attempted and refused, so "the listeners never fire" can
    /// be told apart from "the listeners were never installed".
    private var attachFailures = 0
    private var attachAttempts = 0

    private func attachListener(to object: AudioObjectID) {
        var addr = CA.address(kAudioProcessPropertyIsRunningInput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let now = CA.isRunningInput(object)
            // Logged even when nothing changed. A listener that fires
            // and finds no change is a *working* listener, and telling
            // that apart from one that never fires is the whole
            // question.
            guard now != (self.lastKnown[object] ?? false) else {
                Log.write(
                    "mic: listener fired for object \(object) with no change")
                return
            }
            self.lastKnown[object] = now
            let event = self.event(for: object, capturing: now)
            Log.write("mic: \(event.label) \(now ? "acquired" : "released")")
            self.onEvent?(event)
        }

        attachAttempts += 1
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        if status == noErr {
            listeners[object] = block
        } else {
            // Silently skipped once. An object with no listener is also
            // never reconciled — `reconcile()` only walks watched
            // objects — so a failure here is a process that can never be
            // detected at all, and it left no trace.
            attachFailures += 1
            Log.write(
                "mic: could not watch object \(object) — OSStatus \(status)")
        }
    }

    /// Watch the input *device* for "somebody started using me".
    ///
    /// The per-process listeners do not fire on macOS 26.5 — measured,
    /// 46 attached, 0 refused, never once invoked — which leaves the
    /// poll as the only detector and its interval as the latency.
    ///
    /// This is a second chance at an edge. `kAudioDevicePropertyDevice-
    /// IsRunningSomewhere` says only that *something* has started or
    /// stopped using the input device, with no idea who; that is useless
    /// on its own but it is exactly the moment a scan is worth doing. So
    /// the device answers "when" and the scan answers "who".
    ///
    /// If this listener is as dead as the per-process ones, nothing is
    /// lost: the poll still runs, and the log says which of them noticed.
    /// The device currently being watched, so it can be let go when the
    /// default changes.
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)

    /// Re-attach when the default input device changes.
    ///
    /// Connecting AirPods mid-day makes a different device the default,
    /// and a listener on the old one hears nothing about the new one.
    /// Without this the instant edge would work until the first time
    /// somebody put headphones on, and then quietly stop.
    private func watchDefaultInputDeviceChanges() {
        var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Log.write("mic: the default input device changed — re-attaching")
            self.watchInputDevice()
            // The new device may already be in use.
            self.scan(.device)
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr
        {
            defaultDeviceListener = block
        }
    }

    private func watchInputDevice() {
        // Let the previous one go, or a device swap leaves a listener
        // behind on a device nobody is using.
        if watchedDevice != kAudioObjectUnknown, let deviceListener {
            var old = CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(
                watchedDevice, &old, queue, deviceListener)
            self.deviceListener = nil
            watchedDevice = AudioObjectID(kAudioObjectUnknown)
        }

        var deviceAddr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &deviceAddr, 0, nil, &size,
                &device) == noErr, device != kAudioObjectUnknown
        else {
            Log.write("mic: no default input device to watch")
            return
        }

        var addr = CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.scan(.device)
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &addr, queue, block)
        if status == noErr {
            deviceListener = block
            watchedDevice = device
            Log.write("mic: watching input device \(device) for use")
        } else {
            Log.write("mic: could not watch the input device — OSStatus \(status)")
        }
    }

    private func watchProcessList() {
        var addr = CA.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scan(.processList)
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr
        {
            listListener = block
        }
    }
}
