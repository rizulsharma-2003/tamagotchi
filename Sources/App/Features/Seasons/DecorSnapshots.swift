import AppKit
import SwiftUI
import TamagotchiCore

/// Development tool: renders every holiday in every theme, the menu-bar accents, the seasonal
/// treats and a furnished room offscreen, from the app's own drawing code (part of `--render-snapshots`).
@MainActor
enum DecorSnapshots {
    static func render(to directory: URL) {
        let state = SeasonState.shared
        let saved = state.override
        defer {
            state.override = saved
            SeasonalTreats.style = .cookie
        }
        for event in SeasonalEvent.allCases where event != .mochiBirthday {
            state.override = .event(event)
            renderSeason(event, to: directory.appendingPathComponent("season-\(event.rawValue).png"))
            renderDetail(to: directory.appendingPathComponent("season-\(event.rawValue)-detail.png"))
        }
        state.override = .off
        renderAccents(to: directory.appendingPathComponent("season-accents.png"))
        renderTreats(to: directory.appendingPathComponent("season-treats.png"))
        renderTreatStory(to: directory.appendingPathComponent("season-treat-story.png"))
        renderRooms(to: directory.appendingPathComponent("room-furnished.png"))
        renderCatalog(to: directory.appendingPathComponent("room-catalog.png"))
        renderPhoto(to: directory.appendingPathComponent("room-photo.png"))
    }

    /// A world with the companion at its desk, as the popover usually shows it.
    static func world(theme: OfficeTheme, room: RoomLayout = RoomLayout()) -> CompanionWorld {
        let (world, tick, _) = SnapshotRenderer.makeWorld(theme: theme) { settings in
            settings.companionVisibility = .always
            settings.room = room
        }
        tick()
        return world
    }

    static func scene(_ world: CompanionWorld, dark: Bool, time: Double, reduced: Bool = false) -> some View {
        Canvas { context, size in
            // Snapshot right before drawing: the snapshot records this world's theme for the decorations.
            var snapshot = SceneSnapshot(world: world)
            snapshot.reducedMotion = reduced
            SeasonRenderContext.reducedMotion = reduced
            SceneRenderer.draw(snapshot, layout: .popover(width: size.width, height: size.height), in: context, time: time,
                               dark: dark, hour: dark ? 22 : 14)
        }
        .frame(width: 360, height: 178)
        .clipped()
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    static func renderSeason(_ event: SeasonalEvent, to url: URL) {
        let view = VStack(spacing: 6) {
            ForEach(OfficeTheme.allCases) { theme in
                HStack(spacing: 6) {
                    ForEach([false, true], id: \.self) { dark in
                        scene(world(theme: theme), dark: dark, time: 101.3 + (dark ? 2.2 : 0))
                    }
                }
            }
            HStack(spacing: 6) {
                scene(world(theme: .cozyDesk), dark: false, time: 107.9, reduced: true)
                scene(world(theme: .cozyDesk), dark: true, time: 104.6)
            }
            SnapshotRenderer.label("\(event.title) — 4 themes, light/dark; bottom: Reduced Motion, another moment")
        }
        .padding(6)
        .background(Color(hex: 0x888888))
        SnapshotRenderer.write(view, to: url, scale: 1.5)
    }

    /// The cozy room up close, light and dark, to check the details.
    static func renderDetail(to url: URL) {
        let view = HStack(spacing: 4) {
            scene(world(theme: .cozyDesk), dark: false, time: 101.3)
            scene(world(theme: .cozyDesk), dark: true, time: 103.5)
        }
        SnapshotRenderer.write(view, to: url, scale: 3)
    }

    /// The "cookie catch" treat story with each seasonal treat: falling, then held in the mouth.
    static func renderTreatStory(to url: URL) {
        let styles: [SeasonalTreats.Style] = [.cookie, .candy, .laddoo, .gingerbread, .cakeSlice, .heartCookie]
        let view = HStack(spacing: 4) {
            ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                VStack(spacing: 0) {
                    ForEach([0.7, 1.3], id: \.self) { t in
                        Canvas { context, size in
                            SeasonalTreats.style = style
                            var pose = PetPoseEvaluator.pose(.treat, elapsed: t, context: PoseContext(time: 50 + t), variant: 0)
                            pose.x = 0
                            PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 6), scale: 1.1,
                                             palette: PetPalette(.cream), accessory: nil, dark: false)
                            SeasonalTreats.style = .cookie
                        }
                        .frame(width: 96, height: 96)
                    }
                    SnapshotRenderer.label("\(style)")
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0xFBF4EC))
        SnapshotRenderer.write(view, to: url, scale: 2)
    }

    static func renderAccents(to url: URL) {
        let view = VStack(spacing: 4) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 10) {
                    ForEach(SeasonalEvent.allCases) { event in
                        Canvas { context, size in
                            let point = CGPoint(x: size.width / 2 - 8, y: size.height - 4)
                            MenuBarPetCanvas.drawBed(in: context, center: point, scale: 1, dark: dark)
                            SeasonArt.menuBarAccent(event, in: context, at: CGPoint(x: point.x + 15.5, y: point.y), scale: 1, dark: dark)
                        }
                        .frame(width: 60, height: 24)
                    }
                }
                .padding(6)
                .background(dark ? Color(hex: 0x2B2B30) : Color(hex: 0xEDEDED))
            }
        }
        SnapshotRenderer.write(view, to: url, scale: 4)
    }

    static func renderTreats(to url: URL) {
        let styles: [SeasonalTreats.Style] = [.cookie, .candy, .laddoo, .gingerbread, .cakeSlice, .heartCookie]
        let view = HStack(spacing: 8) {
            ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                VStack(spacing: 2) {
                    Canvas { context, size in
                        var g = context
                        g.translateBy(x: size.width / 2, y: size.height / 2)
                        SeasonalTreats.draw(style, in: g, size: 30, spin: 0.4)
                    }
                    .frame(width: 44, height: 44)
                    Canvas { context, size in
                        var g = context
                        g.translateBy(x: size.width / 2, y: size.height / 2)
                        SeasonalTreats.draw(style, in: g, size: 11, spin: 1.2)
                    }
                    .frame(width: 44, height: 18)
                    SnapshotRenderer.label("\(style)")
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xFBF4EC))
        SnapshotRenderer.write(view, to: url, scale: 3)
    }

    /// Every theme, light and dark, with a typical arrangement of furniture.
    static func renderRooms(to url: URL) {
        var room = RoomLayout()
        let picks: [(String, Double, Double, Bool)] = [("rug", 0.47, 0.92, false), ("bookshelf", 0.06, 0.87, false), ("plant", 0.15, 0.88, false),
                                                      ("poster", 0.47, 0.34, false), ("clock", 0.57, 0.27, false), ("lamp", 0.95, 0.87, false),
                                                      ("photo", 0.38, 0.3, false), ("fishBowl", 0.87, 0.9, true)]
        for (id, x, y, flipped) in picks {
            if let kind = FurnitureCatalog.kind(id), let item = room.add(kind, x: x, y: y), flipped { room.toggleFlip(item.id) }
        }
        let view = VStack(spacing: 6) {
            ForEach(OfficeTheme.allCases) { theme in
                HStack(spacing: 6) {
                    ForEach([false, true], id: \.self) { dark in
                        scene(world(theme: theme, room: room), dark: dark, time: 103.1)
                    }
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0x888888))
        SnapshotRenderer.write(view, to: url, scale: 1.5)
    }

    /// The framed photo up close.
    static func renderPhoto(to url: URL) {
        let view = Canvas { context, size in
            var g = context
            g.translateBy(x: size.width / 2, y: size.height / 2)
            g.scaleBy(x: 5, y: 5)
            FurnitureArt.draw("photo", in: g, dark: false, time: 1)
        }
        .frame(width: 200, height: 160)
        .background(Color(hex: 0xFCF1E5))
        SnapshotRenderer.write(view, to: url, scale: 2)
    }

    /// Each piece on its own, light and dark.
    static func renderCatalog(to url: URL) {
        let view = VStack(spacing: 6) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 4) {
                    ForEach(FurnitureCatalog.all) { kind in
                        VStack(spacing: 2) {
                            Canvas { context, size in
                                let layout = SceneLayout.popover(width: 360, height: 178)
                                let item = PlacedFurniture(kind: kind.id, x: 0, y: kind.defaultY)
                                var g = context
                                let anchor = RoomSpace(layout: layout).anchor(for: item, kind: kind)
                                let frame = RoomSpace(layout: layout).frame(for: item, kind: kind)
                                g.translateBy(x: size.width / 2 - frame.midX, y: size.height - 6 - frame.maxY)
                                _ = anchor
                                RoomDecor.drawPiece(item, kind: kind, in: g, layout: layout, dark: dark, time: 100.7)
                            }
                            .frame(width: 70, height: 110)
                            .background(dark ? Color(hex: 0x2E2523) : Color(hex: 0xFCF1E5))
                            SnapshotRenderer.label(kind.title).lineLimit(1).frame(width: 70)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0x888888))
        SnapshotRenderer.write(view, to: url, scale: 2)
    }
}
