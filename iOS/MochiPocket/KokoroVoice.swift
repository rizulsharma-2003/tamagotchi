import FluidAudio
import Foundation
import Observation

/// Mochi's natural voice: Kokoro, an open-source speech model, running on this iPhone's Neural Engine through
/// FluidAudio (the Core ML route that needs no GPU, so it also works when Siri runs Mochi in the background). It
/// downloads once from Hugging Face (about 98 MB) when you turn it on; after that every word is spoken on the phone
/// and nothing is sent anywhere. When Kokoro can't speak (not downloaded, still loading, or it fails), the reader
/// falls back to the iPhone voice.
@MainActor
@Observable
final class KokoroVoice {
    static let shared = KokoroVoice()

    /// One of Mochi's natural voices: a Kokoro voice, or several mixed by weight, with pitch and pace on top.
    struct Style: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let blurb: String
        /// Kokoro voice packs and how much of each.
        let parts: [Part]
        /// Pitch change in cents (100 is a semitone).
        let cents: Float
        let speed: Float

        struct Part: Equatable, Sendable {
            let voice: String
            let weight: Float
        }

        /// The voice pack Kokoro speaks with: a Kokoro voice as it is, or a blend saved as `mochi<id>.bin`.
        var voice: String { parts.count == 1 ? parts[0].voice : "mochi\(id)" }

        /// Heart as Kokoro made it was the user's pick (2026-11-04); the others stay to try.
        static let all: [Style] = [
            Style(id: "heart", title: "Heart", blurb: "Warm and clear: Kokoro's best voice, just as it is.",
                  parts: [Part(voice: "af_heart", weight: 1)], cents: 0, speed: 1),
            Style(id: "bellasky", title: "Bella + Sky", blurb: "Expressive and young, a little higher: a mix only Mochi has.",
                  parts: [Part(voice: "af_bella", weight: 0.6), Part(voice: "af_sky", weight: 0.4)], cents: 250, speed: 1),
            Style(id: "soft", title: "Soft", blurb: "Heart and Nicole mixed: the gentlest one.",
                  parts: [Part(voice: "af_heart", weight: 0.5), Part(voice: "af_nicole", weight: 0.5)], cents: 200, speed: 1),
            Style(id: "lily", title: "Lily", blurb: "A British voice, a little higher.",
                  parts: [Part(voice: "bf_lily", weight: 1)], cents: 250, speed: 1),
        ]

        /// The style set in Settings.
        static var current: Style {
            let id = UserDefaults.standard.string(forKey: KokoroVoice.styleKey)
            return all.first { $0.id == id } ?? all[0]
        }
    }

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    /// On: Mochi reads with Kokoro once it's downloaded. Off: the iPhone voice.
    nonisolated static let enabledKey = "kokoroVoiceOn"
    nonisolated static let styleKey = "kokoroVoiceStyle"
    /// About how much the first download is (the Core ML models, voices and pronunciation data).
    static let downloadSize = "98 MB"

    private(set) var phase = Phase.idle
    /// The model is on this iPhone (it downloaded completely once).
    private(set) var downloaded: Bool

    @ObservationIgnored private var manager: KokoroAneManager?
    @ObservationIgnored private var repo: URL?
    @ObservationIgnored private var preparing: Task<Bool, Never>?
    @ObservationIgnored private var release: Task<Void, Never>?

    /// Kept in Application Support (iOS doesn't clear it like Caches) and out of iCloud backups.
    nonisolated private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kokoro", isDirectory: true)
    }()
    nonisolated private static let marker = directory.appendingPathComponent("downloaded")

    private init() {
        downloaded = FileManager.default.fileExists(atPath: Self.marker.path)
    }

    /// Kokoro is turned on and on this iPhone, so readings use it.
    nonisolated static var inUse: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && FileManager.default.fileExists(atPath: marker.path)
    }

    /// Loaded and able to speak right away.
    var loaded: Bool { manager != nil }

    /// Downloads Kokoro the first time, then loads it; true once it can speak. Safe to call again while it works.
    @discardableResult
    func prepare() async -> Bool {
        release?.cancel()
        if manager != nil { return true }
        if let preparing { return await preparing.value }
        let task = Task { await load() }
        preparing = task
        let ready = await task.value
        preparing = nil
        return ready
    }

    /// Mochi's words as 24 kHz mono samples, in `style`.
    func speech(_ text: String, style: Style) async throws -> [Float] {
        guard let manager, let repo else { throw KokoroVoiceError.notReady }
        release?.cancel()
        try await Self.ensure(style, in: repo)
        return try await manager.synthesizeDetailed(text: text, voice: style.voice, speed: style.speed).samples
    }

    /// After a reading: let the model go once Mochi has been quiet a few minutes, to give the memory back.
    func idle() {
        release?.cancel()
        release = Task {
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let manager = self.manager else { return }
            self.manager = nil
            self.phase = .idle
            await manager.cleanup()
        }
    }

    /// Deletes the download (Settings › Remove) and goes back to the iPhone voice.
    func remove() {
        release?.cancel()
        let manager = manager
        self.manager = nil
        repo = nil
        Task { await manager?.cleanup() }
        try? FileManager.default.removeItem(at: Self.directory)
        downloaded = false
        phase = .idle
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    private func load() async -> Bool {
        let directory = Self.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var noBackup = URLResourceValues()
            noBackup.isExcludedFromBackup = true
            var folder = directory
            try? folder.setResourceValues(noBackup)

            phase = downloaded ? .loading : .downloading(0)
            let repo = try await KokoroAneResourceDownloader.ensureModels(directory: directory) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in KokoroVoice.shared.downloading(fraction) }
            }
            phase = .loading
            let manager = KokoroAneManager(directory: directory)
            try await manager.initialize()
            try await Self.ensure(Style.current, in: repo)
            if !downloaded {
                FileManager.default.createFile(atPath: Self.marker.path, contents: Data())
                downloaded = true
            }
            self.repo = repo
            self.manager = manager
            phase = .ready
            return true
        } catch {
            phase = .failed(Self.describe(error))
            return false
        }
    }

    private func downloading(_ fraction: Double) {
        if case .downloading = phase { phase = .downloading(min(max(fraction, 0), 1)) }
    }

    /// Makes sure a style's voice packs are here (fetching a Kokoro voice the first time it's used) and, for a
    /// mix, that the blend is saved where Kokoro looks for packs.
    private static func ensure(_ style: Style, in repo: URL) async throws {
        let blend = repo.appendingPathComponent("\(style.voice).bin")
        if FileManager.default.fileExists(atPath: blend.path) { return }
        for part in style.parts {
            try await KokoroAneResourceDownloader.ensureVoicePack(part.voice, repoDirectory: repo)
        }
        guard style.parts.count > 1 else { return }
        let count = KokoroAneConstants.voicePackRows * KokoroAneConstants.voicePackCols
        var mix = [Float](repeating: 0, count: count)
        for part in style.parts {
            let pack = try KokoroAneVoicePack.load(from: repo.appendingPathComponent("\(part.voice).bin"))
            for index in 0..<count { mix[index] += pack.storage[index] * part.weight }
        }
        try KokoroAneVoicePack(storage: mix).binaryData.write(to: blend, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain { return "Couldn't download it. Check your connection and try again." }
        return "Kokoro couldn't start: \(error.localizedDescription)"
    }

    #if DEBUG
    /// `-kokoroTest 1` (devicectl): downloads and loads Kokoro, turns it on, and logs how long a sentence takes.
    func selfTest() async {
        let log = MacLink.shared.log
        let started = Date()
        log("kokoro: preparing (downloaded=\(downloaded))")
        guard await prepare() else {
            log("kokoro: failed \(phase)")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        log("kokoro: ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for text in ["Three things are waiting for you.", "Priya needs you: the invoice for October. That's everything."] {
            let begun = Date()
            do {
                let samples = try await speech(text, style: .current)
                log("kokoro: \(String(format: "%.1f", Double(samples.count) / 24_000)) s of speech in "
                    + "\(String(format: "%.2f", Date().timeIntervalSince(begun))) s")
            } catch {
                log("kokoro: speech failed \(error)")
            }
        }
        idle()
    }
    #endif
}

enum KokoroVoiceError: Error {
    case notReady
}
