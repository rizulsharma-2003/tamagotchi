// Renders the Dart port of every subject the Swift `--render-snapshots` and `--render-strips`
// tools draw, as PNGs with the same names, for side-by-side comparison:
//
//   MOCHI_ART_OUT=/some/dir flutter test test/reference_sheets_test.dart
//
// (without MOCHI_ART_OUT they go to test/out). The poses come from Swift via
// flutter/tools/pose_export, so any difference is in the drawing.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';

import 'support/render.dart';
import 'support/subjects.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PNG sheets', () {
    setUpAll(() async {
      await loadArtFonts();
      pinClock();
    });

    test('pet gallery', () async {
      await writeSheet('pet-gallery.png', petGalleryCells());
    });

    test('companion gallery', () async {
      await writeSheet('companion-gallery.png', companionGalleryCells());
    });

    test('life stages', () async {
      await writeSheet('life-stages.png', lifeStageCells(), columns: 3, spacing: 6);
    });

    test('menu-bar size', () async {
      await writeSheet(
        'pet-tiny-features.png',
        [...tinyFeatureCells(false), ...tinyFeatureCells(true)],
        columns: 9,
        spacing: 3,
        padding: 4,
        labelHeight: 0,
        scale: 4,
        background: const Color(0xFFDADDE3),
      );
    });

    test('accessories', () async {
      await writeSheet('accessories.png', accessoryCells(), columns: 11, spacing: 2, padding: 6, background: const Color(0xFFF4F1EC));
    });

    test('scenes', () async {
      for (final entry in sceneEntries()) {
        await writePng('${entry['name']}.png', await sceneImage(entry));
      }
    });

    test('interactions', () async {
      await writeSheet(
        'interactions.png',
        [for (final e in interactionEntries()) sceneCell(e)],
        columns: 3,
        spacing: 6,
        padding: 6,
        scale: 1.5,
        background: const Color(0xFFFFFFFF),
      );
    });

    test('furnished rooms', () async {
      await writeSheet(
        'room-furnished.png',
        [for (final e in roomEntries()) sceneCell(e, label: '')],
        columns: 2,
        spacing: 6,
        padding: 6,
        labelHeight: 0,
        scale: 1.5,
        background: const Color(0xFF888888),
      );
    });

    test('furniture catalog and photo', () async {
      await writeSheet(
        'room-catalog.png',
        [...catalogCells(false), ...catalogCells(true)],
        columns: 12,
        spacing: 4,
        padding: 6,
        background: const Color(0xFF888888),
      );
      await writeSheet('room-photo.png', [photoCell()], columns: 1, padding: 0, labelHeight: 0);
    });

    test('seasonal treats', () async {
      await writeSheet('season-treats.png', treatCells(), columns: 6, spacing: 8, scale: 3);
      await writeSheet('season-treat-story.png', treatStoryCells(), columns: 6, spacing: 4, padding: 6);
    });

    test('seasons', () async {
      final entries = seasonEntries();
      for (final event in SeasonalEvent.values) {
        final shots = entries.where((e) => e['season'] == event.name).toList();
        if (shots.isEmpty) continue;
        await writeSheet(
          'season-${event.name}.png',
          [for (final e in shots) sceneCell(e, label: '')],
          columns: 2,
          spacing: 6,
          padding: 6,
          labelHeight: 0,
          scale: 1.5,
          background: const Color(0xFF888888),
        );
        await writeSheet(
          'season-${event.name}-detail.png',
          [sceneCell(shots[0], label: ''), sceneCell(shots[1], label: '')],
          columns: 2,
          spacing: 4,
          padding: 0,
          labelHeight: 0,
          scale: 3,
        );
      }
    });

    test('pet strips', () async {
      final strips = chunks(referenceList('petStrips'), 8);
      for (var index = 0; index < strips.length; index++) {
        await writePng('pet-strips-${index + 1}.png', await stripImage(petStripRows(strips[index])));
      }
    });

    test('companion strips', () async {
      final strips = chunks(referenceList('companionStrips'), 8);
      for (var index = 0; index < strips.length; index++) {
        await writePng(
          'companion-strips-${index + 1}.png',
          await stripImage(companionStripRows(strips[index]), titleWidth: 70, captionHeight: 0),
        );
      }
    });
  }, skip: pngSkip);
}
