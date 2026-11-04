import SwiftUI
import TamagotchiCore

/// Settings for the playful features.
struct FunSettings: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        let name = store.settings.petName
        Form {
            Section("Talking") {
                Toggle("\(name) and \(store.settings.companionName) talk in speech bubbles", isOn: $store.settings.speech.enabled)
                Picker("Chattiness", selection: $store.settings.speech.chattiness) {
                    ForEach(Chattiness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!store.settings.speech.enabled)
                Toggle("Fresh lines from Apple Intelligence (on this Mac)", isOn: $store.settings.speech.useAppleIntelligence)
                    .disabled(!store.settings.speech.enabled)
            }
            Section("Touch") {
                Toggle("Purr on the trackpad while you pet \(name)", isOn: $store.settings.hapticPurr)
                Text("Press and hold on \(name) in the panel or on the desktop. Needs a Force Touch trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Growing up") {
                Toggle("\(name) grows up over time", isOn: $store.settings.lifeStages)
                Text("Kitten, then young, then grown-up as your friendship grows. It never goes backwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("\(name) naps in the notch on MacBooks", isOn: $store.settings.notchDen)
            }
            AdventureSettingsSection(environment: environment)
            FocusSettingsSection(environment: environment)
            RecapSettingsSection(environment: environment)
            GamesSettingsSection(environment: environment)
            RoomSettingsSection(environment: environment)
            SeasonalSettingsSection(environment: environment)
        }
        .formStyle(.grouped)
    }
}
