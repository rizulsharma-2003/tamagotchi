// Renders the held items, effects, props and accessories (item_renderer.dart and
// accessory_renderer.dart) to PNG sheets for comparison with the Swift renders.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';

import 'support/render.dart';

const _light = Color(0xFFFBF4EC);
const _dark = Color(0xFF2B2A30);

/// Every effect kind with the variants and phases worth seeing.
List<(String, Effect)> _effects() => [
  ('z', Effect(EffectKind.z)),
  ('sparkle', Effect(EffectKind.sparkle)),
  ('sparkle 1', Effect(EffectKind.sparkle, variant: 1)),
  ('star', Effect(EffectKind.star)),
  ('star 1', Effect(EffectKind.star, variant: 1)),
  ('heart', Effect(EffectKind.heart)),
  ('question', Effect(EffectKind.question)),
  ('exclamation', Effect(EffectKind.exclamation)),
  ('sweat', Effect(EffectKind.sweat)),
  ('note 0', Effect(EffectKind.note)),
  ('note 1', Effect(EffectKind.note, variant: 1)),
  for (var v = 0; v < 4; v++) ('confetti $v', Effect(EffectKind.confetti, variant: v, rotation: 0.4)),
  ('steam', Effect(EffectKind.steam, rotation: 0.6)),
  ('speechDots', Effect(EffectKind.speechDots)),
  ('speechLock', Effect(EffectKind.speechLock)),
  ('speechQuestion', Effect(EffectKind.speechQuestion)),
  ('plug', Effect(EffectKind.plug)),
  ('thinking 2', Effect(EffectKind.thinkingDots, variant: 2)),
  ('clap', Effect(EffectKind.clap)),
  ('ball', Effect(EffectKind.ball, rotation: 0.5)),
  ('ball squash', Effect(EffectKind.ball, stretch: -0.4)),
  ('treat', Effect(EffectKind.treat, rotation: 0.3)),
  ('orb', Effect(EffectKind.orb, rotation: 0.2)),
  ('yarn + strand', Effect(EffectKind.yarn, rotation: 0.4, x2: -0.3, y2: 0.1)),
  ('shadow', Effect(EffectKind.shadow)),
  ('dust 0', Effect(EffectKind.dust)),
  ('dust 1', Effect(EffectKind.dust, variant: 1, phase: 0.5)),
  ('streak 0', Effect(EffectKind.streak)),
  ('streak 1', Effect(EffectKind.streak, variant: 1)),
  ('streak 2', Effect(EffectKind.streak, variant: 2)),
  ('purr 0', Effect(EffectKind.purr, phase: 0.3)),
  ('purr 1', Effect(EffectKind.purr, variant: 1, phase: 0.3)),
  for (var v = 0; v < 3; v++) ('crumb $v', Effect(EffectKind.crumb, variant: v, scale: 2)),
  ('butterfly 0', Effect(EffectKind.butterfly, phase: 0.3)),
  ('butterfly 1', Effect(EffectKind.butterfly, variant: 1, phase: 1.2)),
  ('bubble', Effect(EffectKind.bubble, phase: 0.4)),
  ('pop 0.2', Effect(EffectKind.pop, phase: 0.2)),
  ('pop 0.6', Effect(EffectKind.pop, variant: 1, phase: 0.6)),
  for (var v = 0; v < 4; v++) ('fish $v', Effect(EffectKind.fish, variant: v)),
  ('berry', Effect(EffectKind.berry, rotation: 0.3)),
  for (final v in [0, 1, 2, 4, 3]) ('cupcake $v', Effect(EffectKind.cupcake, variant: v)),
  ('sniff', Effect(EffectKind.sniff, phase: 0.5)),
  ('sneeze', Effect(EffectKind.sneeze, phase: 0.5)),
  ('noseBubble', Effect(EffectKind.noseBubble)),
  ('shake 0', Effect(EffectKind.shakeLines)),
  ('shake 1', Effect(EffectKind.shakeLines, variant: 1)),
  ('burst', Effect(EffectKind.burst, phase: 0.3)),
  ('burst pale', Effect(EffectKind.burst, variant: 1, phase: 0.3)),
  ('notice', Effect(EffectKind.notice)),
  ('droplet', Effect(EffectKind.droplet)),
  ('heartPop', Effect(EffectKind.heartPop, phase: 0.4)),
  ('frosting', Effect(EffectKind.frosting, scale: 1.5)),
];

/// A stand-in Mochi body for the wearables (the real one is PetRenderer's).
void _standInPet(GContext g) {
  final body = PetRenderer.bodyPath();
  g.fill(body, hex(0xFFE2C2));
  g.stroke(body, hex(0xD99D6C), 1.7);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PNG sheets', () {
    setUpAll(loadArtFonts);

    test('held items', () async {
      await writeSheet(
        'items-held.png',
        [
          for (final item in HeldItem.values)
            Cell(item.name, const Size(44, 44), (g, size) => ItemRenderer.draw(item, g, Offset(size.width / 2, size.height / 2), 30)),
        ],
        columns: 7,
        scale: 3,
      );
    });

    test('effects', () async {
      for (final dark in [false, true]) {
        for (final detail in RenderDetail.values) {
          final tiny = detail == RenderDetail.tiny;
          await writeSheet(
            'items-effects-${dark ? 'dark' : 'light'}${tiny ? '-tiny' : ''}.png',
            [
              for (final (label, effect) in _effects())
                Cell(label, const Size(56, 52), (g, size) {
                  EffectRenderer.draw(
                    effect,
                    g.copy()..translateBy(size.width / 2, size.height / 2),
                    unitX: 60,
                    unitY: 54,
                    dark: dark,
                    detail: detail,
                  );
                }, background: dark ? _dark : _light),
            ],
            columns: 10,
            scale: 2,
            background: dark ? const Color(0xFF1C1C20) : const Color(0xFFE8E2DA),
          );
        }
      }
    });

    test('props', () async {
      final cells = <Cell>[
        Cell('ball', const Size(44, 44), (g, s) => ItemRenderer.ball(g.copy()..translateBy(22, 22), 12, 0.4)),
        Cell('yarn', const Size(44, 44), (g, s) => ItemRenderer.yarn(g.copy()..translateBy(22, 22), 12, 0.4)),
        for (var bites = 0; bites < 4; bites++)
          Cell(
            'fish $bites',
            const Size(44, 44),
            (g, s) => ItemRenderer.fish(
              g.copy()
                ..translateBy(22, 22)
                ..scaleBy(1.6, 1.6),
              bites,
            ),
          ),
        Cell('berry', const Size(44, 44), (g, s) => ItemRenderer.berry(g.copy()..translateBy(22, 22), 2)),
        for (final v in [0, 1, 2, 4, 3])
          Cell('cupcake $v', const Size(44, 44), (g, s) => ItemRenderer.cupcake(g.copy()..translateBy(22, 18), 2, variant: v)),
        for (var v = 0; v < 3; v++) Cell('crumb $v', const Size(44, 44), (g, s) => ItemRenderer.crumb(g.copy()..translateBy(22, 22), v, 5)),
        Cell('cookie', const Size(44, 44), (g, s) => ItemRenderer.cookie(g.copy()..translateBy(22, 22), 30, spin: 0.4)),
        for (final kind in ScenePropKind.values)
          Cell(
            'prop ${kind.name}',
            const Size(44, 44),
            (g, s) => EffectRenderer.drawProp(SceneProp(kind, rotation: 0.3, variant: 1), g, const Offset(22, 22), 1.6, false),
          ),
      ];
      await writeSheet('items-props.png', cells, columns: 8, scale: 3);
    });

    test('wearables and desk accessories', () async {
      final wearables = Accessory.values.where((a) => a.slot == AccessorySlot.wearable);
      final desk = Accessory.values.where((a) => a.slot == AccessorySlot.desk);
      await writeSheet(
        'accessories-flutter.png',
        [
          for (final accessory in wearables)
            Cell(accessory.title, const Size(84, 96), (g, size) {
              final pet = g.copy()
                ..translateBy(size.width / 2, size.height - 6)
                ..scaleBy(1.1, 1.1);
              _standInPet(pet);
              if (accessory == Accessory.hoodie) AccessoryRenderer.petHoodie(pet);
              if (accessory == Accessory.scarf) AccessoryRenderer.petScarf(pet);
              AccessoryRenderer.petWearable(accessory, pet);
            }),
          for (final accessory in wearables)
            // Patch's wearables for the older round-head companion (PixelMascot draws its own pixel hats).
            Cell('head: ${accessory.name}', const Size(84, 110), (g, size) {
              final c = g.copy()
                ..translateBy(size.width / 2, size.height - 8)
                ..scaleBy(1.1, 1.1);
              if (accessory == Accessory.hoodie) AccessoryRenderer.companionHood(c);
              c.fill(Shapes.roundedRect(const Rect.fromLTWH(-23, -77, 46, 38), 12), hex(0xE8916A));
              if (accessory == Accessory.scarf) AccessoryRenderer.companionScarf(c);
              AccessoryRenderer.companionWearable(accessory, c);
            }),
          for (final item in [HeldItem.gradCap, HeldItem.detectiveHat])
            Cell('hat ${item.name}', const Size(84, 96), (g, size) {
              final pet = g.copy()
                ..translateBy(size.width / 2, size.height - 6)
                ..scaleBy(1.1, 1.1);
              _standInPet(pet);
              AccessoryRenderer.petHatItem(item, pet);
            }),
          for (final accessory in desk)
            Cell(accessory.title, const Size(84, 70), (g, size) {
              // The decoration's spot is (54, -22.5) on the desk; show it twice as big.
              final d = g.copy()
                ..translateBy(size.width / 2 - 54 * 2, size.height - 12 + 22.5 * 2)
                ..scaleBy(2, 2);
              d.fill(Shapes.rect(const Rect.fromLTWH(30, -22.5, 40, 3)), hex(0xDCA472));
              AccessoryRenderer.desk(accessory, d);
            }),
        ],
        columns: 11,
        scale: 2,
        background: const Color(0xFFF4F1EC),
      );
    });
  }, skip: pngSkip);
}
