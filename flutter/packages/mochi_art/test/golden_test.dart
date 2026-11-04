// Golden tests: the painters render the Swift reference subjects (poses exported from Swift by
// flutter/tools/pose_export) to PNG and compare them with test/goldens. After an intended art
// change, refresh them with:
//
//   flutter test --update-goldens test/golden_test.dart
//
// Labels and the SF font are left out so the goldens don't depend on the machine's fonts (the
// few glyphs in the art use the test font here); see reference_sheets_test.dart for labelled
// renders to compare with the Swift app by eye.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';

import 'support/render.dart';
import 'support/subjects.dart';

const double _scale = 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(pinClock);

  Future<void> golden(String name, List<Cell> cells, {int columns = 8, double spacing = 4, Color background = paper}) async {
    final image = await sheetImage(cells, columns: columns, spacing: spacing, labelHeight: 0, scale: _scale, background: background);
    await expectLater(image, matchesGoldenFile('goldens/$name.png'));
  }

  test('Mochi in every animation', () => golden('pet_gallery', petGalleryCells()));

  test('Mochi growing up', () => golden('life_stages', lifeStageCells(), columns: 3));

  test('Mochi at menu-bar size', () async {
    await golden('pet_tiny', [...tinyFeatureCells(false), ...tinyFeatureCells(true)], columns: 9, spacing: 3);
  });

  test('Patch in every animation', () => golden('companion_gallery', companionGalleryCells()));

  test('wearables on both characters', () => golden('accessories', accessoryCells(), columns: 11, spacing: 2));

  test('the four themes, light and dark', () async {
    await golden('scenes', [for (final e in sceneEntries()) sceneCell(e, label: '')], columns: 2, background: const Color(0xFF888888));
  });

  test('interactions', () async {
    await golden('interactions', [for (final e in interactionEntries()) sceneCell(e, label: '')], columns: 3);
  });

  test('a furnished room', () async {
    await golden('rooms', [for (final e in roomEntries()) sceneCell(e, label: '')], columns: 2, background: const Color(0xFF888888));
  });

  test('every piece of furniture', () async {
    await golden('furniture', [...catalogCells(false), ...catalogCells(true)], columns: 12, background: const Color(0xFF888888));
  });

  test('seasonal treats', () => golden('treats', treatCells(), columns: 6, spacing: 8));

  test('every holiday in the cozy room', () async {
    final entries = seasonEntries();
    final cells = <Cell>[
      for (final event in SeasonalEvent.values)
        for (final e in entries.where((e) => e['season'] == event.name).take(2)) sceneCell(e, label: ''),
    ];
    await golden('seasons', cells, columns: 2, background: const Color(0xFF888888));
  });
}
