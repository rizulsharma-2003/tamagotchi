// Docs/SPRINT_2.md W5, Copy Cloud Settings on Windows (the Mac's AgentController.copyCloudLinkSettings): Mochi Cloud
// joins this PC's room as a `cloud` device (an invitation for the cloud role, joined as "Mochi Cloud" on platform
// "cloud") and replaces the one it had (removed from the room, first if the room is full, never if joining failed);
// the MOCHI_LINK_* block with MOCHI_TIMEZONE goes on the clipboard. Settings › Agent says what it does, honestly, with
// a confirmation before an old Mochi Cloud is replaced. Against a fake relay; test/cloud_live_test.dart does it for
// real in a throwaway room.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/time_zone.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/fakes.dart';

Map<String, Object?> peer(String id, String role, String platform, String name, {bool online = true}) => {
  'id': id,
  'role': role,
  'platform': platform,
  'name': name,
  'online': online,
};

LinkPeer linkPeer(String id, String role) => LinkPeer.fromJson(peer(id, role, role == 'cloud' ? 'cloud' : 'android', id))!;

/// Settings › Agent's Copy Cloud Settings button.
final Finder copyButton = find.ancestor(of: find.text('Copy Cloud Settings'), matching: find.byWidgetPredicate((widget) => widget is FilledButton));

void main() {
  late TestDesktop t;

  setUp(() => t = TestDesktop.make(saved: hostCredentials));
  tearDown(() => t.dispose());

  /// This PC's room on the fake relay, with [others] in it.
  Future<void> room(WidgetTester tester, List<Map<String, Object?>> others) => tester.runAsync(() async {
    await t.desktop.link.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    t.socket.sync(devices: [peer('dev_pc', 'host', 'windows', 'TEST-PC'), ...others]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  final phone = peer('dev_droid', 'pocket', 'android', 'realme RMX3242');
  final cloud = peer('dev_cloud', 'cloud', 'cloud', 'Mochi Cloud', online: false);

  group('LinkHost.joinCloud', () {
    testWidgets('a cloud invitation, joined as Mochi Cloud, and the old Mochi Cloud removed from the room', (tester) async {
      await room(tester, [phone, cloud]);
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_droid', 'pocket'), linkPeer('dev_cloud', 'cloud')];
      final joined = (await tester.runAsync(t.desktop.link.joinCloud))!;
      expect(t.api.inviteRoles, ['cloud']);
      expect(t.api.joins.single, (role: 'cloud', platform: 'cloud', name: 'Mochi Cloud'));
      expect(joined.credentials.role, 'cloud');
      expect(joined.credentials.room, hostCredentials.room);
      expect(joined.credentials.key, hostCredentials.key, reason: 'the room key travels to the cloud, never to the relay');
      expect(joined.replaced, ['dev_cloud']);
      expect(t.api.removed, ['dev_cloud'], reason: 'one Mochi Cloud, not one more each time');
      expect(t.api.removed, isNot(contains(joined.credentials.device)));
      expect(t.api.removed, isNot(contains('dev_droid')));
    });

    testWidgets('no Mochi Cloud yet: it joins, and nothing is removed', (tester) async {
      await room(tester, [phone]);
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_droid', 'pocket')];
      final joined = (await tester.runAsync(t.desktop.link.joinCloud))!;
      expect(joined.replaced, isEmpty);
      expect(t.api.removed, isEmpty);
    });

    testWidgets('a full room (eight devices): the old Mochi Cloud makes room first', (tester) async {
      await room(tester, [phone, cloud]);
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_cloud', 'cloud')];
      t.api.failJoin = const LinkPairingException('The relay said no (room_full).', status: 409, code: 'room_full');
      final joined = (await tester.runAsync(t.desktop.link.joinCloud))!;
      expect(t.api.removed, ['dev_cloud']);
      expect(joined.replaced, ['dev_cloud']);
      expect(t.api.inviteRoles, ['cloud', 'cloud'], reason: 'invited again after making room');
    });

    testWidgets('a full room with no Mochi Cloud to replace, or a relay that says no: nothing is removed', (tester) async {
      await room(tester, [phone, cloud]);
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_droid', 'pocket')];
      t.api.failJoin = const LinkPairingException('The relay said no (room_full).', status: 409, code: 'room_full');
      final full = await tester.runAsync(() => t.desktop.link.joinCloud().then<Object?>((_) => null, onError: (Object e) => e));
      expect(full, isA<LinkPairingException>());
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_cloud', 'cloud')];
      t.api.failJoin = const LinkPairingException('The relay said no (invite_limit).', status: 429, code: 'invite_limit');
      final refused = await tester.runAsync(() => t.desktop.link.joinCloud().then<Object?>((_) => null, onError: (Object e) => e));
      expect(refused, isA<LinkPairingException>());
      expect(t.api.removed, isEmpty, reason: 'the old Mochi Cloud keeps working');
    });

    testWidgets('the relay can’t list the devices over HTTPS: what the socket said last', (tester) async {
      await room(tester, [phone, cloud]);
      t.api.listed = null;
      final joined = (await tester.runAsync(t.desktop.link.joinCloud))!;
      expect(joined.replaced, ['dev_cloud']);
    });

    testWidgets('no phone paired yet: it says to pair one first', (tester) async {
      await room(tester, []);
      final error = await tester.runAsync(() => t.desktop.link.joinCloud().then<Object?>((_) => null, onError: (Object e) => e));
      expect(error, isA<LinkPairingException>().having((e) => e.message, 'message', contains('Pair a phone')));
      expect(t.api.invites, 0);
    });

    test('the environment block: the Mac’s, line for line', () {
      final block = CloudJoin(credentials: phoneCredentials, replaced: const []).environment(timeZone: 'Asia/Kolkata');
      expect(block.split('\n'), [
        'MOCHI_LINK_RELAY=relay.test',
        'MOCHI_LINK_ROOM=room_pc',
        'MOCHI_LINK_DEVICE=dev_phone',
        'MOCHI_LINK_SECRET=phone-secret',
        'MOCHI_LINK_KEY=${phoneCredentials.key}',
        'MOCHI_TIMEZONE=Asia/Kolkata',
      ]);
    });

    test('the time zone: its IANA name; a whole-hour offset when there’s none; new names for old ones', () {
      expect(TimeZoneName.current(), anyOf(contains('/'), 'UTC'));
      expect(TimeZoneName.fixed(const Duration(hours: 1)), 'Etc/GMT-1');
      expect(TimeZoneName.fixed(const Duration(hours: -5)), 'Etc/GMT+5');
      expect(TimeZoneName.fixed(const Duration(hours: 5, minutes: 30)), 'UTC');
      expect(TimeZoneName.fixed(Duration.zero), 'UTC');
      expect(TimeZoneName.renamed['Asia/Calcutta'], 'Asia/Kolkata');
    });
  });

  group('Settings › Agent', () {
    late FakeShell shell;
    String? copied;

    setUp(() {
      shell = FakeShell();
      copied = null;
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.agent,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> copy(WidgetTester tester) async {
      final button = copyButton;
      await tester.ensureVisible(button);
      await tester.tap(button);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('replacing Mochi Cloud asks first, then copies the block and says to paste it in place of the old one', (tester) async {
      await room(tester, [phone, cloud]);
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_droid', 'pocket'), linkPeer('dev_cloud', 'cloud')];
      await open(tester);
      expect(find.textContaining('realme RMX3242 through Mochi Link'), findsOneWidget, reason: 'the phones by name');
      await copy(tester);
      expect(find.text('Replace Mochi Cloud’s settings?'), findsOneWidget);
      await tester.tap(find.text('Replace'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(copied, isNotNull);
      final lines = copied!.split('\n');
      expect(lines.map((line) => line.split('=').first), [
        'MOCHI_LINK_RELAY',
        'MOCHI_LINK_ROOM',
        'MOCHI_LINK_DEVICE',
        'MOCHI_LINK_SECRET',
        'MOCHI_LINK_KEY',
        'MOCHI_TIMEZONE',
      ]);
      expect(lines.last, 'MOCHI_TIMEZONE=${TimeZoneName.current()}');
      expect(t.api.removed, ['dev_cloud']);
      expect(find.textContaining('in place of the MOCHI_LINK_ lines it had'), findsOneWidget);
      expect(find.textContaining('so don’t share it'), findsOneWidget);
    });

    testWidgets('“Cancel”: nothing changes', (tester) async {
      await room(tester, [phone, cloud]);
      await open(tester);
      await copy(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect((copied, t.api.invites, t.api.removed.length), (null, 0, 0));
    });

    testWidgets('the first Mochi Cloud: no question, copied', (tester) async {
      await room(tester, [phone]);
      t.api.listed = [linkPeer('dev_pc', 'host'), linkPeer('dev_droid', 'pocket')];
      await open(tester);
      await copy(tester);
      expect(find.text('Replace Mochi Cloud’s settings?'), findsNothing);
      expect(copied, contains('MOCHI_LINK_DEVICE=dev_cloud_2'));
      expect(find.textContaining('Copied. On claude.ai/code'), findsOneWidget);
    });

    testWidgets('no phone yet: the button is off and it says to pair one; the agent itself is honestly not here', (tester) async {
      await room(tester, []);
      await open(tester);
      final button = tester.widget<FilledButton>(copyButton.first);
      expect(button.onPressed, isNull);
      expect(find.text('Pair a phone in Settings › Phones first: Mochi Cloud joins the same link.'), findsOneWidget);
      expect(find.text('The agent is coming to Windows'), findsOneWidget);
      expect(find.textContaining('the phones paired with this PC'), findsOneWidget);
    });
  });
}
