import Foundation
import TamagotchiWire

/// Validates wire envelopes before anything else sees them.
public enum EventSchemaValidator {
    /// Upper bound on a single wire line. Sanitized events are well under 2 KB.
    public static let maxLineBytes = 32 * 1024

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case tooLarge(Int)
        case malformed(String)
        case unsupportedVersion(Int)
        case invalidField(String)
        case implausibleTimestamp

        public var description: String {
            switch self {
            case .tooLarge(let size): return "event too large (\(size) bytes)"
            case .malformed(let reason): return "malformed event: \(reason)"
            case .unsupportedVersion(let v): return "unsupported schema version \(v)"
            case .invalidField(let field): return "invalid field '\(field)'"
            case .implausibleTimestamp: return "timestamp outside the accepted window"
            }
        }

        /// Short reason for the wire acknowledgement.
        public var code: String {
            switch self {
            case .tooLarge: return "too-large"
            case .malformed: return "malformed"
            case .unsupportedVersion: return "unsupported-version"
            case .invalidField: return "invalid-field"
            case .implausibleTimestamp: return "bad-timestamp"
            }
        }
    }

    public static func decode(_ line: Data, now: Date = Date(), maxAge: TimeInterval = 7 * 86_400) throws -> WireEvent {
        guard line.count <= maxLineBytes else { throw Rejection.tooLarge(line.count) }
        let event: WireEvent
        do {
            event = try WireEvent.decode(line)
        } catch let error as DecodingError {
            throw Rejection.malformed(describe(error))
        } catch {
            throw Rejection.malformed("not JSON")
        }
        try validate(event, now: now, maxAge: maxAge)
        return event
    }

    public static func validate(_ event: WireEvent, now: Date = Date(), maxAge: TimeInterval = 7 * 86_400) throws {
        guard event.v >= 1 else { throw Rejection.unsupportedVersion(event.v) }
        // Newer helpers may add fields; a newer *major* schema is refused.
        guard event.v <= WireEvent.currentSchemaVersion else { throw Rejection.unsupportedVersion(event.v) }

        guard WireText.identifier(event.id, maxLength: 96) != nil else { throw Rejection.invalidField("id") }
        guard WireText.identifier(event.event, maxLength: 40) != nil else { throw Rejection.invalidField("event") }
        if let session = event.session, WireText.identifier(session, maxLength: 128) == nil { throw Rejection.invalidField("session") }
        if let tool = event.tool, WireText.identifier(tool, maxLength: 96) == nil { throw Rejection.invalidField("tool") }
        if let toolUseId = event.toolUseId, WireText.identifier(toolUseId, maxLength: 96) == nil { throw Rejection.invalidField("toolUseId") }
        if let host = event.host, WireText.identifier(host, maxLength: 96) == nil { throw Rejection.invalidField("host") }
        try checkLength(event.project, 64, "project")
        try checkLength(event.projectKey, 32, "projectKey")
        try checkLength(event.projectPath, 4096, "projectPath")
        try checkLength(event.message, 200, "message")
        try checkLength(event.notificationType, 40, "notificationType")
        try checkLength(event.agentType, 48, "agentType")
        try checkLength(event.agentId, 64, "agentId")
        try checkLength(event.source, 24, "source")
        try checkLength(event.reason, 48, "reason")
        try checkLength(event.model, 64, "model")
        try checkLength(event.report?.label, 80, "report.label")
        try checkLength(event.summary, HookPayloadSanitizer.maxSummaryLength, "summary")
        try checkLength(event.file, 96, "file")
        if let tools = event.batchTools, tools.count > 16 { throw Rejection.invalidField("batchTools") }
        if let path = event.projectPath, !path.hasPrefix("/") { throw Rejection.invalidField("projectPath") }

        let timestamp = Date(timeIntervalSince1970: event.ts)
        guard event.ts.isFinite,
              timestamp > now.addingTimeInterval(-maxAge),
              timestamp < now.addingTimeInterval(300) else {
            throw Rejection.implausibleTimestamp
        }

        if event.origin == .report {
            guard let report = event.report,
                  ExplicitReport.Kind(rawValue: report.kind) != nil,
                  ExplicitReport.Status(rawValue: report.status) != nil else {
                throw Rejection.invalidField("report")
            }
        }
    }

    private static func checkLength(_ value: String?, _ max: Int, _ field: String) throws {
        if let value, value.count > max { throw Rejection.invalidField(field) }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at '\(context.codingPath.map(\.stringValue).joined(separator: "."))'"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "undecodable"
        }
    }
}
