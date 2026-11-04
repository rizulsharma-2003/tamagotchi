import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import TamagotchiCore

/// What Mochi can do on the Mac. Only public APIs: Launch Services for apps and links, the
/// Accessibility API to pick a window (when the user allowed it), media-key events, Core Audio
/// for the volume and the `shortcuts` command for the user's own automations. Window titles are
/// matched here and never leave the Mac.
@MainActor
enum MacActions {
    struct Outcome {
        var text: String
        var ok = true
        /// Another app came to the front, so the Ask Mochi panel can get out of the way.
        var movedFocus = false
    }

    // MARK: Apps

    private static var installedCache: (at: Date, apps: [String: URL])?

    /// Installed apps by name, from the usual folders (cached briefly).
    static func installedApps() -> [String: URL] {
        if let cache = installedCache, Date().timeIntervalSince(cache.at) < 60 { return cache.apps }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var apps: [String: URL] = [:]
        for folder in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       "\(home)/Applications", "\(home)/Applications/Chrome Apps.localized"] {
            for item in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                if apps[name] == nil { apps[name] = URL(fileURLWithPath: folder).appendingPathComponent(item) }
            }
        }
        installedCache = (Date(), apps)
        return apps
    }

    /// Apps with a Dock presence, frontmost first is not guaranteed.
    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func runningApp(named name: String) -> NSRunningApplication? {
        let apps = runningApps()
        guard let match = QuickCommands.matchApp(QuickCommands.normalize(name), in: apps.compactMap(\.localizedName)) else { return nil }
        return apps.first { $0.localizedName == match }
    }

    static func openApp(named name: String) -> Outcome {
        if let app = runningApp(named: name) {
            bringForward(app)
            return Outcome(text: "Switched to \(app.localizedName ?? name).", movedFocus: true)
        }
        let installed = installedApps()
        guard let match = QuickCommands.matchApp(QuickCommands.normalize(name), in: Array(installed.keys)), let url = installed[match] else {
            return Outcome(text: "I couldn't find an app called “\(name)”.", ok: false)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return Outcome(text: "Opening \(match).", movedFocus: true)
    }

    /// Hands the focus to another app (macOS 14 cooperative activation), with Launch Services
    /// as a fallback when the system declines.
    static func bringForward(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !app.isActive, let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    // MARK: Links

    static func openURL(_ text: String) -> Outcome {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else {
            return Outcome(text: "That doesn't look like a web link.", ok: false)
        }
        guard NSWorkspace.shared.open(url) else { return Outcome(text: "The link didn't open.", ok: false) }
        return Outcome(text: "Opened \(url.host() ?? "the page").", movedFocus: true)
    }

    // MARK: Windows

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) and opens the Accessibility pane.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Brings forward the window whose title best matches `title`, in `app` if given.
    static func focusWindow(app name: String?, title: String?) -> Outcome {
        let app = name.flatMap(runningApp(named:))
        if name != nil, app == nil, title == nil { return openApp(named: name!) }
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            guard let app else { return Outcome(text: "Which window should I look for?", ok: false) }
            bringForward(app)
            return Outcome(text: "Switched to \(app.localizedName ?? "the app").", movedFocus: true)
        }
        guard accessibilityTrusted else {
            if let app {
                bringForward(app)
                return Outcome(text: "Switched to \(app.localizedName ?? "the app") (allow Accessibility so I can pick the exact window).",
                               movedFocus: true)
            }
            return Outcome(text: "I need Accessibility permission to find windows — it's in Settings › Assistant.", ok: false)
        }
        let candidates = app.map { [$0] } ?? runningApps()
        guard let found = bestWindow(matching: title, in: candidates) else {
            if let app {
                bringForward(app)
                return Outcome(text: "Switched to \(app.localizedName ?? "the app"), but no window matched “\(title)”.", movedFocus: true)
            }
            return Outcome(text: "I couldn't find a window matching “\(title)”.", ok: false)
        }
        raise(found.window, of: found.app)
        return Outcome(text: "Here's \(found.app.localizedName ?? "the window").", movedFocus: true)
    }

    private static func bestWindow(matching query: String, in apps: [NSRunningApplication]) -> (app: NSRunningApplication, window: AXUIElement)? {
        let wanted = tokens(query)
        guard !wanted.isEmpty else { return nil }
        var best: (NSRunningApplication, AXUIElement, Int)?
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                var titleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                guard let title = titleValue as? String, !title.isEmpty else { continue }
                let have = tokens(title)
                let squashed = have.joined()
                let score = wanted.filter { token in have.contains(token) || squashed.contains(token) }.count
                if score == wanted.count || (wanted.count >= 3 && score >= wanted.count - 1), score > (best?.2 ?? 0) {
                    best = (app, window, score)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        bringForward(app)
    }

    private static func tokens(_ text: String) -> [String] {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.filter { !["the", "my", "window", "app", "a"].contains($0) }
    }

    /// Editors that bring an already-open folder's window forward when asked to open it.
    private static let folderEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]

    /// Shows the window a Claude session works in: the project folder in its editor, or the
    /// terminal or app it runs in.
    static func showProject(_ project: ProjectRef, host: String?) -> Outcome {
        let name = project.displayName
        if let host, let path = project.path, folderEditors.contains(host) || host.hasPrefix("com.jetbrains."),
           let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
                NSApp.yieldActivation(to: running)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: editor, configuration: configuration)
            return Outcome(text: "Here's \(name).", movedFocus: true)
        }
        let hostApp = host.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        if accessibilityTrusted, let found = bestWindow(matching: name, in: hostApp.map { [$0] } ?? runningApps()) {
            raise(found.window, of: found.app)
            return Outcome(text: "Here's \(name).", movedFocus: true)
        }
        if let hostApp {
            bringForward(hostApp)
            return Outcome(text: "Switched to \(hostApp.localizedName ?? "its app").", movedFocus: true)
        }
        return Outcome(text: "I couldn't tell which window \(name) is in.", ok: false)
    }

    // MARK: Media and volume

    static func media(_ key: MediaKey) -> Outcome {
        guard accessibilityTrusted else {
            return Outcome(text: "I need Accessibility permission to press music keys — it's in Settings › Assistant.", ok: false)
        }
        let code: Int
        switch key {
        case .playPause: code = 16   // NX_KEYTYPE_PLAY
        case .next: code = 17        // NX_KEYTYPE_NEXT
        case .previous: code = 18    // NX_KEYTYPE_PREVIOUS
        }
        postSystemKey(code)
        switch key {
        case .playPause: return Outcome(text: "Pressed play/pause.")
        case .next: return Outcome(text: "Skipped ahead.")
        case .previous: return Outcome(text: "Went back a track.")
        }
    }

    private static func postSystemKey(_ code: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func volume(_ change: VolumeChange) -> Outcome {
        guard let device = defaultOutputDevice() else { return Outcome(text: "I couldn't find the sound output.", ok: false) }
        switch change {
        case .mute:
            return setMute(device, true) ? Outcome(text: "Muted.") : Outcome(text: "This output can't be muted.", ok: false)
        case .unmute:
            return setMute(device, false) ? Outcome(text: "Sound's back on.") : Outcome(text: "This output can't be unmuted.", ok: false)
        case .up, .down, .set:
            guard let current = mainVolume(device) else { return Outcome(text: "This output's volume can't be changed.", ok: false) }
            let target: Float32
            switch change {
            case .up: target = min(1, current + 0.1)
            case .down: target = max(0, current - 0.1)
            case .set(let level): target = Float32(max(0, min(100, level))) / 100
            default: target = current
            }
            if target > 0 { _ = setMute(device, false) }
            guard setMainVolume(device, target) else { return Outcome(text: "This output's volume can't be changed.", ok: false) }
            return Outcome(text: "Volume \(Int((target * 100).rounded()))%.")
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func volumeAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func mainVolume(_ device: AudioDeviceID) -> Float32? {
        var address = volumeAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setMainVolume(_ device: AudioDeviceID, _ value: Float32) -> Bool {
        var address = volumeAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var newValue = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue) == noErr
    }

    private static func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = volumeAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: Shortcuts

    static func runShortcut(_ name: String) async -> Outcome {
        let result = await runTool("/usr/bin/shortcuts", ["run", name], timeout: 120)
        if result.status == 0 { return Outcome(text: "Ran “\(name)”.") }
        return Outcome(text: "The shortcut “\(name)” didn't run\(result.timedOut ? " in time" : "").", ok: false)
    }

    static func shortcutNames() async -> [String] {
        let result = await runTool("/usr/bin/shortcuts", ["list"], timeout: 15)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, output: String, timedOut: Bool) {
        await Task.detached(priority: .userInitiated) { runToolBlocking(path, arguments, timeout: timeout) }.value
    }

    private nonisolated static func runToolBlocking(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String, timedOut: Bool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, "", false) }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                return (-1, "", true)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data.prefix(64 * 1024), as: UTF8.self), false)
    }
}
