import Foundation
import Testing
@testable import TamagotchiCore

/// Golden fixtures for the Dart port of Mochi's world (flutter/packages/mochi_world): the Swift engine runs fixed seeds
/// and scripted timelines, and its results are kept in `link-spec/world/*.json`, which the Dart tests replay.
///
/// The tests below regenerate each fixture and require it to equal the committed file, so the fixtures can never drift
/// from the Mac's behaviour. After a deliberate change to the engine, rewrite them with
///
///     MOCHI_WRITE_WORLD_FIXTURES=1 swift test --filter WorldFixture
///
/// and run the Dart tests (`dart test` in flutter/packages/mochi_world) to see what the port must follow.
enum WorldFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("link-spec").appendingPathComponent("world")

    static var writing: Bool { ProcessInfo.processInfo.environment["MOCHI_WRITE_WORLD_FIXTURES"] == "1" }

    /// Writes the fixture (when asked to) or checks the committed one is exactly what the engine produces now.
    static func check(_ name: String, _ json: String) throws {
        let url = directory.appendingPathComponent(name)
        let text = json + "\n"
        if writing {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == text, "link-spec/world/\(name) no longer matches the Swift engine: MOCHI_WRITE_WORLD_FIXTURES=1 swift test --filter WorldFixture")
    }

    /// A fixed UTC calendar, so day boundaries in the fixtures don't depend on the machine's time zone.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

// MARK: - A tiny deterministic JSON writer (key order as written, numbers to 12 significant digits)

enum FixtureJSON {
    static func num(_ x: Double) -> String {
        guard x.isFinite else { return "null" }
        if x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        let text = String(format: "%.12g", x)
        return text == "-0" ? "0" : text
    }

    static func str(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func array(_ items: [String], multiline: Bool = false) -> String {
        guard multiline, !items.isEmpty else { return "[" + items.joined(separator: ",") + "]" }
        return "[\n" + items.joined(separator: ",\n") + "\n]"
    }
}

/// An ordered JSON object.
struct FixtureObject {
    private(set) var parts: [String] = []

    var isEmpty: Bool { parts.isEmpty }

    mutating func raw(_ key: String, _ value: String) { parts.append("\(FixtureJSON.str(key)):\(value)") }

    mutating func num(_ key: String, _ value: Double, default fallback: Double? = nil) {
        if let fallback, value == fallback { return }
        raw(key, FixtureJSON.num(value))
    }

    /// An input value (a time, a duration) at full precision: the shortest text that reads back as the same Double,
    /// so a replay feeds the port exactly what Swift used.
    mutating func exact(_ key: String, _ value: Double) {
        raw(key, value.isFinite ? "\(value)" : "null")
    }

    mutating func optionalExact(_ key: String, _ value: Double?) {
        guard let value else { return }
        exact(key, value)
    }

    mutating func optionalNum(_ key: String, _ value: Double?) {
        guard let value else { return }
        raw(key, FixtureJSON.num(value))
    }

    mutating func int(_ key: String, _ value: Int, default fallback: Int? = nil) {
        if let fallback, value == fallback { return }
        raw(key, String(value))
    }

    mutating func optionalInt(_ key: String, _ value: Int?) {
        guard let value else { return }
        raw(key, String(value))
    }

    mutating func str(_ key: String, _ value: String?, default fallback: String? = nil) {
        guard let value, value != fallback else { return }
        raw(key, FixtureJSON.str(value))
    }

    mutating func bool(_ key: String, _ value: Bool, default fallback: Bool? = nil) {
        if let fallback, value == fallback { return }
        raw(key, value ? "true" : "false")
    }

    mutating func list(_ key: String, _ items: [String], omitEmpty: Bool = true, multiline: Bool = false) {
        if omitEmpty, items.isEmpty { return }
        raw(key, FixtureJSON.array(items, multiline: multiline))
    }

    mutating func object(_ key: String, _ value: FixtureObject, omitEmpty: Bool = false) {
        if omitEmpty, value.isEmpty { return }
        raw(key, value.json)
    }

    var json: String { "{" + parts.joined(separator: ",") + "}" }
}

// MARK: - Poses as JSON (the keys and defaults of mochi_world's PetPose / CompanionPose.fromJson)

enum PoseJSON {
    static func effect(_ e: Effect) -> String {
        var o = FixtureObject()
        o.str("kind", e.kind.rawValue)
        o.num("x", e.x)
        o.num("y", e.y)
        o.num("scale", e.scale, default: 1)
        o.num("opacity", e.opacity, default: 1)
        o.num("rotation", e.rotation, default: 0)
        o.int("variant", e.variant, default: 0)
        o.num("stretch", e.stretch, default: 0)
        o.num("phase", e.phase, default: 0)
        o.num("x2", e.x2, default: 0)
        o.num("y2", e.y2, default: 0)
        o.bool("followsFacing", e.followsFacing, default: false)
        o.bool("worldSpace", e.worldSpace, default: false)
        return o.json
    }

    static func pet(_ p: PetPose) -> String {
        var o = FixtureObject()
        o.num("x", p.x, default: 0)
        o.num("y", p.y, default: 0)
        o.num("scaleX", p.scaleX, default: 1)
        o.num("scaleY", p.scaleY, default: 1)
        o.num("rotation", p.rotation, default: 0)
        o.num("tilt", p.tilt, default: 0)
        o.num("facing", p.facing, default: 1)
        o.str("eyes", p.eyes.rawValue, default: "open")
        o.num("eyeOpenness", p.eyeOpenness, default: 1)
        o.num("lookX", p.lookX, default: 0.15)
        o.num("lookY", p.lookY, default: 0)
        o.str("brows", p.brows.rawValue, default: "none")
        o.str("mouth", p.mouth.rawValue, default: "cat")
        o.num("blush", p.blush, default: 0.35)
        o.num("earPerk", p.earPerk, default: 0)
        o.num("leftArm", p.leftArm, default: 0)
        o.num("rightArm", p.rightArm, default: 0)
        o.num("tailWag", p.tailWag, default: 0)
        o.num("step", p.step, default: 0)
        o.str("held", p.held?.rawValue)
        o.str("hat", p.hat?.rawValue)
        o.list("effects", p.effects.map(effect))
        o.num("shadow", p.shadow, default: 1)
        o.num("opacity", p.opacity, default: 1)
        o.num("earLeft", p.earLeft, default: 0)
        o.num("earRight", p.earRight, default: 0)
        o.num("tailCurl", p.tailCurl, default: 0)
        o.num("tailLift", p.tailLift, default: 0)
        o.num("lean", p.lean, default: 0)
        o.num("breath", p.breath, default: 0)
        o.num("cheekLeft", p.cheekLeft, default: 0)
        o.num("cheekRight", p.cheekRight, default: 0)
        o.num("eyeSparkle", p.eyeSparkle, default: 0)
        o.num("eyeScale", p.eyeScale, default: 1)
        o.num("crossEyed", p.crossEyed, default: 0)
        o.num("stride", p.stride, default: 0)
        o.num("kick", p.kick, default: 0)
        o.num("pawToMouth", p.pawToMouth, default: 0)
        o.num("holdFront", p.holdFront, default: 0)
        o.num("headTurn", p.headTurn, default: 0)
        o.num("earListen", p.earListen, default: 0)
        return o.json
    }

    static func companion(_ p: CompanionPose) -> String {
        var o = FixtureObject()
        o.num("x", p.x, default: 0)
        o.num("y", p.y, default: 0)
        o.num("scaleX", p.scaleX, default: 1)
        o.num("scaleY", p.scaleY, default: 1)
        o.num("rotation", p.rotation, default: 0)
        o.num("facing", p.facing, default: -1)
        o.str("eyes", p.eyes.rawValue, default: "normal")
        o.num("eyeOpenness", p.eyeOpenness, default: 1)
        o.num("lookX", p.lookX, default: 0)
        o.num("lookY", p.lookY, default: 0)
        o.str("mouth", p.mouth.rawValue, default: "none")
        o.num("visorBrightness", p.visorBrightness, default: 1)
        o.num("antennaGlow", p.antennaGlow, default: 0.35)
        o.str("antennaTint", p.antennaTint.rawValue, default: "calm")
        o.num("antennaBend", p.antennaBend, default: 0)
        o.num("leftArm", p.leftArm, default: 0)
        o.num("rightArm", p.rightArm, default: 0)
        o.num("reach", p.reach, default: 0)
        o.str("held", p.held?.rawValue)
        o.str("hat", p.hat?.rawValue)
        var laptop = FixtureObject()
        laptop.bool("visible", p.laptop.visible, default: true)
        laptop.num("openness", p.laptop.openness, default: 1)
        laptop.str("screen", p.laptop.screen.rawValue, default: "idle")
        laptop.num("scroll", p.laptop.scroll, default: 0)
        o.object("laptop", laptop, omitEmpty: true)
        o.list("effects", p.effects.map(effect))
        o.num("shadow", p.shadow, default: 1)
        o.num("opacity", p.opacity, default: 1)
        return o.json
    }

    static func prop(_ p: SceneProp) -> String {
        var o = FixtureObject()
        o.str("kind", p.kind.rawValue)
        o.num("x", p.x)
        o.num("y", p.y)
        o.num("scale", p.scale, default: 1)
        o.num("opacity", p.opacity, default: 1)
        o.num("rotation", p.rotation, default: 0)
        o.int("variant", p.variant, default: 0)
        return o.json
    }

    static func context(_ c: PoseContext) -> String {
        var o = FixtureObject()
        o.exact("time", c.time)
        o.bool("reducedMotion", c.reducedMotion, default: false)
        o.str("intensity", c.intensity.rawValue, default: "normal")
        o.raw("seed", FixtureJSON.str(String(c.seed)))
        o.str("returnLoop", c.returnLoop.rawValue, default: "idle")
        return o.json
    }
}
