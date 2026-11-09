// The approval card in Ask Mochi's place (the main window's question box): what it shows, what each choice does, the
// keyboard and the screen reader.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/ui/screens/home_screen.dart';
import 'package:mochi_ui/mochi_ui.dart';

import 'support/brain_fakes.dart';
import 'support/fakes.dart';

void main() {
  late BrainRig rig;
  late AskMochi ask;
  late FakeChannel channel;

  Future<void> pumpCard(WidgetTester tester, {String message = 'Please run the tests.', String to = 'web-ab [123456]'}) async {
    rig = BrainRig();
    rig.sessions.apply(hook('UserPromptSubmit', project: 'web', at: rig.clock.now));
    ask = AskMochi(sessions: rig.sessions, runner: () => null, cue: (_) {}, brainFactory: (self) => rig.brain);
    addTearDown(rig.brain.dispose);
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: mochiTheme(Brightness.light, formFactor: MochiFormFactor.desktop),
        home: Scaffold(
          body: SingleChildScrollView(child: AskBox(ask: ask)),
        ),
      ),
    );
    await tester.runAsync(() async {
      ask.ask('tell the web Claude to run the tests');
      await rig.settle();
      channel = await rig.askToSend(to: to, message: message);
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> answered(WidgetTester tester) async {
    await tester.runAsync(rig.settle);
    await tester.pump();
  }

  bool allowed() => !neverAllowed(channel);

  testWidgets('shows the session, its project and the full message, with Send and Don’t send', (tester) async {
    final long = List.generate(30, (i) => 'Step $i: do the thing.').join('\n');
    await pumpCard(tester, message: long);
    expect(find.text('Send to Claude · web · web-ab'), findsOneWidget);
    // The whole text is in the card (a long one scrolls inside it); nothing is cut to "…".
    expect(find.textContaining('Step 0: do the thing.', findRichText: true), findsOneWidget);
    expect(find.textContaining('Step 29: do the thing.', findRichText: true), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text("Don't send"), findsOneWidget);
    expect(rig.brain.approval!.message, long);
    rig.brain.decline();
  });

  testWidgets('Send sends; nothing else does', (tester) async {
    await pumpCard(tester);
    expect(allowed(), isFalse);
    await tester.tap(find.text('Send'));
    await answered(tester);
    expect(allowed(), isTrue);
    expect(find.text('Send'), findsNothing, reason: 'the card goes away once answered');
  });

  testWidgets('Don’t send declines', (tester) async {
    await pumpCard(tester);
    await tester.tap(find.text("Don't send"));
    await answered(tester);
    expect(rig.verdict(channel)['behavior'], 'deny');
    expect(find.text("Don't send"), findsNothing);
  });

  testWidgets('keyboard: focus starts on Don’t send, so Return can’t send by accident; Tab reaches Send; Escape declines', (tester) async {
    await pumpCard(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, "Don't send");
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await answered(tester);
    expect(rig.verdict(channel)['behavior'], 'deny', reason: 'Return on the focused button is Don’t send');
  });

  testWidgets('keyboard: Escape is Don’t send', (tester) async {
    await pumpCard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await answered(tester);
    expect(rig.verdict(channel)['behavior'], 'deny');
    expect(rig.brain.approval, isNull);
  });

  testWidgets('keyboard: Tab to Send, then Return sends', (tester) async {
    await pumpCard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(allowed(), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await answered(tester);
    expect(allowed(), isTrue);
  });

  testWidgets('keyboard: Ctrl+Return sends', (tester) async {
    await pumpCard(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await answered(tester);
    expect(allowed(), isTrue);
  });

  testWidgets('screen reader: the card is announced with the session and the whole message; both buttons are named', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCard(tester, message: 'Please run the tests, then tell me what failed.');
    final card = find.bySemanticsLabel(
      RegExp(
        r'^Mochi wants to send a message to your Claude session web\. The message is: Please run the tests, then tell me what failed\.$',
      ),
    );
    expect(card, findsOneWidget);
    expect(tester.getSemantics(card).flagsCollection.isLiveRegion, isTrue);
    expect(find.bySemanticsLabel('Send this message to web'), findsOneWidget);
    expect(find.bySemanticsLabel("Don't send this message"), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('Send this message to web')).flagsCollection.isButton, isTrue);
    rig.brain.decline();
    handle.dispose();
  });

  testWidgets('the card shows on the PC for a request that came from a phone, and the phone’s answer takes it away', (tester) async {
    rig = BrainRig();
    rig.sessions.apply(hook('UserPromptSubmit', project: 'web', at: rig.clock.now));
    ask = AskMochi(sessions: rig.sessions, runner: () => null, cue: (_) {}, brainFactory: (self) => rig.brain);
    addTearDown(rig.brain.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: mochiTheme(Brightness.light, formFactor: MochiFormFactor.desktop),
        home: Scaffold(
          body: SingleChildScrollView(child: AskBox(ask: ask)),
        ),
      ),
    );
    await tester.runAsync(() async {
      ask.ask('tell web to test', fromPhone: true, commandId: 'c1');
      await rig.settle();
      channel = await rig.askToSend();
    });
    await tester.pump();
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('from your phone'.toString()), findsNothing);
    expect(rig.phones.mirrored, hasLength(1));
    rig.brain.answerFromPhone(rig.phones.mirrored.single.id, allow: false);
    await answered(tester);
    expect(find.text('Send'), findsNothing);
    expect(rig.verdict(channel)['behavior'], 'deny');
  });
}
