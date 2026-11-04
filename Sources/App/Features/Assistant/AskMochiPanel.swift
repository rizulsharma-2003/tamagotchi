import AppKit
import SwiftUI
import TamagotchiCore

/// The Ask Mochi command bar: a floating panel near the top of the screen that grows downward
/// as steps, an approval card or the answer appear.
@MainActor
final class AskMochiPanel: NSPanel {
    private unowned let controller: AssistantController
    static let width: CGFloat = 620

    init(controller: AssistantController, environment: AppEnvironment) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 86), styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: AskMochiView(controller: controller, environment: environment) { [weak self] size in
            self?.fit(size)
        })
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { controller.escape() }

    func present() {
        if !isVisible {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                setFrameTopLeftPoint(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - visible.height * 0.16))
            }
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Keeps the top edge in place while the content grows or shrinks.
    private func fit(_ size: CGSize) {
        let height = ceil(size.height)
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        var newFrame = frame
        newFrame.origin.y += frame.height - height
        newFrame.size.height = height
        setFrame(newFrame, display: true, animate: false)
    }
}

struct AskMochiView: View {
    @Bindable var controller: AssistantController
    let environment: AppEnvironment
    var onSize: (CGSize) -> Void = { _ in }
    @FocusState private var fieldFocused: Bool

    private var settings: AppSettings { environment.settingsStore.settings }
    private var phase: AssistantController.Phase { controller.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                MochiFace(phase: phase, since: controller.phaseChangedAt, color: settings.petColor, accessory: settings.petAccessory,
                          reducedMotion: environment.world.reducedMotion)
                    .frame(width: 58, height: 50)
                inputArea
                if settings.assistant.shortcut != .off {
                    Text(settings.assistant.shortcut.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 10)

            if hasDetail {
                Divider().opacity(0.5)
                details.padding(.horizontal, 18).padding(.vertical, 14)
            }
            Divider().opacity(0.35)
            footer.padding(.horizontal, 18).padding(.vertical, 8)
        }
        .frame(width: AskMochiPanel.width)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size, initial: true) { _, size in onSize(size) }
        })
        .onChange(of: controller.focusRequest, initial: true) { _, _ in fieldFocused = true }
        .animation(.spring(duration: 0.28), value: controller.steps)
        .animation(.spring(duration: 0.28), value: controller.approval)
        .animation(.spring(duration: 0.28), value: controller.reply)
    }

    @ViewBuilder private var inputArea: some View {
        if phase == .listening {
            HStack(spacing: 8) {
                ListeningBars()
                Text(controller.transcript.isEmpty ? "Listening…" : controller.transcript)
                    .font(.system(size: 20, design: .rounded))
                    .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            TextField("", text: $controller.draft, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 20, design: .rounded))
                .focused($fieldFocused)
                .onSubmit { controller.submit() }
                .frame(maxWidth: .infinity)
        }
    }

    private var placeholder: String {
        switch phase {
        case .approving: return "Press Return to send, or Esc to cancel"
        case .working: return "Working on it… (Esc to stop)"
        default: return "Ask \(controller.petName) anything…"
        }
    }

    private var hasDetail: Bool {
        (controller.request != nil && phase != .idle && phase != .listening) || !controller.steps.isEmpty
            || controller.approval != nil || controller.reply != nil
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let request = controller.request, phase != .idle, phase != .listening {
                Text("“\(request)”")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(controller.steps) { step in StepRow(step: step) }
            if let approval = controller.approval {
                ApprovalCard(approval: approval, petName: controller.petName,
                             send: { controller.approve() }, cancel: { controller.decline() })
            }
            if let reply = controller.reply, phase == .done || phase == .failed || phase == .idle {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: phase == .failed ? "exclamationmark.bubble.fill" : "pawprint.fill")
                        .foregroundStyle(phase == .failed ? Color.orange : Color.accentColor)
                    Text(reply)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("return", "Ask")
            hint("esc", phase == .working ? "Stop" : phase == .approving || phase == .listening ? "Cancel" : "Close")
            if settings.assistant.voice, settings.assistant.shortcut != .off {
                hint(settings.assistant.shortcut.title, "Hold to talk")
            }
            Spacer()
            Text("Uses your Claude Code · \(settings.assistant.model == .fast ? "Haiku" : "Sonnet")")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label).font(.system(size: 11, design: .rounded))
        }
        .foregroundStyle(.secondary)
    }
}

private struct StepRow: View {
    let step: AssistantController.Step

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.small).scaleEffect(0.75)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 16, height: 16)
            Image(systemName: step.symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(step.text).font(.system(size: 13.5, design: .rounded)).lineLimit(1)
        }
    }
}

private struct ApprovalCard: View {
    let approval: AssistantController.Approval
    let petName: String
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "paperplane.fill").foregroundStyle(Color.accentColor)
                Text("Send to Claude").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(approval.project.map { "\($0.displayName) · \(approval.target)" } ?? approval.target)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(approval.message)
                .font(.system(size: 14, design: .rounded))
                .lineLimit(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 10) {
                Text("It arrives as “Message from @\(BrainLaunch.sessionName)”. Your permission prompts still apply there.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
                Button("Send", action: send).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22)))
    }
}

/// Little bars that bounce while Mochi listens.
private struct ListeningBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3.5, height: 6 + 12 * abs(sin(t * 7 + Double(index) * 0.9)))
                }
            }
            .frame(width: 22, height: 20)
        }
    }
}

/// Mochi in the command bar: listening ears, a curious look while working, a hop when done.
struct MochiFace: View {
    let phase: AssistantController.Phase
    let since: Date
    let color: PetColor
    let accessory: Accessory?
    let reducedMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reducedMotion)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                let t = now.timeIntervalSinceReferenceDate
                let elapsed = max(0, now.timeIntervalSince(since))
                let poseContext = PoseContext(time: t, reducedMotion: reducedMotion, intensity: .normal, seed: 11)
                let pose = Self.pose(phase: phase, t: t, elapsed: elapsed, context: poseContext)
                PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 2), scale: 0.62,
                                 palette: PetPalette(color), accessory: accessory, dark: false)
            }
        }
    }

    static func pose(phase: AssistantController.Phase, t: Double, elapsed: Double, context: PoseContext) -> PetPose {
        var pose = PetPoseEvaluator.pose(.idle, elapsed: t, context: context)
        switch phase {
        case .idle:
            pose.earPerk = 0.35
        case .listening:
            pose.earPerk = 1
            pose.eyes = .wide
            pose.mouth = .o
            pose.lookX = 0
        case .working:
            pose = PetPoseEvaluator.pose(.lookAround, elapsed: elapsed.truncatingRemainder(dividingBy: 2.6), context: context)
            pose.earPerk = 0.8
        case .approving:
            pose.earPerk = 0.9
            pose.lookX = 0.55
            pose.brows = .raised
            pose.rightArm = 0.5
        case .done:
            if elapsed < 1 {
                pose = PetPoseEvaluator.pose(.happyBounce, elapsed: elapsed, duration: 1, context: context)
            } else {
                pose.eyes = .happy
                pose.mouth = .smile
                pose.blush = 0.8
            }
        case .failed:
            pose = PetPoseEvaluator.pose(.concerned, elapsed: min(elapsed, 2.2), context: context)
        }
        return pose
    }
}

/// Development: renders the command bar in each state to PNGs next to the debug files.
@MainActor
enum AskMochiSnapshots {
    struct State {
        var name: String
        var phase: AssistantController.Phase
        var request: String?
        var steps: [AssistantController.Step]
        var approval: AssistantController.Approval?
        var reply: String?
        var transcript = ""
    }

    static func states() -> [State] {
        typealias Step = AssistantController.Step
        let project = ProjectRef(displayName: "mac-Tamagotchi", key: "0", path: nil)
        let ask = "tell the tamagotchi claude to make the animations smoother"
        return [
            State(name: "idle", phase: .idle, request: nil, steps: [], approval: nil, reply: nil),
            State(name: "listening", phase: .listening, request: nil, steps: [], approval: nil, reply: nil,
                  transcript: "tell the tamagotchi claude to make the animations"),
            State(name: "working", phase: .working, request: "open youtube and play lofi beats", steps: [
                Step(id: "1", symbol: "magnifyingglass", text: "Searching the web for “lofi beats youtube”", state: .done),
                Step(id: "2", symbol: "safari", text: "Opening www.youtube.com", state: .running),
            ], approval: nil, reply: nil),
            State(name: "approving", phase: .approving, request: ask, steps: [
                Step(id: "1", symbol: "person.2", text: "Looking for your Claude sessions", state: .done),
                Step(id: "2", symbol: "paperplane", text: "Asking to send to mac-tamagotchi-bb", state: .running),
            ], approval: AssistantController.Approval(target: "mac-tamagotchi-bb", project: project,
                                                      message: "From the user, via Mochi: make the animations smoother."), reply: nil),
            State(name: "done", phase: .done, request: ask, steps: [
                Step(id: "1", symbol: "person.2", text: "Looking for your Claude sessions", state: .done),
                Step(id: "2", symbol: "paperplane", text: "Sent to mac-tamagotchi-bb", state: .done),
            ], approval: nil, reply: "Sent! Claude in mac-Tamagotchi is on it — I'll tell you when it's done."),
        ]
    }

    static func render(controller: AssistantController, environment: AppEnvironment) {
        for state in states() {
            let (name, phase, request, steps, approval, reply, transcript) =
                (state.name, state.phase, state.request, state.steps, state.approval, state.reply, state.transcript)
            controller.previewState(phase: phase, request: request, steps: steps, approval: approval, reply: reply, transcript: transcript)
            let view = AskMochiView(controller: controller, environment: environment)
                .padding(24)
                .background(Color(white: 0.88))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: environment.paths.home.appendingPathComponent("debug-ask-\(name).png"))
            }
        }
        controller.previewState(phase: .idle, request: nil, steps: [], approval: nil, reply: nil)
    }
}
