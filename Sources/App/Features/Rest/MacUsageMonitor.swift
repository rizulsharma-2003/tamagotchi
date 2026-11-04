import AppKit
import Darwin
import IOKit.pwr_mgt
import TamagotchiCore

/// Samples how the Mac is used every few seconds, so Mochi sleeps while it rests and is awake while
/// you work: the time since the last input (never the input itself), display and system sleep,
/// whether something keeps the screen on, and processor load. Nothing is stored or sent.
@MainActor
final class MacUsageMonitor {
    private var timer: Timer?
    private var displaysAsleep = false
    private var cpu = CPULoadSampler()
    private var load = 0.0
    private var onUpdate: ((SystemActivity) -> Void)?

    func start(_ onUpdate: @escaping (SystemActivity) -> Void) {
        self.onUpdate = onUpdate
        let center = NSWorkspace.shared.notificationCenter
        // Displays or the Mac asleep, or another user switched in: nobody is here.
        let asleep: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                                           NSWorkspace.sessionDidResignActiveNotification]
        let awake: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification]
        for (names, value) in [(asleep, true), (awake, false)] {
            for name in names {
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.displaysAsleep = value
                        self?.sample()
                    }
                }
            }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    private func sample() {
        // About a minute of smoothing at one sample every 5 seconds.
        if let instant = cpu.sample() { load += (instant - load) * 0.08 }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
        onUpdate?(SystemActivity(idleSeconds: idle, displaysAsleep: displaysAsleep,
                                 keepsDisplayAwake: Self.screenHeldOn(), cpuLoad: load))
    }

    /// A video, a call or a presentation is keeping the screen on (a public power assertion).
    static func screenHeldOn() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let assertions = status?.takeRetainedValue() as? [String: Any] else { return false }
        return ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains { (assertions[$0] as? Int ?? 0) > 0 }
    }
}

/// Whole-Mac processor load between samples, from the kernel's tick counters.
struct CPULoadSampler {
    private let host = mach_host_self()
    private var previous: (busy: UInt64, total: UInt64)?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let total = busy + UInt64(ticks.2)
        defer { previous = (busy, total) }
        guard let previous, total > previous.total, busy >= previous.busy else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }
}
