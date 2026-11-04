// The subjects of the Swift reference sheets (Sources/App/Dev/SnapshotRenderer.swift,
// AnimationStrips.swift, Features/Seasons/DecorSnapshots.swift), drawn with the Dart port from
// the poses in test/fixtures/reference_poses.json. Shared by the comparison and golden tests.

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/src/model/json.dart';

import 'render.dart';

const Color paper = Color(0xFFFBF4EC);

/// A fixed time for the wall clock, so renders are reproducible.
void pinClock() => FurnitureArt.now = () => DateTime(2026, 11, 4, 10, 8, 30);

// MARK: pet-gallery.png

List<Cell> petGalleryCells() => [
  for (final entry in referenceList('petGallery'))
    Cell(string(entry, 'title') ?? '', const Size(104, 104), (g, size) {
      final pose = PetPose.fromJson(asMap(entry['pose']));
      PetRenderer.draw(pose, g, Offset(size.width / 2, size.height - 8), 1.25, PetPalette(PetColor.cream));
    }),
];

// MARK: companion-gallery.png

List<Cell> companionGalleryCells() => [
  for (final entry in referenceList('companionGallery'))
    Cell(string(entry, 'title') ?? '', const Size(150, 124), (g, size) {
      final pose = CompanionPose.fromJson(asMap(entry['pose']));
      CompanionRenderer.draw(
        pose,
        g,
        Offset(size.width / 2, size.height - 6),
        1.1,
        time: dbl(entry, 'time', 2.1),
        deskFront: (desk) => ThemeRenderer.deskFront(OfficeTheme.cozyDesk, desk),
      );
    }),
];

// MARK: life-stages.png

List<Cell> lifeStageCells() {
  final pose = PetPose.fromJson(asMap(referencePoses()['lifeStagePose']));
  return [
    for (final stage in LifeStage.values)
      Cell(stage.title, const Size(140, 120), (g, size) {
        PetRenderer.stage = stage;
        PetRenderer.draw(pose, g, Offset(size.width / 2, size.height - 8), 1.6, PetPalette(PetColor.cream));
        PetRenderer.stage = LifeStage.grownUp;
      }),
  ];
}

// MARK: pet-tiny-features.png (menu-bar size: each feature that must read at 12–16 pt)

List<(String, PetPose)> tinyFeaturePoses() {
  final base = PetPose.fromJson(asMap(referencePoses()['tinyBasePose']));
  return [
    ('open', base.copy()..eyeOpenness = 1),
    ('blink', base.copy()..eyeOpenness = 0.05),
    ('ear', base.copy()..earRight += 0.45),
    (
      'tail',
      base.copy()
        ..tailWag = 1.6
        ..tailCurl = 0.6,
    ),
    (
      'happy',
      base.copy()
        ..eyes = PetEyes.happy
        ..mouth = PetMouth.grin
        ..blush = 0.9,
    ),
    (
      'sparkle',
      base.copy()
        ..eyes = PetEyes.wide
        ..eyeSparkle = 1
        ..eyeScale = 1.2,
    ),
    (
      'cheeks',
      base.copy()
        ..cheekLeft = 1
        ..cheekRight = 1
        ..mouth = PetMouth.tiny,
    ),
    ('sleep', PetPose.fromJson(asMap(referencePoses()['tinySleepPose']))),
    ('run', PetPose.fromJson(asMap(referencePoses()['tinyRunPose']))),
  ];
}

List<Cell> tinyFeatureCells(bool dark) => [
  for (final (name, pose) in tinyFeaturePoses())
    Cell(name, const Size(30, 22), background: dark ? const Color(0xFF2B2A30) : const Color(0xFFF2F1F4), (g, size) {
      PetRenderer.draw(
        pose,
        g,
        Offset(size.width * 0.45, size.height - 2.5),
        0.3,
        PetPalette(PetColor.cream),
        dark: dark,
        detail: RenderDetail.tiny,
      );
    }),
];

// MARK: accessories.png (each cell: Mochi wearing it above Patch wearing it)

List<Cell> accessoryCells() {
  final petPose = PetPose.fromJson(asMap(referencePoses()['accessoryPetPose']));
  final companionPose = CompanionPose.fromJson(asMap(referencePoses()['accessoryCompanionPose']));
  final wearables = Accessory.values.where((a) => a.slot == AccessorySlot.wearable).toList();
  return [
    for (var index = 0; index < wearables.length; index++)
      Cell(wearables[index].title, const Size(84, 206), (g, size) {
        final pose = petPose.copy()..eyes = index % 3 == 0 ? PetEyes.happy : PetEyes.open;
        PetRenderer.draw(
          pose,
          g,
          Offset(size.width / 2, 96 - 6),
          1.1,
          PetPalette(PetColor.values[index % PetColor.values.length]),
          accessory: wearables[index],
        );
        CompanionRenderer.draw(
          companionPose,
          g,
          Offset(size.width / 2, 96 + 110 - 8),
          1.25,
          accessory: wearables[index],
          time: 0.5,
          workstation: false,
        );
      }),
  ];
}

// MARK: Scenes (scene-*.png, interactions.png, room-furnished.png)

void drawSceneEntry(Map<String, Object?> entry, GContext g, Size size) {
  final config = SceneConfig.fromJson(entry);
  final frame = SceneFrame.fromJson(entry);
  SceneRenderer.draw(
    config,
    frame,
    SceneLayout.popover(size.width, size.height),
    g,
    time: dbl(entry, 'time', 100),
    dark: boolean(entry, 'dark', false),
    hour: integer(entry, 'hour', 14),
  );
}

Cell sceneCell(Map<String, Object?> entry, {String? label}) => Cell(
  label ?? string(entry, 'name') ?? '',
  Size(dbl(entry, 'width', 360), dbl(entry, 'height', 178)),
  (g, size) => drawSceneEntry(entry, g, size),
  clip: true,
);

List<Map<String, Object?>> sceneEntries() => referenceList('scenes');
List<Map<String, Object?>> interactionEntries() => referenceList('interactions');
List<Map<String, Object?>> roomEntries() => referenceList('rooms');
List<Map<String, Object?>> seasonEntries() => referenceList('seasons');

// MARK: room-catalog.png and room-photo.png

List<Cell> catalogCells(bool dark) => [
  for (final kind in FurnitureCatalog.all)
    Cell(kind.title, const Size(70, 110), background: dark ? const Color(0xFF2E2523) : const Color(0xFFFCF1E5), (g, size) {
      final layout = SceneLayout.popover(360, 178);
      final item = PlacedFurniture(id: kind.id, kind: kind.id, x: 0, y: kind.defaultY);
      final frame = RoomSpace(layout).frame(item, kind);
      final piece = g.copy()..translateBy(size.width / 2 - frame.center.dx, size.height - 6 - frame.bottom);
      RoomDecor.drawPiece(item, kind, piece, layout, dark: dark, time: 100.7);
    }),
];

Cell photoCell() => Cell('', const Size(200, 160), background: const Color(0xFFFCF1E5), (g, size) {
  final piece = g.copy()
    ..translateBy(size.width / 2, size.height / 2)
    ..scaleBy(5, 5);
  FurnitureArt.draw('photo', piece, time: 1);
});

// MARK: Strips (pet-strips-N.png, companion-strips-N.png)

List<List<T>> chunks<T>(List<T> items, int size) => [
  for (var i = 0; i < items.length; i += size) items.sublist(i, i + size > items.length ? items.length : i + size),
];

/// `AnimationStrips.petSheet` rows (cell 78, not wide).
List<StripRow> petStripRows(List<Map<String, Object?>> strips, {double cell = 78}) {
  final scale = cell / 78;
  return [
    for (final strip in strips)
      StripRow(string(strip, 'title') ?? '', [
        for (final frame in list(strip, 'frames'))
          Cell('${dbl(frame, 't', 0).toStringAsFixed(2)}s', Size(cell, cell * 1.12), (g, size) {
            final ground = size.height - 7;
            g.fill(Shapes.rect(Rect.fromLTWH(0, ground + 1, size.width, 1)), black.fade(0.12));
            final home = size.width / 2;
            g.fill(Shapes.rect(Rect.fromLTWH(home - 0.5, ground + 1, 1, 3)), black.fade(0.2));
            final pose = PetPose.fromJson(asMap(frame['pose']));
            final offset = pose.x * bodyWidthsPerPathUnit * PetRenderer.bodyWidth * scale;
            PetRenderer.draw(pose, g, Offset(home + offset, ground), scale, PetPalette(PetColor.cream));
          }),
      ]),
  ];
}

/// `AnimationStrips.companionSheet` rows.
List<StripRow> companionStripRows(List<Map<String, Object?>> strips) => [
  for (final strip in strips)
    StripRow(string(strip, 'title') ?? '', [
      for (final frame in list(strip, 'frames'))
        Cell('', const Size(104, 112), (g, size) {
          final pose = CompanionPose.fromJson(asMap(frame['pose']));
          CompanionRenderer.draw(
            pose,
            g,
            Offset(size.width / 2 - 6, size.height - 4),
            0.95,
            time: dbl(frame, 'time', 10),
            deskFront: (desk) => ThemeRenderer.deskFront(OfficeTheme.cozyDesk, desk),
          );
        }),
    ]),
];

// MARK: season-treats.png and season-treat-story.png

List<Cell> treatCells() => [
  for (final style in TreatStyle.values)
    Cell(style.name, const Size(44, 66), (g, size) {
      SeasonalTreats.drawStyle(style, g.copy()..translateBy(22, 22), 30, 0.4);
      SeasonalTreats.drawStyle(style, g.copy()..translateBy(22, 44 + 9), 11, 1.2);
    }),
];

List<Cell> treatStoryCells() {
  final story = referenceList('treatStory');
  return [
    for (final style in TreatStyle.values)
      Cell(style.name, const Size(96, 192), (g, size) {
        for (var index = 0; index < story.length; index++) {
          SeasonalTreats.style = style;
          final pose = PetPose.fromJson(asMap(story[index]['pose']));
          PetRenderer.draw(pose, g, Offset(size.width / 2, 96.0 * index + 96 - 6), 1.1, PetPalette(PetColor.cream));
          SeasonalTreats.style = TreatStyle.cookie;
        }
      }),
  ];
}

/// A single scene as an image the size Swift writes it.
Future<ui.Image> sceneImage(Map<String, Object?> entry, {double scale = 2}) =>
    sheetImage([sceneCell(entry, label: '')], columns: 1, padding: 0, spacing: 0, labelHeight: 0, scale: scale);
