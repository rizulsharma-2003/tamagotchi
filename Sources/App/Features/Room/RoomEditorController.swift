import AppKit
import Observation
import SwiftUI
import TamagotchiCore

/// Room makeover: furniture the user unlocks and places by dragging in the popover scene.
@MainActor
@Observable
final class RoomEditorController {
    @ObservationIgnored private unowned let environment: AppEnvironment
    var isEditing = false
    /// The piece showing its flip and remove controls.
    var selection: UUID?
    /// The piece being dragged, from the tray or around the room.
    var drag: RoomDrag?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Debug requests: "room:edit", "room:done", "room:demo" (a furnished room), "room:clear",
    /// "room:select:<index>", "room:drag:<index>" (lifts a piece as if mid-drag, to check the overlay).
    func start() {
        environment.debug.register("room") { [weak self] argument in
            guard let self else { return }
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first {
            case "edit": self.beginEditing(openPopover: false)
            case "done": self.endEditing()
            case "clear": self.clear()
            case "demo":
                var room = RoomLayout()
                for (id, x, y) in [("rug", 0.47, 0.92), ("bookshelf", 0.06, 0.87), ("plant", 0.16, 0.89), ("poster", 0.6, 0.3),
                                   ("clock", 0.47, 0.3), ("lamp", 0.95, 0.87), ("photo", 0.37, 0.36), ("fishBowl", 0.87, 0.9)] {
                    if let kind = FurnitureCatalog.kind(id) { room.add(kind, x: x, y: y) }
                }
                self.environment.settingsStore.settings.room = room
            case "select":
                let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                self.selection = self.room.items.indices.contains(index) ? self.room.items[index].id : nil
            case "drag":
                let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                guard self.room.items.indices.contains(index), let kind = FurnitureCatalog.kind(self.room.items[index].kind) else { return }
                let item = self.room.items[index]
                let space = RoomSpace(layout: .popover(width: ShareClipController.sceneSize.width, height: ShareClipController.sceneSize.height))
                var anchor = space.anchor(for: item, kind: kind)
                anchor.x = min(anchor.x + 40, space.width - 30)
                self.lift(item, kind: kind, anchor: space.snapped(anchor, kind: kind).anchor, grabOffset: .zero)
            default: break
            }
        }
        environment.debug.registerState("room") { [weak self] in
            guard let self else { return [:] }
            return ["editing": self.isEditing, "items": self.room.items.map { "\($0.kind)@\(String(format: "%.2f,%.2f", $0.x, $0.y))" },
                    "selection": self.selection?.uuidString ?? "none", "dragging": self.drag?.kind.id ?? "none"]
        }
    }

    func toggleEditing() { isEditing ? endEditing() : beginEditing(openPopover: false) }

    /// Starts decorating, opening the popover first when asked from the menu or Settings.
    func beginEditing(openPopover: Bool = true) {
        if openPopover, !environment.ui.popoverVisible { environment.statusItem.showPopover() }
        guard !isEditing else { return }
        isEditing = true
        observePopover()
    }

    func endEditing() {
        isEditing = false
        selection = nil
        drag = nil
        RoomDecor.liftedID = nil
    }

    var room: RoomLayout { environment.settingsStore.settings.room }
    var progress: ProgressState { environment.world.progress }

    // MARK: Arranging

    /// Adds a piece at `position` (normalized), or at a free spot near its usual place.
    @discardableResult
    func add(_ kind: FurnitureKind, at position: (x: Double, y: Double)? = nil) -> PlacedFurniture? {
        guard kind.isUnlocked(progress) else { return nil }
        var room = room
        guard let placed = room.add(kind, x: position?.x, y: position?.y) else { return nil }
        environment.settingsStore.settings.room = room
        selection = placed.id
        return placed
    }

    func move(_ id: UUID, to position: (x: Double, y: Double)) {
        var room = room
        room.move(id, x: position.x, y: position.y)
        environment.settingsStore.settings.room = room
    }

    func flip(_ id: UUID) {
        environment.settingsStore.settings.room.toggleFlip(id)
    }

    func remove(_ id: UUID) {
        environment.settingsStore.settings.room.remove(id)
        if selection == id { selection = nil }
    }

    func clear() {
        environment.settingsStore.settings.room = RoomLayout()
        selection = nil
    }

    // MARK: Dragging

    /// Lifts a placed piece out of the scene so the overlay can carry it.
    func lift(_ item: PlacedFurniture, kind: FurnitureKind, anchor: CGPoint, grabOffset: CGSize) {
        selection = item.id
        RoomDecor.liftedID = item.id
        drag = RoomDrag(kind: kind, existing: item.id, flipped: item.flipped, grabOffset: grabOffset, anchor: anchor, overTray: false)
    }

    /// Drops the dragged piece: a new one is added, a placed one moved, and anything dropped back on
    /// the tray is put away.
    func drop(at position: (x: Double, y: Double)) {
        guard let drag else { return }
        defer {
            self.drag = nil
            RoomDecor.liftedID = nil
        }
        if let id = drag.existing {
            if drag.overTray { remove(id) } else { move(id, to: position) }
        } else if !drag.overTray {
            add(drag.kind, at: position)
        }
    }

    private func observePopover() {
        withObservationTracking {
            _ = environment.ui.popoverVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isEditing else { return }
                if !self.environment.ui.popoverVisible { self.endEditing() } else { self.observePopover() }
            }
        }
    }
}

/// A piece of furniture following the pointer.
struct RoomDrag: Equatable {
    var kind: FurnitureKind
    /// The placed piece being moved (nil for a new one from the tray).
    var existing: UUID?
    var flipped: Bool
    /// Anchor minus pointer, so the piece doesn't jump to the pointer.
    var grabOffset: CGSize
    /// Where the piece would land, already snapped to its band (scene points).
    var anchor: CGPoint
    /// Over the tray: a new piece is cancelled, a placed one put away.
    var overTray: Bool
}

/// A piece of furniture drawn to fit a small square (tray, settings).
struct FurnitureIcon: View {
    let kind: FurnitureKind
    var dark = false

    var body: some View {
        Canvas { context, size in
            let k = min((size.width - 2) / kind.width, (size.height - 2) / kind.height)
            var g = context
            let standing = kind.placement == .floor && !kind.isFlat
            g.translateBy(x: size.width / 2, y: standing ? size.height / 2 + kind.height * k / 2 : size.height / 2)
            g.scaleBy(x: k, y: k)
            FurnitureArt.draw(kind.id, in: g, dark: dark, time: 1.2)
        }
    }
}

/// Drag handles and the furniture tray over the popover scene while editing.
struct RoomEditorOverlay: View {
    let environment: AppEnvironment

    var body: some View {
        if environment.roomEditor.isEditing {
            RoomEditorView(environment: environment)
        }
    }
}

private struct RoomEditorView: View {
    let environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    private var editor: RoomEditorController { environment.roomEditor }
    private static let trayBottom: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let space = RoomSpace(layout: .popover(width: geometry.size.width, height: geometry.size.height))
            let room = environment.settingsStore.settings.room
            ZStack(alignment: .topLeading) {
                // Clicks on empty space deselect, and nobody gets petted while decorating.
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { editor.selection = nil }
                if let drag = editor.drag {
                    band(for: drag.kind, space: space)
                }
                ForEach(room.drawingOrder) { item in
                    if let kind = FurnitureCatalog.kind(item.kind) {
                        handle(item, kind: kind, space: space)
                    }
                }
                if editor.drag == nil, let id = editor.selection, let item = room.items.first(where: { $0.id == id }),
                   let kind = FurnitureCatalog.kind(item.kind) {
                    selectionChrome(item, kind: kind, space: space)
                }
                if let drag = editor.drag {
                    lifted(drag, space: space)
                }
                tray(room: room, space: space)
                    .frame(width: geometry.size.width)
                    .padding(.top, 5)
            }
            .coordinateSpace(.named("room"))
        }
    }

    // MARK: Pieces in the room

    private func handle(_ item: PlacedFurniture, kind: FurnitureKind, space: RoomSpace) -> some View {
        let frame = space.frame(for: item, kind: kind)
        return Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .frame(width: max(frame.width, 18), height: max(frame.height, 14))
            .onTapGesture { editor.selection = item.id }
            .gesture(moveGesture(item, kind: kind, space: space))
            .help("\(kind.title) — drag to move")
            .accessibilityElement()
            .accessibilityLabel(kind.title)
            .accessibilityAddTraits(.isButton)
            .position(x: frame.midX, y: frame.midY)
    }

    private func moveGesture(_ item: PlacedFurniture, kind: FurnitureKind, space: RoomSpace) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("room"))
            .onChanged { value in
                if editor.drag?.existing != item.id {
                    let anchor = space.anchor(for: item, kind: kind)
                    editor.lift(item, kind: kind, anchor: anchor,
                                grabOffset: CGSize(width: anchor.x - value.startLocation.x, height: anchor.y - value.startLocation.y))
                }
                follow(value.location, space: space)
            }
            .onEnded { value in
                follow(value.location, space: space)
                commit(space: space)
            }
    }

    private func follow(_ pointer: CGPoint, space: RoomSpace) {
        guard var drag = editor.drag else { return }
        let raw = CGPoint(x: pointer.x + drag.grabOffset.width, y: pointer.y + drag.grabOffset.height)
        drag.anchor = space.snapped(raw, kind: drag.kind).anchor
        drag.overTray = pointer.y < Self.trayBottom
        editor.drag = drag
    }

    private func commit(space: RoomSpace) {
        guard let drag = editor.drag else { return }
        editor.drop(at: space.position(anchor: drag.anchor, kind: drag.kind))
    }

    private func band(for kind: FurnitureKind, space: RoomSpace) -> some View {
        let rect: CGRect
        switch kind.placement {
        case .wall:
            rect = CGRect(x: 4, y: space.height * RoomLayout.wallBand.lowerBound - 14, width: space.width - 8,
                          height: space.height * (RoomLayout.wallBand.upperBound - RoomLayout.wallBand.lowerBound) + 28)
        case .floor:
            rect = CGRect(x: 4, y: space.layout.ground - 3, width: space.width - 8, height: space.height - space.layout.ground + 1)
        }
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func selectionChrome(_ item: PlacedFurniture, kind: FurnitureKind, space: RoomSpace) -> some View {
        let frame = space.frame(for: item, kind: kind).insetBy(dx: -3, dy: -3)
        let above = frame.minY > Self.trayBottom + 22
        let controls = CGPoint(x: min(max(frame.midX, 30), space.width - 30), y: above ? frame.minY - 11 : min(frame.maxY + 11, space.height - 11))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            HStack(spacing: 2) {
                Button { editor.flip(item.id) } label: {
                    Image(systemName: "arrow.left.and.right").font(.system(size: 8.5, weight: .bold)).frame(width: 18, height: 16)
                }
                .help("Flip")
                .accessibilityLabel("Flip \(kind.title)")
                Button { editor.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 18, height: 16)
                }
                .help("Put away")
                .accessibilityLabel("Remove \(kind.title)")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
            .position(x: controls.x, y: controls.y)
        }
    }

    /// The carried piece, drawn above everything until it's dropped.
    private func lifted(_ drag: RoomDrag, space: RoomSpace) -> some View {
        let dark = colorScheme == .dark
        return Canvas { context, _ in
            let position = space.position(anchor: drag.anchor, kind: drag.kind)
            let item = PlacedFurniture(kind: drag.kind.id, x: position.x, y: position.y, flipped: drag.flipped)
            RoomDecor.drawPiece(item, kind: drag.kind, in: context, layout: space.layout, dark: dark, time: ProcessInfo.processInfo.systemUptime)
        }
        .opacity(drag.overTray ? 0.35 : 0.92)
        .allowsHitTesting(false)
    }

    // MARK: Tray

    private func tray(room: RoomLayout, space: RoomSpace) -> some View {
        HStack(spacing: 1) {
            ForEach(FurnitureCatalog.all) { kind in
                trayItem(kind, room: room, space: space)
            }
            Divider().frame(height: 16).padding(.horizontal, 2)
            Text("\(room.items.count)/\(RoomLayout.maxItems)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Up to \(RoomLayout.maxItems) pieces fit in the room")
            Button("Done") { editor.endEditing() }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .padding(.leading, 3)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(.thickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    @ViewBuilder
    private func trayItem(_ kind: FurnitureKind, room: RoomLayout, space: RoomSpace) -> some View {
        let unlocked = kind.isUnlocked(editor.progress)
        let available = unlocked && !room.isFull
        let help = !unlocked ? "\(kind.title) — \(kind.unlockHint)"
            : room.isFull ? "\(kind.title) — the room is full; put something away first"
            : "\(kind.title) — drag into the room, or click to add"
        FurnitureIcon(kind: kind, dark: colorScheme == .dark)
            .frame(width: 20, height: 20)
            .saturation(unlocked ? 1 : 0)
            .opacity(available ? 1 : (unlocked ? 0.45 : 0.3))
            .overlay(alignment: .bottomTrailing) {
                if !unlocked {
                    Image(systemName: "lock.fill").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if available { editor.add(kind) } }
            .gesture(trayGesture(kind, space: space), including: available ? .all : .none)
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(kind.title)
            .accessibilityHint(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if available { editor.add(kind) } }
    }

    private func trayGesture(_ kind: FurnitureKind, space: RoomSpace) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("room"))
            .onChanged { value in
                if editor.drag == nil {
                    // A new piece, held by its middle.
                    editor.selection = nil
                    let hold = space.anchor(holding: kind, at: value.location)
                    editor.drag = RoomDrag(kind: kind, existing: nil, flipped: false,
                                           grabOffset: CGSize(width: hold.x - value.location.x, height: hold.y - value.location.y),
                                           anchor: hold, overTray: true)
                }
                follow(value.location, space: space)
            }
            .onEnded { value in
                follow(value.location, space: space)
                if !CGRect(origin: .zero, size: space.layout.size).contains(value.location) { editor.drag?.overTray = true }
                commit(space: space)
            }
    }
}

struct RoomSettingsSection: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        let room = store.settings.room
        let unlocked = FurnitureCatalog.unlocked(environment.world.progress).count
        Section("Room") {
            if room.items.isEmpty {
                Text("Nothing placed yet. Click Decorate in the panel and drag furniture into the room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(room.items) { item in
                if let kind = FurnitureCatalog.kind(item.kind) {
                    HStack(spacing: 8) {
                        FurnitureIcon(kind: kind).frame(width: 20, height: 20)
                        Text(kind.title)
                        Spacer()
                        Button {
                            environment.roomEditor.remove(item.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Put away")
                        .accessibilityLabel("Remove \(kind.title)")
                    }
                }
            }
            HStack {
                Text("\(unlocked) of \(FurnitureCatalog.all.count) pieces unlocked · \(room.items.count) of \(RoomLayout.maxItems) placed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Decorate…") { environment.roomEditor.beginEditing() }
                Button("Clear Room") { environment.roomEditor.clear() }
                    .disabled(room.items.isEmpty)
            }
        }
    }
}
