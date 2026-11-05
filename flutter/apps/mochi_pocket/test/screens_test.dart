// Every screen on a phone-sized view with sample data, light and dark, at the normal text size and at 2× (Android's
// largest font scaling): no overflow or other exception anywhere. With the real fonts loaded (Nunito and Material
// Icons), so text measures as on the phone.
//
// MOCHI_SCREENSHOTS=<folder> flutter test test/screens_test.dart   also writes each screen as a PNG there.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/scene/pose_library.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';

import 'support/fakes.dart';

void main() {
  final output = Platform.environment['MOCHI_SCREENSHOTS'];
  late PoseLibrary library;

  setUpAll(() async {
    library = PoseLibrary.parse(File(PoseLibrary.asset).readAsBytesSync());
    final nunito = FontLoader('Nunito');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      nunito.addFont(Future.value(ByteData.sublistView(File('fonts/Nunito-$weight.ttf').readAsBytesSync())));
    }
    await nunito.load();
    // The Flutter SDK's copy of Material Icons, next to the test runner.
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!Directory('${sdk.path}/artifacts/material_fonts').existsSync() && sdk.parent.path != sdk.path) {
      sdk = sdk.parent;
    }
    final icons = File('${sdk.path}/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
    }
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      final variant = '${dark ? 'dark' : 'light'}${scale == 1 ? '' : '-2x'}';

      Future<(PocketModel, FakeRelay)> open(WidgetTester tester, {bool paired = true, double height = 800}) async {
        tester.view.physicalSize = Size(1080, height * 3);
        tester.view.devicePixelRatio = 3;
        tester.view.padding = const FakeViewPadding(top: 120, bottom: 72);
        tester.view.viewPadding = const FakeViewPadding(top: 120, bottom: 72);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final relay = FakeRelay();
        final bridge = FakeBridge();
        final settings = AppSettings(MemoryDocument());
        final model = PocketModel(
          credentialStore: MemoryCredentialStore(paired ? phoneCredentials : null),
          doneDocument: MemoryDocument(),
          notifier: FakeNotifier(),
          connect: relay.connect,
          deviceName: 'realme RMX3242',
        );
        await tester.pumpWidget(
          MochiApp(
            model: model,
            bridge: bridge,
            notifier: FakeNotifier(),
            opener: FakeOpener(),
            library: Future.value(library),
            settings: settings,
            reader: UpdatesReader(engine: FakeSpeechEngine(), focus: bridge, settings: settings, language: () => 'en-IN'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        if (paired) {
          relay.presence(macOnline: true);
          relay.fromMac(LinkKey.look, sampleLook().toValue());
          relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'working', category: 'edit').toValue());
          relay.fromMac(LinkKey.sessions, richSessions().toValue());
          relay.fromMac(LinkKey.agent, richAgent().toValue());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
        }
        return (model, relay);
      }

      Future<void> shoot(WidgetTester tester, String name) async {
        await tester.pump(const Duration(milliseconds: 900));
        expect(tester.takeException(), isNull, reason: '$name ($variant)');
        if (output == null) return;
        await tester.runAsync(() async {
          final image = await captureImage(find.byType(MaterialApp).evaluate().single);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          Directory(output).createSync(recursive: true);
          File('$output/$name-$variant.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }

      Future<void> finish(WidgetTester tester, PocketModel model) async {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await tester.pump(const Duration(seconds: 10));
      }

      testWidgets('home, whole page ($variant)', (tester) async {
        final (model, _) = await open(tester, height: scale == 1 ? 2350 : 4200);
        await shoot(tester, 'home-full');
        await finish(tester, model);
      });

      testWidgets('home, first screen, typing and a reply ($variant)', (tester) async {
        final (model, relay) = await open(tester);
        model.send('Water the plants');
        await tester.pump();
        final command = LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!;
        relay.fromMac(LinkKey.reply, LinkReply(id: command.id, state: 'done', text: 'Watered them. Mochi says hi!', at: now()).toValue());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await shoot(tester, 'home');
        await finish(tester, model);
      });

      testWidgets('Send to Claude? ($variant)', (tester) async {
        final (model, relay) = await open(tester, height: 1400);
        relay.fromMac(
          LinkKey.approval,
          ApprovalRequest(
            id: 'a1',
            target: 'session-1',
            project: 'mac-Tamagotchi',
            message: 'Run the tests and push.',
            at: now(),
          ).toValue(),
        );
        await tester.pump();
        await shoot(tester, 'approval');
        await finish(tester, model);
      });

      testWidgets('updates ($variant)', (tester) async {
        final (model, _) = await open(tester);
        model.markDone(['mail:github']);
        await tester.pump();
        await tester.scrollUntilVisible(find.text('Waiting for you'), 300);
        await tester.tap(find.text('Waiting for you'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await shoot(tester, 'updates');
        await finish(tester, model);
      });

      testWidgets('settings ($variant)', (tester) async {
        final (model, _) = await open(tester, height: scale == 1 ? 1700 : 3600);
        await tester.tap(find.byTooltip('Settings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await shoot(tester, 'settings');
        await finish(tester, model);
      });

      testWidgets('home with animations removed ($variant)', (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
        final (model, _) = await open(tester);
        model.interact('pet');
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
        await finish(tester, model);
      });

      testWidgets('pairing ($variant)', (tester) async {
        final (model, _) = await open(tester, paired: false);
        await shoot(tester, 'pairing');
        await finish(tester, model);
      });
    }
  }
}

/// Fuller sample data than the unit tests need: every kind of row the screens draw.
AgentPending richAgent() => AgentPending(
  enabled: true,
  headline: 'A busy afternoon: the design review is at 4, and Priya is waiting on the invoice.',
  lookedAt: now() - 300,
  updatedAt: now() - 300,
  items: [
    AgentNote(
      id: 'cal:review',
      source: AgentSource.calendar,
      title: 'Design review',
      detail: 'With Aditi and Sam · Google Meet',
      important: true,
      at: now(),
      due: now() + 7200,
      link: 'https://meet.google.com/abc-defg-hij',
    ),
    ...sampleAgent().items.where((note) => note.source == AgentSource.gmail),
    AgentNote(
      id: 'notion:checklist',
      source: AgentSource.notion,
      title: 'Finish the launch checklist',
      detail: 'Due today · Product',
      important: false,
      at: now() - 7200,
      due: now() + 5 * 3600,
      link: 'https://www.notion.so',
    ),
    AgentNote(
      id: 'mail:github',
      source: AgentSource.gmail,
      title: 'GitHub',
      detail: '1 new commit pushed to main.',
      important: false,
      at: now() - 9000,
      link: 'https://mail.google.com/mail/u/0/#inbox/github',
      subject: '[tamagotchi] Mochi for Android',
    ),
    AgentNote(
      id: 'mail:aditi',
      source: AgentSource.gmail,
      title: 'Aditi Rao',
      detail: 'Shared the new onboarding flow; would love your notes before Friday.',
      important: true,
      at: now() - 3600,
      link: 'https://mail.google.com/mail/u/0/#inbox/aditi',
      subject: 'Onboarding v2 for review',
    ),
  ],
);

PhoneSessions richSessions() => PhoneSessions(
  enabled: true,
  updatedAt: now(),
  sessions: [
    PhoneSessionCard(id: 'session-2', project: 'mochi-link', phase: 'working', files: const [], phaseSince: now() - 120),
    PhoneSessionCard(
      id: 'session-1',
      project: 'mac-Tamagotchi',
      phase: 'done',
      summary: const TurnSummary(
        done: 'Gave Mochi its own voice and made Siri read reliably.',
        session: 'Mochi Pocket voice and Siri',
        next: ['Push it', 'Run the tests'],
      ),
      files: const ['KokoroVoice.swift', 'UpdatesReader.swift'],
      finishedAt: now() - 600,
    ),
  ],
);
