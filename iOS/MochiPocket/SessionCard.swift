import SwiftUI
import TamagotchiCore

/// One Claude session on the Mac: what it's doing, Claude's summary of its last turn and the files
/// it changed, with a reply that goes to that session.
struct SessionCard: View {
    let card: PhoneSessionCard
    let send: (String) -> Void
    @State private var replying = false
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) {
                    IconTile(symbol: symbol, tint: tint)
                    Text(card.project).font(.mochi(.headline)).foregroundStyle(Theme.ink).fixedSize()
                    Spacer(minLength: Theme.Space.xs)
                    Tag(text: label, tint: tint).fixedSize()
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        IconTile(symbol: symbol, tint: tint)
                        Text(card.project).font(.mochi(.headline)).foregroundStyle(Theme.ink).lineLimit(2)
                    }
                    Tag(text: label, tint: tint)
                }
            }
            if let summary = card.summary {
                Text(summary.done).font(.mochi(.subheadline)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let session = summary.session, !session.isEmpty {
                    Label(session, systemImage: "text.alignleft")
                        .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                }
                if !card.files.isEmpty { files }
                if let finished = card.finishedAt {
                    Text("Finished \(Date(timeIntervalSince1970: finished).formatted(.relative(presentation: .named)))")
                        .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                }
            } else {
                Text(card.phase == "working" ? "Claude is working — a summary comes when it finishes."
                                             : "A summary comes when Claude finishes its next turn.")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
            }
            if replying {
                replyField
            } else {
                HStack(spacing: Theme.Space.s) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(card.summary?.next ?? [], id: \.self) { suggestion in
                                Button {
                                    text = suggestion
                                    startReplying()
                                } label: {
                                    Text(suggestion)
                                        .font(.mochi(.footnote, .semibold))
                                        .foregroundStyle(Theme.tint)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 34)
                                        .background(Capsule().fill(Theme.sunken))
                                        .frame(minHeight: Theme.touch)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(ClayPressStyle())
                                .accessibilityHint("Starts a reply with this")
                            }
                        }
                    }
                    Button { startReplying() } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.mochi(.subheadline, .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
        }
        .mochiCard()
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: replying)
    }

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(card.files, id: \.self) { file in
                    Label(file, systemImage: "doc.text")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.sunken))
                }
            }
        }
        .accessibilityLabel("Changed files: \(card.files.joined(separator: ", "))")
    }

    private var replyField: some View {
        HStack(spacing: Theme.Space.xs) {
            TextField("Tell Claude what to do next", text: $text, axis: .vertical)
                .font(.mochi(.body))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(.leading, Theme.Space.m)
            Button(action: submit) {
                Image(systemName: "paperplane.fill").font(.mochi(.body, .semibold))
                    .frame(width: Theme.touch, height: Theme.touch)
                    .contentShape(Rectangle())
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send to Claude")
            Button {
                replying = false
                text = ""
            } label: {
                Image(systemName: "xmark").font(.mochi(.footnote, .bold))
                    .frame(width: Theme.touch, height: Theme.touch)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityLabel("Cancel reply")
        }
        .frame(minHeight: Theme.touch)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).fill(Theme.sunken))
    }

    private func startReplying() {
        replying = true
        focused = true
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        send(words)
        text = ""
        replying = false
        focused = false
    }

    private var label: String {
        switch card.phase {
        case "working": return "Working"
        case "waiting": return "Needs you"
        case "done": return "Finished"
        case "error": return "Hit a snag"
        default: return "Idle"
        }
    }

    private var symbol: String {
        switch card.phase {
        case "working": return "gearshape.2.fill"
        case "waiting": return "hand.raised.fill"
        case "done": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "moon.zzz.fill"
        }
    }

    private var tint: Color {
        switch card.phase {
        case "working": return Theme.tint
        case "waiting": return Theme.warning
        case "done": return Theme.success
        case "error": return Theme.danger
        default: return Theme.inkSecondary
        }
    }
}
