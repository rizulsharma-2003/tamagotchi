// The gallery's pages: Mochi, Patch, the room, and the props.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';

import 'tracks.dart';
import 'widgets.dart';

const Color paper = Color(0xFFFBF4EC);
const Color night = Color(0xFF2B2A30);

String _title(String name) => name.isEmpty ? name : name[0].toUpperCase() + name.substring(1);

// MARK: - Mochi

class MochiPage extends StatefulWidget {
  const MochiPage({super.key, required this.library});

  final PoseLibrary library;

  @override
  State<MochiPage> createState() => _MochiPageState();
}

class _MochiPageState extends State<MochiPage> {
  int selected = 0;
  PetColor color = PetColor.cream;
  Accessory? accessory;
  LifeStage stage = LifeStage.grownUp;
  bool dark = false;
  bool tiny = false;
  bool faceLeft = false;

  void _drawPet(PetTrack track, GContext g, Size size, double t, {required double scale, double bottom = 10}) {
    var pose = track.at(t);
    if (faceLeft) pose = pose.mirrored();
    final offset = pose.x * bodyWidthsPerPathUnit * PetRenderer.bodyWidth * scale;
    pose.x = 0;
    final saved = PetRenderer.stage;
    PetRenderer.stage = stage;
    final home = Offset(size.width / 2 + offset.clamp(-size.width * 0.35, size.width * 0.35), size.height - bottom);
    PetRenderer.draw(
      pose,
      g,
      home,
      scale,
      PetPalette(color),
      accessory: accessory,
      dark: dark,
      detail: tiny ? RenderDetail.tiny : RenderDetail.standard,
    );
    PetRenderer.stage = saved;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.library.pet;
    final current = tracks[selected];
    final background = dark ? night : paper;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Picker<PetColor>(
                label: 'Coat',
                value: color,
                items: PetColor.values,
                title: (c) => c.title,
                onChanged: (c) => setState(() => color = c),
              ),
              Picker<Accessory?>(
                label: 'Wearing',
                value: accessory,
                items: [null, ...Accessory.values.where((a) => a.slot == AccessorySlot.wearable)],
                title: (a) => a?.title ?? 'Nothing',
                onChanged: (a) => setState(() => accessory = a),
              ),
              Picker<LifeStage>(
                label: 'Stage',
                value: stage,
                items: LifeStage.values,
                title: (s) => s.title,
                onChanged: (s) => setState(() => stage = s),
              ),
              Toggle(label: 'Dark', value: dark, onChanged: (v) => setState(() => dark = v)),
              Toggle(label: 'Menu-bar size', value: tiny, onChanged: (v) => setState(() => tiny = v)),
              Toggle(label: 'Facing left', value: faceLeft, onChanged: (v) => setState(() => faceLeft = v)),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 360,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Tile(
                    label: '${current.title}${current.loop ? ' (loop)' : ''}',
                    background: background,
                    child: ArtCanvas(
                      draw: (g, size, t) {
                        final scale = tiny ? 1.0 : math.min(size.width / 120, size.height / 110);
                        _drawPet(current, g, size, t, scale: scale, bottom: size.height * 0.12);
                      },
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 132,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: tracks.length,
                  itemBuilder: (context, index) => Tile(
                    label: tracks[index].title,
                    selected: index == selected,
                    background: background,
                    onTap: () => setState(() => selected = index),
                    child: ArtCanvas(draw: (g, size, t) => _drawPet(tracks[index], g, size, t, scale: tiny ? 0.5 : 1.05)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// MARK: - Patch

class PatchPage extends StatefulWidget {
  const PatchPage({super.key, required this.library});

  final PoseLibrary library;

  @override
  State<PatchPage> createState() => _PatchPageState();
}

class _PatchPageState extends State<PatchPage> {
  OfficeTheme theme = OfficeTheme.cozyDesk;
  Accessory? accessory;
  Accessory? desk = Accessory.plant;
  bool dark = false;
  bool workstation = true;

  @override
  Widget build(BuildContext context) {
    final tracks = widget.library.companion;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Picker<OfficeTheme>(
                label: 'Desk',
                value: theme,
                items: OfficeTheme.values,
                title: (t) => t.title,
                onChanged: (t) => setState(() => theme = t),
              ),
              Picker<Accessory?>(
                label: 'Wearing',
                value: accessory,
                items: [null, ...Accessory.values.where((a) => a.slot == AccessorySlot.wearable)],
                title: (a) => a?.title ?? 'Nothing',
                onChanged: (a) => setState(() => accessory = a),
              ),
              Picker<Accessory?>(
                label: 'On the desk',
                value: desk,
                items: [null, ...Accessory.values.where((a) => a.slot == AccessorySlot.desk)],
                title: (a) => a?.title ?? 'Nothing',
                onChanged: (a) => setState(() => desk = a),
              ),
              Toggle(label: 'Workstation', value: workstation, onChanged: (v) => setState(() => workstation = v)),
              Toggle(label: 'Dark', value: dark, onChanged: (v) => setState(() => dark = v)),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.15,
            ),
            itemCount: tracks.length,
            itemBuilder: (context, index) => Tile(
              label: tracks[index].title,
              background: dark ? night : paper,
              child: ArtCanvas(
                draw: (g, size, t) {
                  final track = tracks[index];
                  final scale = math.min(size.width / 150, size.height / 118);
                  CompanionRenderer.draw(
                    track.at(t),
                    g,
                    Offset(size.width / 2, size.height - 6),
                    scale,
                    accessory: accessory,
                    dark: dark,
                    time: 10 + track.localTime(t),
                    workstation: workstation,
                    deskFront: (d) => ThemeRenderer.deskFront(theme, d, dark: dark, accessory: desk),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// MARK: - Room

/// The room as the phone shows it (iOS/MochiPocket/RoomView.swift) or as the Mac's popover.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.library});

  final PoseLibrary library;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

enum RoomShape { phone, popover }

class _RoomPageState extends State<RoomPage> {
  RoomShape shape = RoomShape.phone;
  OfficeTheme theme = OfficeTheme.cozyDesk;
  bool dark = false;
  bool nightTime = false;
  bool listening = false;
  SeasonalEvent? season;
  bool furnished = true;
  PetColor color = PetColor.cream;
  InteractionID? interaction;
  PetAnimation petLoop = PetAnimation.idle;
  CompanionAnimation companionLoop = CompanionAnimation.typing;

  /// The arrangement Swift's room snapshots use (DecorSnapshots.renderRooms).
  static RoomLayout furnishedRoom() {
    final room = RoomLayout();
    const picks = [
      ('rug', 0.47, 0.92, false),
      ('bookshelf', 0.06, 0.87, false),
      ('plant', 0.15, 0.88, false),
      ('poster', 0.47, 0.34, false),
      ('clock', 0.57, 0.27, false),
      ('lamp', 0.95, 0.87, false),
      ('photo', 0.38, 0.3, false),
      ('fishBowl', 0.87, 0.9, true),
    ];
    for (final (id, x, y, flipped) in picks) {
      room.add(FurnitureCatalog.kind(id)!, x: x, y: y, flipped: flipped);
    }
    return room;
  }

  late final RoomLayout _furnished = furnishedRoom();

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final petLoops = library.pet.where((t) => t.variant == 0).map((t) => t.animation).toList();
    final companionLoops = library.companion.map((t) => t.animation).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Picker<RoomShape>(
                label: 'Layout',
                value: shape,
                items: RoomShape.values,
                title: (s) => s == RoomShape.phone ? 'Phone' : 'Mac popover',
                onChanged: (s) => setState(() => shape = s),
              ),
              Picker<OfficeTheme>(
                label: 'Theme',
                value: theme,
                items: OfficeTheme.values,
                title: (t) => t.title,
                onChanged: (t) => setState(() => theme = t),
              ),
              Picker<SeasonalEvent?>(
                label: 'Season',
                value: season,
                items: [null, ...SeasonalEvent.values],
                title: (s) => s?.title ?? 'None',
                onChanged: (s) => setState(() => season = s),
              ),
              Picker<PetColor>(
                label: 'Coat',
                value: color,
                items: PetColor.values,
                title: (c) => c.title,
                onChanged: (c) => setState(() => color = c),
              ),
              Toggle(label: 'Furnished', value: furnished, onChanged: (v) => setState(() => furnished = v)),
              Toggle(label: 'Dark', value: dark, onChanged: (v) => setState(() => dark = v)),
              Toggle(label: 'Night', value: nightTime, onChanged: (v) => setState(() => nightTime = v)),
              Toggle(label: 'Hold to talk', value: listening, onChanged: (v) => setState(() => listening = v)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Picker<InteractionID?>(
                label: 'Playing',
                value: interaction,
                items: [null, ...library.interactions.map((t) => t.interaction)],
                title: (i) => i?.title ?? 'Their own loops',
                onChanged: (i) => setState(() => interaction = i),
              ),
              if (interaction == null) ...[
                Picker<PetAnimation>(
                  label: 'Mochi',
                  value: petLoop,
                  items: petLoops,
                  title: (a) => a.title,
                  onChanged: (a) => setState(() => petLoop = a),
                ),
                Picker<CompanionAnimation>(
                  label: 'Patch',
                  value: companionLoop,
                  items: companionLoops,
                  title: (a) => a.title,
                  onChanged: (a) => setState(() => companionLoop = a),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            // Laid out at the device's size in points (a phone's room card, or the Mac popover),
            // then scaled up to fill the window, so the proportions match the real thing.
            child: FittedBox(
              child: SizedBox(
                width: shape == RoomShape.phone ? 390 : 360,
                height: shape == RoomShape.phone ? 320 : 178,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(shape == RoomShape.phone ? 24 : 10),
                  child: ArtCanvas(draw: _drawRoom),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _drawRoom(GContext g, Size size, double t) {
    final library = widget.library;
    final config = SceneConfig(
      theme: theme,
      petColor: color,
      deskAccessory: Accessory.plant,
      room: furnished ? _furnished : RoomLayout(),
      season: season,
    );
    SeasonalTreats.style = TreatStyle.of(season);
    final SceneFrame frame;
    final current = interaction;
    if (current != null) {
      frame = library.interactions.firstWhere((track) => track.interaction == current).at(t);
    } else {
      frame = SceneFrame(pet: library.petTrack(petLoop).at(t), companion: library.companionTrack(companionLoop).at(t));
    }
    final layout = shape == RoomShape.phone ? SceneLayout.phone(size) : SceneLayout.popover(size.width, size.height);
    // Hold to talk (Mochi Pocket): Mochi turns its listening ear towards you and sound arrives.
    final idle = library.petTrack(PetAnimation.idle).at(t);
    SceneRenderer.draw(
      config,
      frame,
      layout,
      g,
      time: 100 + t,
      dark: dark,
      hour: nightTime ? 22 : 14,
      petOverride: listening ? (_) => ListeningPose.pose(idle, elapsed: 1, listening: true, time: 100 + t) : null,
    );
    if (listening) ListeningPose.drawSoundWaves(g, layout, 100 + t, 1);
  }
}

// MARK: - Props

class PropsPage extends StatefulWidget {
  const PropsPage({super.key});

  @override
  State<PropsPage> createState() => _PropsPageState();
}

class _PropsPageState extends State<PropsPage> {
  bool dark = false;

  Widget _section(String title, List<Widget> tiles, {double extent = 110, double aspect = 1}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      GridView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: extent,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: aspect,
        ),
        children: tiles,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final background = dark ? night : paper;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Toggle(label: 'Dark', value: dark, onChanged: (v) => setState(() => dark = v)),
        ),
        _section('Held items', [
          for (final item in HeldItem.values)
            Tile(
              label: _title(item.name),
              background: background,
              child: ArtCanvas(animated: false, draw: (g, size, t) => ItemRenderer.draw(item, g, size.center(Offset.zero), 44)),
            ),
        ]),
        _section('Effects', [
          for (final kind in EffectKind.values)
            if (kind != EffectKind.tangle)
              Tile(
                label: kind.name,
                background: background,
                child: ArtCanvas(
                  draw: (g, size, t) {
                    final effect = Effect(
                      kind,
                      scale: 1.6,
                      phase: (t * 0.6) % 1,
                      rotation: kind == EffectKind.streak ? 0 : t * 1.5 % (2 * math.pi),
                      variant: (t / 2).floor() % 3,
                      x2: kind == EffectKind.yarn ? 0.6 : 0,
                      y2: kind == EffectKind.yarn ? -0.4 : 0,
                    );
                    EffectRenderer.draw(effect, g.copy()..translateBy(size.width / 2, size.height / 2), unitX: 60, unitY: 54, dark: dark);
                  },
                ),
              ),
        ]),
        _section(
          'Furniture',
          [
            for (final kind in FurnitureCatalog.all)
              Tile(
                label: kind.title,
                background: background,
                child: ArtCanvas(
                  draw: (g, size, t) {
                    final centred = kind.placement == FurniturePlacement.wall || kind.isFlat;
                    final k = math.min(1.6, math.min(size.width / (kind.width + 12), (size.height - 8) / (kind.height + 12)));
                    final piece = g.copy()
                      ..translateBy(size.width / 2, centred ? size.height / 2 : size.height - 8)
                      ..scaleBy(k, k);
                    FurnitureArt.draw(kind.id, piece, dark: dark, time: 100 + t);
                  },
                ),
              ),
          ],
          extent: 140,
          aspect: 0.8,
        ),
        _section('Treats', [
          for (final style in TreatStyle.values)
            Tile(
              label: _title(style.name),
              background: background,
              child: ArtCanvas(
                draw: (g, size, t) => SeasonalTreats.drawStyle(style, g.copy()..translateBy(size.width / 2, size.height / 2), 44, t),
              ),
            ),
        ]),
        _section('Desk decorations', [
          for (final accessory in Accessory.values.where((a) => a.slot == AccessorySlot.desk))
            Tile(
              label: accessory.title,
              background: background,
              child: ArtCanvas(
                animated: false,
                draw: (g, size, t) => AccessoryRenderer.desk(
                  accessory,
                  g.copy()
                    ..translateBy(size.width / 2 - 54 * 2.6, size.height - 6 + 22.5 * 2.6)
                    ..scaleBy(2.6, 2.6),
                ),
              ),
            ),
        ]),
        _section('Holiday accents (menu bar)', [
          for (final event in SeasonalEvent.values)
            Tile(
              label: event.title,
              background: background,
              child: ArtCanvas(
                animated: false,
                draw: (g, size, t) => SeasonArt.menuBarAccent(event, g, Offset(size.width / 2, size.height - 10), 5, dark: dark),
              ),
            ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }
}
