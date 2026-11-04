import Foundation

/// A quantized fingerprint of what a frame draws, so the menu bar can skip re-rendering
/// frames that would look identical.
///
/// Poses are read by reflection: every channel of `PetPose`, `CompanionPose` and `Effect`
/// counts, including ones added later, so a new ear twitch or tail curl can never be frozen
/// by an out-of-date list. Known channels get steps of about a quarter of a pixel at menu-bar
/// scale on a Retina display (coarser on 1× displays); unknown ones get a fine default.
public struct PoseSignature: Equatable, Sendable {
    public private(set) var values: [Int32] = []
    /// 1 on Retina displays; larger steps where pixels are bigger.
    public var resolution: Double

    public init(resolution: Double = 1) {
        self.resolution = resolution
        values.reserveCapacity(160)
    }

    public mutating func add(_ value: Int) { values.append(Int32(truncatingIfNeeded: value)) }

    public mutating func add(_ value: Bool) { values.append(value ? 1 : 0) }

    public mutating func add(_ value: Double, _ step: Double) {
        guard value.isFinite else { return add(Int.max) }
        values.append(Int32(clamping: Int((value / (step * resolution)).rounded())))
    }

    public mutating func add(_ value: String) { add(value.hashValue) }

    public mutating func pet(_ pose: PetPose) { reflect(pose, steps: Self.petSteps, fallback: 0.02) }

    public mutating func companion(_ pose: CompanionPose) { reflect(pose, steps: Self.companionSteps, fallback: 0.02) }

    public mutating func effects(_ effects: [Effect]) {
        add(effects.count)
        for effect in effects { reflect(effect, steps: Self.effectSteps, fallback: 0.03) }
    }

    // MARK: Steps (pose units: body widths/heights, radians, 0…1 amounts)

    /// At bar scale Mochi is ~30 px tall on a Retina display: these are about ⅓–½ px of movement,
    /// so slow drifts (the tail's sway, a wandering gaze) re-render only when it shows.
    public static let petSteps: [String: Double] = [
        "x": 0.005, "y": 0.01, "scaleX": 0.015, "scaleY": 0.015, "rotation": 0.02, "tilt": 0.035, "facing": 1,
        "eyeOpenness": 0.2, "lookX": 0.15, "lookY": 0.2, "blush": 0.1, "earPerk": 0.15, "leftArm": 0.05, "rightArm": 0.05,
        "tailWag": 0.35, "step": 0.15, "shadow": 0.1, "opacity": 0.04,
        "earLeft": 0.05, "earRight": 0.05, "tailCurl": 0.1, "tailLift": 0.1, "lean": 0.01, "breath": 0.6,
        "cheekLeft": 0.08, "cheekRight": 0.08, "eyeSparkle": 0.1, "eyeScale": 0.03, "crossEyed": 0.1, "stride": 0.1,
        "kick": 0.1, "pawToMouth": 0.06, "holdFront": 0.06, "headTurn": 0.12, "earListen": 0.1,
    ]

    /// Patch is ~11 pt per unit at 0.2 scale.
    static let companionSteps: [String: Double] = [
        "x": 0.01, "y": 0.012, "scaleX": 0.01, "scaleY": 0.01, "rotation": 0.02, "facing": 1, "eyeOpenness": 0.12,
        "lookX": 0.12, "lookY": 0.12, "visorBrightness": 0.08, "antennaGlow": 0.06, "antennaBend": 0.04, "leftArm": 0.06,
        "rightArm": 0.06, "reach": 0.06, "shadow": 0.1, "opacity": 0.04, "openness": 0.06,
        // The laptop's content scrolls on a screen the menu bar never shows.
        "scroll": 1_000,
    ]

    static let effectSteps: [String: Double] = [
        "x": 0.02, "y": 0.02, "scale": 0.04, "opacity": 0.05, "rotation": 0.06, "stretch": 0.03, "phase": 0.05,
        "x2": 0.02, "y2": 0.02,
    ]

    // MARK: Reflection

    private mutating func reflect(_ subject: Any, steps: [String: Double], fallback: Double) {
        for child in Mirror(reflecting: subject).children {
            let step = child.label.flatMap { steps[$0] } ?? fallback
            value(child.value, step: step, steps: steps, fallback: fallback, depth: 0)
        }
    }

    private mutating func value(_ value: Any, step: Double, steps: [String: Double], fallback: Double, depth: Int) {
        switch value {
        case let number as Double:
            add(number, step)
        case let flag as Bool:
            add(flag)
        case let number as Int:
            add(number)
        case let effects as [Effect]:
            self.effects(effects)
        case let effect as Effect:
            reflect(effect, steps: Self.effectSteps, fallback: 0.03)
        default:
            let mirror = Mirror(reflecting: value)
            switch mirror.displayStyle {
            case .optional:
                if let wrapped = mirror.children.first {
                    add(1)
                    self.value(wrapped.value, step: step, steps: steps, fallback: fallback, depth: depth + 1)
                } else {
                    add(-1)
                }
            case .struct where depth < 3:
                reflect(value, steps: steps, fallback: fallback)
            case .collection where depth < 3:
                add(mirror.children.count)
                for element in mirror.children {
                    self.value(element.value, step: step, steps: steps, fallback: fallback, depth: depth + 1)
                }
            default:
                if let hashable = value as? AnyHashable {
                    add(hashable.hashValue)
                } else {
                    add(String(describing: value))
                }
            }
        }
    }
}
