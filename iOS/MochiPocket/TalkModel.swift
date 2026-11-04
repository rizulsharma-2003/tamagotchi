import Foundation
import Observation
import UIKit

/// Press and hold Mochi: it turns its right ear towards you and listens; let go and what you said
/// goes to your Mac, where Ask Mochi carries it out. The answer comes back here. Every state finds its
/// way back to normal: a tap cancels, and a Mac that doesn't answer times out.
@MainActor
@Observable
final class TalkModel {
    enum Phase: Equatable {
        case idle, approaching, listening, sending, waiting, replied, failed

        /// Talking takes over Mochi's pose in the room.
        var overridesPet: Bool { self != .idle }
    }

    private(set) var phase: Phase = .idle
    private(set) var phaseStart = Date()
    private(set) var bubble: String?
    private(set) var transcript = ""
    var isHolding: Bool { phase == .approaching || phase == .listening }
    var isBusy: Bool { phase != .idle }

    let link: MacLink
    private let listener = PhoneListener()
    private var waitingFor: String?
    /// Moves on with every new start or cancel, so a late result from an older one is dropped.
    private var generation = 0
    private var stopping = false
    private var settleTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?

    private static let answerTimeout: Double = 45

    init(link: MacLink) {
        self.link = link
    }

    private func set(_ phase: Phase, bubble: String?? = .none) {
        self.phase = phase
        phaseStart = Date()
        if case .some(let text) = bubble { self.bubble = text }
    }

    // MARK: Talking

    func earHeld() {
        guard !isHolding, !stopping else { return }
        reset()
        transcript = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        set(.approaching, bubble: .some("I'm listening…"))
        listenTask = Task {
            do {
                try await listener.start { [weak self] text in
                    guard let self, self.isHolding else { return }
                    self.transcript = text
                    self.bubble = text
                }
                guard isHolding else {
                    listener.cancel()
                    return
                }
                try? await Task.sleep(for: .seconds(max(0, 0.8 - Date().timeIntervalSince(phaseStart))))
                if !Task.isCancelled, phase == .approaching { set(.listening) }
            } catch {
                listener.cancel()
                if isHolding { fail(error.localizedDescription) }
            }
        }
    }

    func earReleased() {
        guard isHolding else { return }
        listenTask?.cancel()
        let ticket = generation
        // Out of listening at once: a tap from here cancels instead of releasing twice.
        set(.sending, bubble: .some(transcript.isEmpty ? "…" : "“\(transcript)”"))
        stopping = true
        Task {
            let heard = await listener.stop() ?? (transcript.isEmpty ? nil : transcript)
            stopping = false
            guard ticket == generation else { return }
            guard let text = heard, text.count > 1 else {
                set(.idle, bubble: .some("I didn't catch that — hold me and talk."))
                settle(after: 3)
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            send(text)
        }
    }

    /// Sends typed words the same way as spoken ones; with `project`, to that Claude session.
    func send(typed text: String, project: String? = nil, session: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isHolding { listener.cancel() }
        reset()
        send(text, project: project, session: session, typed: true)
    }

    private func send(_ text: String, project: String? = nil, session: String? = nil, typed: Bool = false) {
        set(.sending, bubble: .some(project.map { "To Claude in \($0): “\(text)”" } ?? "“\(text)”"))
        waitingFor = link.send(text, project: project, session: session, typed: typed)
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            if phase == .sending { set(.waiting, bubble: .some("Sending to your Mac…")) }
            try? await Task.sleep(for: .seconds(Self.answerTimeout))
            guard !Task.isCancelled, phase == .waiting || phase == .sending else { return }
            waitingFor = nil
            fail("Your Mac didn't answer — is it awake and online?")
        }
    }

    /// "Check now" went straight to Mochi Cloud.
    func cloudChecking() {
        if isHolding { listener.cancel() }
        reset()
        set(.replied, bubble: .some("Asking Mochi Cloud… your news arrives as a notification in a minute or two."))
        settle(after: 8)
    }

    /// The Mac didn't pick up "Check now", so Mochi Cloud did: say so rather than wait for the Mac.
    func cloudTookOver() {
        guard waitingFor != nil else { return }
        waitingFor = nil
        timeoutTask?.cancel()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        set(.replied, bubble: .some("Your Mac is away, so Mochi Cloud is checking — your news arrives as a notification in a minute or two."))
        settle(after: 10)
    }

    /// Back to normal right away (a tap on Mochi, or the Cancel button).
    func cancel() {
        listener.cancel()
        reset()
        set(.idle, bubble: .some(nil))
    }

    /// Follows the Mac's answers.
    func linkChanged() {
        guard let waitingFor, let exchange = link.exchanges.first(where: { $0.id == waitingFor }) else { return }
        switch exchange.state {
        case .sending: break
        case .working:
            if phase == .waiting || phase == .sending { bubble = "Your Mac is on it…" }
        case .done, .failed:
            self.waitingFor = nil
            timeoutTask?.cancel()
            let ok = exchange.state == .done
            UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .warning)
            set(ok ? .replied : .failed, bubble: .some(exchange.reply ?? (ok ? "Done!" : "That didn't work.")))
            settle(after: 8)
        }
    }

    private func fail(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        set(.failed, bubble: .some(message))
        settle(after: 5)
    }

    private func reset() {
        generation += 1
        settleTask?.cancel()
        timeoutTask?.cancel()
        listenTask?.cancel()
        waitingFor = nil
    }

    private func settle(after seconds: Double) {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !isHolding, phase != .sending, phase != .waiting else { return }
            set(.idle, bubble: .some(nil))
        }
    }
}
