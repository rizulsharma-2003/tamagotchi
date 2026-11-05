import ActivityKit
import Foundation
import TamagotchiCore
import Observation
import UIKit

/// Keeps the Mac able to reach this iPhone's Live Activity. The push-to-start token and each
/// activity's update token go into iCloud key-value storage, which the Mac app (same Apple ID,
/// same developer team) reads. Nothing else is stored there.
@MainActor
@Observable
final class ActivityCoordinator {
    static let shared = ActivityCoordinator()

    private(set) var activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var hasPushToStartToken = false
    private(set) var iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
    private(set) var runningPhases: [String] = []
    private(set) var lastSaved: Date?

    private var linkStore: LinkStore { MochiLink.store }
    private var started = false
    private var watched = Set<String>()
    private var loggedActivities: String?


    func start() {
        guard !started else { return }
        started = true
        linkStore.flush()
        Task {
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates { activitiesEnabled = enabled }
        }
        if let token = Activity<MochiActivityAttributes>.pushToStartToken { save(pushToStart: token) }
        Task {
            for await token in Activity<MochiActivityAttributes>.pushToStartTokenUpdates { save(pushToStart: token) }
        }
        for activity in Activity<MochiActivityAttributes>.activities { watch(activity) }
        Task {
            for await activity in Activity<MochiActivityAttributes>.activityUpdates { watch(activity) }
        }
        refresh()
        NotificationCenter.default.addObserver(forName: .linkStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMacEnd() }
        }
        followMacEnd()
        if let phase = UserDefaults.standard.string(forKey: "demo") { startDemo(phase: phase) }
    }

    /// The Mac ended its Live Activity. Its push normally closes it; this covers the times the push
    /// can't (the Mac hadn't heard the activity's address yet), as soon as this app runs.
    func followMacEnd() {
        guard let ended = linkStore.dictionary(.activityEnded), let at = ended["at"] as? Double,
              at > UserDefaults.standard.double(forKey: "handledMacEnd") else { return }
        UserDefaults.standard.set(at, forKey: "handledMacEnd")
        let dismissAt = Date(timeIntervalSince1970: ended["dismissAt"] as? Double ?? at)
        // Only the turn that ended (or older ones): a newer activity the Mac started since stays.
        let since = ended["since"] as? Double ?? at
        for activity in Activity<MochiActivityAttributes>.activities
        where activity.activityState != .dismissed && activity.content.state.since <= since && !demoIDs.contains(activity.id) {
            MacLink.shared.log("closing activity \(activity.id.prefix(6)), which the Mac ended")
            Task { await activity.end(nil, dismissalPolicy: dismissAt > Date() ? .after(dismissAt) : .immediate) }
        }
    }

    private func watch(_ activity: Activity<MochiActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                save(update: token, for: activity.id)
                MacLink.shared.log("activity \(activity.id.prefix(6)) shared its update address")
            }
        }
        Task {
            for await _ in activity.activityStateUpdates { refresh() }
        }
        Task {
            for await _ in activity.contentUpdates { refresh() }
        }
        refresh()
    }

    private func refresh() {
        let activities = Activity<MochiActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        runningPhases = activities.map(\.content.state.phase)
        let described = activities.map { "\($0.id.prefix(6)) \($0.content.state.phase)" }.joined(separator: ", ")
        if described != loggedActivities {
            loggedActivities = described
            MacLink.shared.log("live activities: \(described.isEmpty ? "none" : described)")
        }
        iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        // Forget tokens of activities that ended, so the Mac never pushes to them.
        let live = Set(activities.map(\.id))
        var tokens = linkStore.dictionary(.updateTokens) as? [String: String] ?? [:]
        let before = tokens.count
        tokens = tokens.filter { live.contains($0.key) }
        if tokens.count != before {
            linkStore.set(tokens, for: .updateTokens)
            markSaved()
        }
    }

    private func save(pushToStart token: Data) {
        linkStore.set(token.hex, for: .pushToStart)
        hasPushToStartToken = true
        markSaved()
    }

    private func save(update token: Data, for activityID: String) {
        var tokens = linkStore.dictionary(.updateTokens) as? [String: String] ?? [:]
        tokens[activityID] = token.hex
        linkStore.set(tokens, for: .updateTokens)
        markSaved()
    }

    private func markSaved() {
        linkStore.set(Date().timeIntervalSince1970, for: .tokensSavedAt)
        linkStore.flush()
        PocketLink.shared.registerPush()
        lastSaved = Date()
    }

    // MARK: Trying it without the Mac

    func startDemo(phase: String = "working") {
        let attributes = MochiActivityAttributes(petName: "Mochi", companionName: "Patch")
        let state = Self.demoState(phase, frame: 0)
        if let activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: .token) {
            demoIDs.insert(activity.id)
        }
        refresh()
    }

    // MARK: A moving demo

    @ObservationIgnored private var demoIDs = Set<String>()
    @ObservationIgnored private var animation: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// After you leave the app, test Live Activities keep moving for a little while (iOS gives an app
    /// about half a minute). While Claude works, your Mac moves them on with its updates instead.
    func animateDemoWhileAway(for seconds: Double = 25) {
        let demos = Activity<MochiActivityAttributes>.activities.filter { demoIDs.contains($0.id) && $0.activityState == .active }
        guard !demos.isEmpty, animation == nil else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Mochi demo") { [weak self] in
            MainActor.assumeIsolated { self?.stopDemoAnimation() }
        }
        animation = Task {
            let end = Date().addingTimeInterval(seconds)
            var frame = 0
            while Date() < end, !Task.isCancelled {
                frame += 1
                for activity in Activity<MochiActivityAttributes>.activities where demoIDs.contains(activity.id) {
                    var state = activity.content.state
                    state.frame = frame % 10
                    await activity.update(.init(state: state, staleDate: nil))
                }
                try? await Task.sleep(for: .seconds(1.2))
            }
            stopDemoAnimation()
        }
    }

    func stopDemoAnimation() {
        animation?.cancel()
        animation = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func nextDemoPhase() {
        let order = ["working", "waiting", "done", "error", "idle", "asleep"]
        for activity in Activity<MochiActivityAttributes>.activities {
            let current = order.firstIndex(of: activity.content.state.phase) ?? 0
            let next = Self.demoState(order[(current + 1) % order.count])
            Task { await activity.update(.init(state: next, staleDate: nil)) }
        }
    }

    func endAll() {
        for activity in Activity<MochiActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    static func demoState(_ phase: String, frame: Int? = nil) -> MochiActivityAttributes.ContentState {
        let titles = ["working": "Claude is working", "waiting": "Claude needs you", "done": "Claude finished!",
                      "error": "Claude hit a snag", "idle": "Claude is idle", "asleep": "Mochi is napping"]
        return .init(phase: phase, title: titles[phase] ?? "Mochi", detail: "A test from your iPhone",
                     since: Date().timeIntervalSince1970 - 95, frame: frame)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
