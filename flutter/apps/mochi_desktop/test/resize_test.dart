// Mochi's window and the Settings window can be resized by their edges (they have no frame of their own), and each
// remembers the size you gave it.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/ui/widgets/resize_edges.dart';

import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  late FakeShell shell;

  Future<DesktopAppState> show(WidgetTester tester, {MainPage page = MainPage.home}) async {
    final size = page == MainPage.settings ? SurfaceSizes.settings : SurfaceSizes.main;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DesktopApp(desktop: t.desktop, shell: shell, initialSurface: Surface.main, initialPage: page, library: Future<PoseLibrary?>.value()),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return tester.state<DesktopAppState>(find.byType(DesktopApp));
  }

  setUp(() {
    t = TestDesktop.make(saved: hostCredentials);
    shell = FakeShell();
  });
  tearDown(() => t.dispose());

  testWidgets('dragging an edge or a corner starts a resize from it', (tester) async {
    await show(tester);
    final size = tester.view.physicalSize;
    Future<void> dragAt(Offset at) async {
      final gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(20, 20));
      await gesture.up();
      await tester.pump();
    }

    await dragAt(Offset(size.width - 2, size.height / 2));
    await dragAt(Offset(size.width / 2, size.height - 2));
    await dragAt(Offset(size.width - 2, size.height - 2));
    await dragAt(const Offset(2, 300));
    expect(shell.resizes, [WindowEdge.right, WindowEdge.bottom, WindowEdge.bottomRight, WindowEdge.left]);
  });

  testWidgets('the edges show resize cursors and leave the window inside clickable', (tester) async {
    await show(tester);
    expect(ResizeEdges.cursorFor(WindowEdge.left), SystemMouseCursors.resizeLeftRight);
    expect(ResizeEdges.cursorFor(WindowEdge.top), SystemMouseCursors.resizeUpDown);
    expect(ResizeEdges.cursorFor(WindowEdge.topLeft), SystemMouseCursors.resizeUpLeftDownRight);
    expect(ResizeEdges.cursorFor(WindowEdge.bottomLeft), SystemMouseCursors.resizeUpRightDownLeft);
    // A drag well inside the window is not a resize.
    final gesture = await tester.startGesture(const Offset(200, 300), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pump();
    expect(shell.resizes, isEmpty);
  });

  testWidgets("Mochi's window remembers the size you gave it", (tester) async {
    final state = await show(tester);
    shell.sizeNow = const Size(620, 840);
    shell.controller.add(ShellAction.windowResized);
    await tester.pump();
    await tester.pump();
    expect(t.desktop.settings.mainWindowSize, const Size(620, 840));
    expect(t.desktop.settings.settingsWindowSize, isNull, reason: 'each kind of window keeps its own size');

    // Opened again later: at that size.
    state.closeMain();
    await tester.pump();
    shell.sizeNow = null;
    state.open(MainPage.home);
    await tester.pump();
    expect(shell.mainShows.last, const Size(620, 840));
  });

  testWidgets('Settings remembers its own size', (tester) async {
    final state = await show(tester, page: MainPage.settings);
    shell.sizeNow = const Size(1000, 720);
    shell.controller.add(ShellAction.windowResized);
    await tester.pump();
    await tester.pump();
    expect(t.desktop.settings.settingsWindowSize, const Size(1000, 720));
    expect(t.desktop.settings.mainWindowSize, isNull);
    state.open(MainPage.home);
    await tester.pump();
    expect(shell.mainShows.last, SurfaceSizes.main, reason: "Mochi's window keeps the default until you resize it");
    state.open(MainPage.settings);
    await tester.pump();
    expect(shell.mainShows.last, const Size(1000, 720));
  });

  testWidgets('a size below the minimum is never saved', (tester) async {
    await show(tester);
    shell.sizeNow = const Size(120, 90);
    shell.controller.add(ShellAction.windowResized);
    await tester.pump();
    await tester.pump();
    expect(t.desktop.settings.mainWindowSize, isNull);
  });

  test('saved window sizes survive a restart and silly values are ignored', () {
    final settings = t.desktop.settings
      ..mainWindowSize = const Size(600, 800)
      ..settingsWindowSize = const Size(1100, 760);
    final json = settings.toJson();
    expect(json['mainWindowSize'], [600.0, 800.0]);
    expect(json['settingsWindowSize'], [1100.0, 760.0]);
  });
}
