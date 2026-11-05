import ActivityKit
import SwiftUI

/// The look of Mochi's Live Activity, shared by the widget extension and the app's preview.
enum MochiStyle {
    static let accent = Color(red: 0.95, green: 0.55, blue: 0.38)
    static let background = Color(red: 0.16, green: 0.12, blue: 0.20)
    static let backgroundTop = Color(red: 0.25, green: 0.17, blue: 0.29)

    static func glyph(for phase: String) -> (String, Color) {
        switch phase {
        case "waiting": return ("hand.raised.fill", Color(red: 1.0, green: 0.72, blue: 0.30))
        case "done": return ("checkmark.circle.fill", Color(red: 0.45, green: 0.85, blue: 0.50))
        case "error": return ("exclamationmark.triangle.fill", Color(red: 1.0, green: 0.80, blue: 0.35))
        case "asleep", "idle": return ("moon.zzz.fill", Color(red: 0.70, green: 0.66, blue: 1.0))
        default: return ("sparkle", accent)
        }
    }
}

/// Mochi, the desk and Patch (or Patch alone) for a phase. `frame` picks one of ten poses; in a Live
/// Activity each update moves it on and the system animates the change.
struct PhaseArt: View {
    enum Kind { case scene, sprite }

    let kind: Kind
    let phase: String
    var frame: Int?
    let height: CGFloat

    private var name: String {
        let prefix = kind == .scene ? "scene" : "patch"
        return frame.map { "\(prefix)-\(phase)-\(($0 % 10 + 10) % 10)" } ?? "\(prefix)-\(phase)"
    }

    var body: some View {
        Image(name)
            .resizable()
            .interpolation(kind == .sprite ? .none : .high)
            .aspectRatio(kind == .scene ? 140.0 / 72.0 : 34.0 / 30.0, contentMode: .fit)
            .frame(height: height)
            .id(name)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .accessibilityHidden(true)
    }
}

struct ElapsedTimer: View {
    let since: Date

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    }
}

/// The status pill: an icon and the live timer (or the characters' names when idle).
struct StatusChip: View {
    let attributes: MochiActivityAttributes
    let state: MochiActivityAttributes.ContentState

    var body: some View {
        let (symbol, tint) = MochiStyle.glyph(for: state.phase)
        HStack(spacing: 5) {
            Image(systemName: symbol)
            if state.showsTimer {
                // A live timer claims the width of its longest value on the Lock Screen; keep it to a size.
                ElapsedTimer(since: state.sinceDate)
                    .frame(width: 62, alignment: .leading)
            } else {
                Text("\(attributes.petName) & \(attributes.companionName)")
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.16)))
    }
}

struct MochiLockScreenBackground: View {
    var body: some View {
        LinearGradient(colors: [MochiStyle.backgroundTop, MochiStyle.background], startPoint: .top, endPoint: .bottom)
    }
}

/// The Lock Screen (and StandBy) banner.
struct MochiLockScreenView: View {
    let attributes: MochiActivityAttributes
    let state: MochiActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            PhaseArt(kind: .scene, phase: state.art, frame: state.frame, height: 76)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.shownTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail = state.shownDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                StatusChip(attributes: attributes, state: state)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 12)
    }
}
