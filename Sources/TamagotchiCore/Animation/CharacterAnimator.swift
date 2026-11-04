import Foundation

/// The animation state machine for one character.
///
/// There is always exactly one thing playing: either the current base loop or a
/// one-shot on top of it. One-shots end on their own and fall back to whatever the
/// base is *at that moment*, so a character can never get stuck in an old pose.
/// Each start gets a token; completions report it so obsolete callbacks can be
/// ignored.
public struct CharacterAnimator<Animation: CharacterAnimationKind>: Equatable, Sendable {
    public struct Playing: Equatable, Sendable {
        public var animation: Animation
        public var priority: AnimationPriority
        public var startedAt: TimeInterval
        /// nil for loops.
        public var duration: TimeInterval?
        public var token: Int
        /// Set when an interaction script drives this animation.
        public var scriptID: String?

        public func isFinished(at now: TimeInterval) -> Bool {
            guard let duration else { return false }
            return now >= startedAt + duration
        }

        public func elapsed(at now: TimeInterval) -> TimeInterval { max(0, now - startedAt) }
    }

    public enum PlayResult: Equatable, Sendable {
        case started(token: Int, interrupted: Int?)
        case busy
        case coolingDown
    }

    public struct Completion: Equatable, Sendable {
        public var animation: Animation
        public var token: Int
        public var scriptID: String?
        /// False when the animation was replaced or cancelled before finishing.
        public var finished: Bool
    }

    public private(set) var current: Playing
    public private(set) var base: Animation
    private var nextToken: Int
    private var lastStarted: [Animation: TimeInterval] = [:]

    public init(base: Animation, at now: TimeInterval) {
        self.base = base
        self.current = Playing(animation: base, priority: .base, startedAt: now, duration: nil, token: 1, scriptID: nil)
        self.nextToken = 2
    }

    public var isPlayingOneShot: Bool { current.duration != nil }

    /// Starts a one-shot (or a scripted segment) on top of the base.
    @discardableResult
    public mutating func play(
        _ animation: Animation,
        priority: AnimationPriority,
        at now: TimeInterval,
        duration: TimeInterval? = nil,
        scriptID: String? = nil,
        ignoreCooldown: Bool = false
    ) -> PlayResult {
        if !ignoreCooldown, animation.cooldown > 0,
           let last = lastStarted[animation], now - last < animation.cooldown {
            return .coolingDown
        }
        if isPlayingOneShot, !current.isFinished(at: now), priority < current.priority {
            return .busy
        }
        let interrupted = isPlayingOneShot && !current.isFinished(at: now) ? current.token : nil
        let token = nextToken
        nextToken += 1
        current = Playing(
            animation: animation,
            priority: priority,
            startedAt: now,
            duration: max(0.05, duration ?? animation.defaultDuration),
            token: token,
            scriptID: scriptID
        )
        lastStarted[animation] = now
        return .started(token: token, interrupted: interrupted)
    }

    /// Changes the loop to return to. If the base is what is playing now, the
    /// switch happens immediately.
    public mutating func setBase(_ animation: Animation, at now: TimeInterval) {
        guard animation != base else { return }
        base = animation
        if !isPlayingOneShot {
            current = Playing(animation: animation, priority: .base, startedAt: now, duration: nil, token: nextToken, scriptID: nil)
            nextToken += 1
        }
    }

    /// Advances time. Returns a completion if a one-shot just ended.
    public mutating func update(at now: TimeInterval) -> Completion? {
        guard isPlayingOneShot, current.isFinished(at: now) else { return nil }
        let finished = Completion(animation: current.animation, token: current.token, scriptID: current.scriptID, finished: true)
        current = Playing(animation: base, priority: .base, startedAt: now, duration: nil, token: nextToken, scriptID: nil)
        nextToken += 1
        return finished
    }

    /// Cancels the given one-shot if it is still playing.
    @discardableResult
    public mutating func cancel(token: Int, at now: TimeInterval) -> Completion? {
        guard isPlayingOneShot, current.token == token else { return nil }
        let cancelled = Completion(animation: current.animation, token: token, scriptID: current.scriptID, finished: false)
        current = Playing(animation: base, priority: .base, startedAt: now, duration: nil, token: nextToken, scriptID: nil)
        nextToken += 1
        return cancelled
    }

    /// Cancels whatever one-shot is playing (e.g. when reactions are paused).
    @discardableResult
    public mutating func cancelOneShot(at now: TimeInterval) -> Completion? {
        cancel(token: current.token, at: now)
    }
}
