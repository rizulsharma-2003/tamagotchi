// W18: the furniture catalogue, unlocks and placement against the Swift engine (link-spec/world/room.json), plus the
// Mac editor's rules (only unlocked pieces; dropping on the tray puts a piece away).

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

String _id(int n) => '00000000-0000-0000-0000-${n.toString().padLeft(12, '0')}';

List<Object?> _items(List<PlacedFurniture> items) => [
  for (final i in items) [i.id, i.kind, i.x, i.y, i.flipped],
];

double _value(Object? v) => switch (v) {
  'nan' => double.nan,
  'inf' => double.infinity,
  '-inf' => double.negativeInfinity,
  final num n => n.toDouble(),
  _ => throw StateError('bad value $v'),
};

Object? _unlock(FurnitureUnlock u) => switch (u) {
  FurnitureAlways() => 'always',
  FurnitureAtLevel(:final level) => {'level': level},
  FurnitureForAchievement(:final achievement) => {'achievement': achievement.name},
};

void main() {
  final fixture = readWorldFixture('room.json');

  test('the catalogue: twelve pieces, their sizes, places and how each is earned', () {
    final expected = objs(fixture['catalog']);
    expect(FurnitureCatalog.all, hasLength(12));
    expect(
      diffJson([
        for (final k in FurnitureCatalog.all)
          {
            'id': k.id,
            'title': k.title,
            'placement': k.placement.name,
            'isFlat': k.isFlat,
            'width': k.width,
            'height': k.height,
            'unlock': _unlock(k.unlock),
            'defaultX': k.defaultX,
            'defaultY': k.defaultY,
            'unlockHint': k.unlockHint,
          },
      ], expected),
      isEmpty,
    );
  });

  test('what friendship and achievements unlock', () {
    for (final row in (fixture['unlocks']! as List).cast<List<Object?>>()) {
      final progress = ProgressState()..affectionPoints = row[0]! as int;
      for (final id in (row[1]! as List).cast<String>()) {
        progress.unlocked[id] = DateTime.utc(2027);
      }
      expect(progress.friendshipLevel, row[2], reason: '$row');
      expect(FurnitureCatalog.unlocked(progress).map((k) => k.id), row[3], reason: '$row');
    }
  });

  test('snapping into the wall, floor and rug bands', () {
    for (final row in (fixture['snapped']! as List).cast<List<Object?>>()) {
      final kind = FurnitureCatalog.kind(row[0]! as String)!;
      final (x, y) = RoomLayout.snapped(kind, _value(row[1]), _value(row[2]));
      expect(diffJson([x, y], row.sublist(3)), isEmpty, reason: '$row');
    }
  });

  test('arranging one room: free spots, moves, flips, removals and the size limit', () {
    final room = RoomLayout();
    var counter = 0;
    for (final step in (fixture['steps']! as List).cast<List<Object?>>()) {
      final op = (step[0]! as String).split(' ');
      Object? result;
      switch (op[0]) {
        case 'add':
          counter += 1;
          final kind = FurnitureCatalog.kind(op[1])!;
          result = room
              .add(kind, x: op.length > 2 ? double.parse(op[2]) : null, y: op.length > 3 ? double.parse(op[3]) : null, id: _id(counter))
              ?.id;
        case 'move':
          room.move(_id(int.parse(op[1])), double.parse(op[2]), double.parse(op[3]));
        case 'flip':
          room.toggleFlip(_id(int.parse(op[1])));
        case 'remove':
          for (final n in op.skip(1).where((p) => p != 'and')) {
            room.remove(_id(int.parse(n)));
          }
      }
      expect(result, step[1], reason: step[0]! as String);
      expect(diffJson(_items(room.items), step[2]), isEmpty, reason: step[0]! as String);
      expect(room.isFull, step[3], reason: step[0]! as String);
      expect(room.drawingOrder.map((i) => i.id), step[4], reason: step[0]! as String);
    }
  });

  test('cleaning up a room from a newer version, and the Mac\'s JSON', () {
    final messy = RoomLayout(
      items: [
        for (final i in (fixture['messy']! as List).cast<List<Object?>>())
          PlacedFurniture(
            id: i[0]! as String,
            kind: i[1]! as String,
            x: (i[2]! as num).toDouble(),
            y: (i[3]! as num).toDouble(),
            flipped: i[4]! as bool,
          ),
      ],
    );
    final clean = messy.sanitized();
    expect(diffJson(_items(clean.items), fixture['sanitized']), isEmpty);
    final mac = RoomLayout.fromJson(fixture['encoded']);
    expect(diffJson(_items(mac.items), fixture['sanitized']), isEmpty);
    expect(diffJson(clean.toJson(), fixture['encoded']), isEmpty);
    expect(
      RoomLayout.fromJson({
        'items': [
          {'kind': 'rug'},
          'junk',
          {'id': 'a', 'kind': 'rug', 'x': 0.5, 'y': 0.9},
        ],
      }).items,
      hasLength(1),
    );
  });

  test('the editor adds only unlocked pieces; dropping on the tray puts a piece away', () {
    final progress = ProgressState();
    var n = 0;
    final room = RoomLayout(newID: () => 'id-${++n}');
    expect(room.addUnlocked(FurnitureCatalog.kind('catTree')!, progress), isNull, reason: 'needs friendship level 4');
    final rug = room.drop(FurnitureCatalog.kind('rug')!, overTray: false, x: 0.3, y: 0.93, progress: progress);
    expect(rug?.id, 'id-1');
    expect(room.drop(FurnitureCatalog.kind('plant')!, overTray: true, x: 0.3, y: 0.9, progress: progress), isNull);
    expect(room.items, hasLength(1));
    room.drop(FurnitureCatalog.kind('rug')!, existing: 'id-1', overTray: false, x: 0.6, y: 0.2, progress: progress);
    expect([room.items.single.x, room.items.single.y], [0.6, 0.9]);
    room.drop(FurnitureCatalog.kind('rug')!, existing: 'id-1', overTray: true, x: 0.6, y: 0.2, progress: progress);
    expect(room.items, isEmpty);
    expect(room.summary(progress), '4 of 12 pieces unlocked · 0 of 8 placed');
    expect(randomUUID(), matches(RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$')));
  });
}
