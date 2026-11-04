import Foundation
import Observation
import TamagotchiWire

/// Persists `AppSettings` as JSON in the app's private directory.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            onChange?(oldValue, settings)
        }
    }

    /// Called after every change with the old and new values.
    @ObservationIgnored public var onChange: ((AppSettings, AppSettings) -> Void)?
    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// `fileURL == nil` keeps settings in memory only (tests, previews).
    public init(fileURL: URL?, initial: AppSettings? = nil) {
        self.fileURL = fileURL
        if let initial {
            settings = initial
        } else if let fileURL, let data = try? Data(contentsOf: fileURL) {
            settings = AppSettings.decodeTolerantly(data)
        } else {
            settings = AppSettings()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        BridgePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        chmod(fileURL.path, 0o600)
    }
}
