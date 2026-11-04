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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(card.project).font(.system(.headline, design: .rounded)).lineLimit(1)
                Spacer(minLength: 4)
                Text(label)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(tint.opacity(0.13)))
            }
            if let summary = card.summary {
                Text(summary.done).font(.system(.subheadline, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                if let session = summary.session, !session.isEmpty {
                    Label(session, systemImage: "text.alignleft")
                        .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
                }
                if !card.files.isEmpty { files }
                if let finished = card.finishedAt {
                    Text("Finished \(Date(timeIntervalSince1970: finished).formatted(.relative(presentation: .named)))")
                        .font(.system(.caption2, design: .rounded)).foregroundStyle(.tertiary)
                }
            } else {
                Text(card.phase == "working" ? "Claude is working — a summary comes when it finishes."
                                             : "A summary comes when Claude finishes its next turn.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
            }
            if replying {
                replyField
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(card.summary?.next ?? [], id: \.self) { suggestion in
                                Button(suggestion) {
                                    text = suggestion
                                    startReplying()
                                }
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(MochiStyle.accent.opacity(0.12)))
                                .foregroundStyle(MochiStyle.accent)
                            }
                        }
                    }
                    Button { startReplying() } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.85)))
        .animation(.spring(duration: 0.3), value: replying)
    }

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(card.files, id: \.self) { file in
                    Label(file, systemImage: "doc.text")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.05)))
                }
            }
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Tell Claude what to do next", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .semibold))
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                replying = false
                text = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.04)))
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
        case "working": return MochiStyle.accent
        case "waiting": return .orange
        case "done": return .green
        case "error": return .red
        default: return .gray
        }
    }
}
