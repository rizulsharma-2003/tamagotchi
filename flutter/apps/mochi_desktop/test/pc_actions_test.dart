// W9: Ask Mochi controls the PC. The matching and arithmetic, the brain's tools with their limits and the Settings switch,
// and the quick commands, all on fakes (the native side is checked on a Windows PC).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/ask_brain.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/core/brain_session.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/pc_actions.dart';
import 'package:mochi_desktop/src/core/quick_commands.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart' show ToggleRow;
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/brain_fakes.dart';
import 'support/fakes.dart';

const String _secret = 'Salary review Q4 - confidential';

/// A PC that records what it was asked and answers as the test says.
class FakePcPlatform implements PcPlatform {
  List<PcWindow> shown = [];
  List<PcApp>? installed = [];
  double? level = 0.5;
  bool muted = false;
  PcTasks mochiTasks = const PcTasks(PcTaskState.ok, ['Backup', 'Clean up']);
  PcTaskRun runResult = PcTaskRun.started;
  bool raiseWorks = true;
  bool launchWorks = true;
  final List<String> calls = [];

  @override
  List<PcWindow> windows() => shown;

  @override
  bool raise(int hwnd) {
    calls.add('raise $hwnd');
    return raiseWorks;
  }

  @override
  Future<List<PcApp>?> apps() async {
    calls.add('apps');
    return installed;
  }

  @override
  Future<bool> launch(String id) async {
    calls.add('launch $id');
    return launchWorks;
  }

  @override
  Future<bool> mediaKey(String key) async {
    calls.add('media $key');
    return true;
  }

  @override
  Future<double?> volume() async => level;

  @override
  Future<bool> setVolume(double value) async {
    calls.add('setVolume $value');
    level = value;
    return true;
  }

  @override
  Future<bool> setMuted(bool value) async {
    calls.add('setMuted $value');
    muted = value;
    return true;
  }

  @override
  Future<PcTasks> tasks() async => mochiTasks;

  @override
  Future<PcTaskRun> runTask(String name) async {
    calls.add('runTask $name');
    return runResult;
  }
}

/// A [PcActions] that only records what it was asked (for the routing tests).
class FakePcActions implements PcActions {
  final List<String> calls = [];
  List<String> installed = ['Slack', 'Visual Studio Code'];
  List<String> running = ['Google Chrome'];

  @override
  Future<List<String>> installedNames() async => installed;

  @override
  List<String> runningNames() => running;

  @override
  Future<PcResult> openApp(String name) async {
    calls.add('openApp $name');
    return PcResult('Opening $name.');
  }

  @override
  PcResult listApps() {
    calls.add('listApps');
    return const PcResult('Running: Google Chrome');
  }

  @override
  Future<PcResult> focusWindow({String? app, String? title}) async {
    calls.add('focusWindow ${app ?? '-'} ${title ?? '-'}');
    return const PcResult("Here's Google Chrome.");
  }

  @override
  Future<PcResult> media(String key) async {
    calls.add('media $key');
    return const PcResult('Pressed play/pause.');
  }

  @override
  Future<PcResult> volume({int? level, String? change}) async {
    calls.add('volume ${level ?? '-'} ${change ?? '-'}');
    return const PcResult('Volume 30%.');
  }

  @override
  Future<PcResult> runTask(String name) async {
    calls.add('runTask $name');
    return PcResult('Started “$name”.');
  }

  @override
  Future<PcResult> listTasks() async {
    calls.add('listTasks');
    return const PcResult('Backup');
  }
}

class _Url implements UrlOpener {
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}

PcWindow _window(int hwnd, String program, String title) => PcWindow(hwnd: hwnd, program: program, title: title);

void main() {
  group('matching a window by its title (the Mac\'s tokens and bestWindow)', () {
    test('words are lowercased, split on anything that is not a letter or digit, and the filler words dropped', () {
      expect(PcMatch.tokens('The Tamagotchi — my window'), ['tamagotchi']);
      expect(PcMatch.tokens('Résumé v2.docx - Word'), ['résumé', 'v2', 'docx', 'word']);
      expect(PcMatch.tokens('a the my app window'), isEmpty);
    });

    test('a window matches when it has all the words', () {
      final windows = [_window(1, 'Chrome', 'Inbox - Gmail'), _window(2, 'Code', 'main.dart - mac-Tamagotchi - Visual Studio Code')];
      expect(PcMatch.bestWindow('tamagotchi code', windows)!.hwnd, 2);
      expect(PcMatch.bestWindow('gmail', windows)!.hwnd, 1);
      expect(PcMatch.bestWindow('gmail tamagotchi', windows), isNull, reason: 'one of two is not enough');
      expect(PcMatch.bestWindow('nothing here', windows), isNull);
      expect(PcMatch.bestWindow('the window', windows), isNull, reason: 'no words left to look for');
    });

    test('with three or more words, all but one is enough; with two, it is not', () {
      final windows = [_window(1, 'Code', 'main.dart - mac-Tamagotchi - Visual Studio Code')];
      expect(PcMatch.bestWindow('main dart tamagotchi studio', windows)!.hwnd, 1);
      expect(PcMatch.bestWindow('main dart tamagotchi photoshop', windows)!.hwnd, 1, reason: '3 of 4');
      expect(PcMatch.bestWindow('main photoshop illustrator', windows), isNull, reason: '1 of 3');
      expect(PcMatch.bestWindow('main photoshop', windows), isNull, reason: '1 of 2');
    });

    test('words run together match too ("vs" inside "vscode"), the best score wins, the front window wins a tie', () {
      final windows = [
        _window(1, 'Code', 'notes.md - vscode'),
        _window(2, 'Chrome', 'notes - Google Docs'),
        _window(3, 'Edge', 'notes - Google Docs'),
      ];
      expect(PcMatch.bestWindow('vs', windows)!.hwnd, 1);
      expect(PcMatch.bestWindow('notes docs', windows)!.hwnd, 2, reason: 'the one in front of an equal one');
      expect(PcMatch.score(PcMatch.tokens('notes md vscode'), 'notes.md - vscode'), 3);
      expect(PcMatch.bestWindow('anything', [_window(4, 'X', '')]), isNull, reason: 'a window with no title is never matched');
    });
  });

  group('apps by name, and what is never opened', () {
    late FakePcPlatform pc;
    late PcActionsImpl actions;
    var clock = DateTime(2026, 11, 9, 10);

    setUp(() {
      clock = DateTime(2026, 11, 9, 10);
      pc = FakePcPlatform()
        ..installed = const [
          PcApp('Slack', 'com.slack'),
          PcApp('Visual Studio Code', 'Microsoft.VSCode'),
          PcApp('Uninstall Slack', 'uninstall-slack'),
          PcApp('Windows Setup Helper', 'setup-helper'),
          PcApp('Notes Installer', 'notes-installer'),
          PcApp('Repair Tool', 'repair'),
          PcApp('Reset Network', 'reset-net'),
          PcApp('Remove Adware', 'remove-adware'),
          PcApp('Cleanup', r'C:\tools\cleanup.bat'),
          PcApp('Tweaks', r'C:\tools\tweaks.PS1'),
          PcApp('Macro', r'C:\tools\macro.vbs'),
          PcApp('Pack', r'C:\tools\pack.msi'),
          PcApp('Merge', r'C:\tools\merge.reg'),
          PcApp('Helper Script', r'C:\tools\helper.js'),
          PcApp('Page', r'C:\tools\page.hta'),
          PcApp('Notepad', 'Microsoft.Notepad'),
        ];
      actions = PcActionsImpl(pc, clock: () => clock);
    });

    test('an installed app is opened by the id the PC listed, with the Mac\'s names for it', () async {
      expect((await actions.openApp('slack')).text, 'Opening Slack.');
      expect((await actions.openApp('vs code')).text, 'Opening Visual Studio Code.');
      expect((await actions.openApp('the Notepad app')).text, 'Opening Notepad.');
      expect(pc.calls.where((call) => call.startsWith('launch')), ['launch com.slack', 'launch Microsoft.VSCode', 'launch Microsoft.Notepad']);
    });

    test('uninstallers, installers, repair tools and scripts are not in the list, so they can\'t be opened by name', () async {
      for (final name in [
        'Uninstall Slack', 'Windows Setup Helper', 'Notes Installer', 'Repair Tool', 'Reset Network', 'Remove Adware', 'Cleanup', //
        'Tweaks', 'Macro', 'Pack', 'Merge', 'Helper Script', 'Page',
      ]) {
        final outcome = await actions.openApp(name);
        expect(outcome.ok, isFalse, reason: name);
        expect(outcome.text, startsWith('I couldn\'t find an app called'), reason: name);
      }
      expect((await actions.installedNames())..sort(), ['Notepad', 'Slack', 'Visual Studio Code']);
      expect(pc.calls.where((call) => call.startsWith('launch')), isEmpty);
      expect(PcMatch.openable('Slack', id: 'x'), isTrue);
      expect(PcMatch.openable('Slack uninstaller'), isFalse);
      expect(PcMatch.openable('Tool', id: 'RUN.CMD'), isFalse);
      expect(PcMatch.openable('Example website', id: r'{A77F5D77}\Example\Website.url'), isFalse);
      expect(PcMatch.openable('Example', id: 'http://example.com/'), isFalse);
      expect(PcMatch.openable('Calculator', id: 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'), isTrue);
    });

    test('an app that is already running is switched to, not started again', () async {
      pc.shown = [_window(7, 'Slack', '#general - Acme'), _window(8, 'Google Chrome', _secret)];
      final outcome = await actions.openApp('Slack');
      expect(outcome.text, 'Switched to Slack.');
      expect(pc.calls, ['raise 7']);
      pc.raiseWorks = false;
      final refused = await actions.openApp('chrome');
      expect(refused.ok, isFalse);
      expect(refused.text, 'Google Chrome is open, but Windows wouldn\'t bring it forward.');
    });

    test('a running program is found by its file name too, or a longer name inside its own (VM, 11-09)', () async {
      // Windows 11's Notepad describes itself as "Notepad.exe" (the platform drops the .exe) and Windows Terminal as
      // "Windows Terminal Host": "switch to notepad" opened a second Notepad on the VM before this.
      final notepad = PcWindow(hwnd: 7, program: 'Text editor', exe: 'Notepad', title: _secret);
      final terminal = PcWindow(hwnd: 8, program: 'Windows Terminal Host', exe: 'WindowsTerminal', title: _secret);
      pc.shown = [notepad, terminal];
      expect((await actions.openApp('notepad')).text, 'Switched to Text editor.');
      expect((await actions.openApp('windows terminal')).text, 'Switched to Windows Terminal Host.');
      expect((await actions.openApp('the terminal app')).text, 'Switched to Windows Terminal Host.');
      expect(pc.calls, ['raise 7', 'raise 8', 'raise 8']);
      expect(PcMatch.program('pad', [notepad, terminal]), isNull);
      expect(PcMatch.program('slack', [notepad, terminal]), isNull);
    });

    test('an unknown app says so, and the app list is kept for a minute', () async {
      final outcome = await actions.openApp('the pod bay doors');
      expect(outcome.ok, isFalse);
      expect(outcome.text, 'I couldn\'t find an app called “the pod bay doors”.');
      await actions.installedNames();
      expect(pc.calls.where((call) => call == 'apps'), hasLength(1));
      clock = clock.add(const Duration(seconds: 61));
      await actions.installedNames();
      expect(pc.calls.where((call) => call == 'apps'), hasLength(2));
    });

    test('a failed launch is said, an unreadable list opens nothing', () async {
      pc.launchWorks = false;
      expect((await actions.openApp('slack')).ok, isFalse);
      pc.installed = null;
      expect((await PcActionsImpl(pc).openApp('slack')).ok, isFalse);
    });
  });

  group('windows: titles stay on the PC', () {
    late FakePcPlatform pc;
    late PcActionsImpl actions;

    setUp(() {
      pc = FakePcPlatform()
        ..shown = [
          _window(1, 'Google Chrome', _secret),
          _window(2, 'Visual Studio Code', 'dispatch.dart - mac-Tamagotchi - Visual Studio Code'),
          _window(3, 'Slack', '#general - Acme'),
        ];
      actions = PcActionsImpl(pc);
    });

    test('list_apps names programs, never titles', () {
      final text = actions.listApps().text;
      expect(text, 'Running: Google Chrome, Slack, Visual Studio Code');
      expect(text, isNot(contains('confidential')));
      expect(text, isNot(contains('general')));
    });

    test('focus_window raises the best match and names only the program', () async {
      final outcome = await actions.focusWindow(title: 'salary review');
      expect(outcome.text, 'Here\'s Google Chrome.');
      expect(pc.calls, ['raise 1']);
      expect(outcome.text, isNot(contains('Salary')));
      pc.calls.clear();
      final inApp = await actions.focusWindow(app: 'code', title: 'mac tamagotchi');
      expect(inApp.text, 'Here\'s Visual Studio Code.');
      expect(pc.calls, ['raise 2']);
    });

    test('app only: switched to; title that matches nothing: switched to the app, or not found, and never a title', () async {
      expect((await actions.focusWindow(app: 'slack')).text, 'Switched to Slack.');
      final none = await actions.focusWindow(app: 'slack', title: 'budget forecast');
      expect(none.text, 'Switched to Slack, but no window matched.');
      final nowhere = await actions.focusWindow(title: 'budget forecast');
      expect(nowhere.ok, isFalse);
      expect(nowhere.text, 'I couldn\'t find a matching window.');
      for (final text in [none.text, nowhere.text]) {
        expect(text, isNot(contains('budget')));
      }
      expect((await actions.focusWindow()).text, 'Which window should I look for?');
      pc.calls.clear();
      // An app that is not running and no title: open it.
      pc.installed = const [PcApp('Notepad', 'Microsoft.Notepad')];
      expect((await actions.focusWindow(app: 'notepad')).text, 'Opening Notepad.');
    });
  });

  group('volume: the Mac\'s steps of ten, 0 to 100, and sound on when there is sound', () {
    late FakePcPlatform pc;
    late PcActionsImpl actions;
    setUp(() {
      pc = FakePcPlatform();
      actions = PcActionsImpl(pc);
    });

    test('up and down move by ten points and stop at the ends', () async {
      pc.level = 0.55;
      expect((await actions.volume(change: 'up')).text, 'Volume 65%.');
      expect((await actions.volume(change: 'down')).text, 'Volume 55%.');
      pc.level = 0.95;
      expect((await actions.volume(change: 'up')).text, 'Volume 100%.');
      pc.level = 0.05;
      expect((await actions.volume(change: 'down')).text, 'Volume 0%.');
      pc.level = 0.5;
      expect((await actions.volume()).text, 'Volume 60%.', reason: 'up when nothing else is said');
      expect(PcMatch.step('up', 1), 1.0);
      expect(PcMatch.step('down', 0), 0.0);
    });

    test('a level is clamped to 0 to 100', () async {
      expect((await actions.volume(level: 30)).text, 'Volume 30%.');
      expect(pc.level, closeTo(0.3, 1e-9));
      expect((await actions.volume(level: 250)).text, 'Volume 100%.');
      expect(pc.level, 1.0);
      expect((await actions.volume(level: -20)).text, 'Volume 0%.');
      expect(pc.level, 0.0);
      expect(PcMatch.clampLevel(101), 100);
      expect(PcMatch.clampLevel(-1), 0);
    });

    test('going above zero unmutes; going to zero does not; mute and unmute are their own', () async {
      pc.muted = true;
      await actions.volume(level: 40);
      expect(pc.muted, isFalse);
      pc.calls.clear();
      pc.muted = true;
      await actions.volume(level: 0);
      expect(pc.calls, ['setVolume 0.0']);
      expect((await actions.volume(change: 'mute')).text, 'Muted.');
      expect(pc.muted, isTrue);
      expect((await actions.volume(change: 'unmute')).text, 'Sound\'s back on.');
      expect(pc.muted, isFalse);
    });

    test('an output whose volume can\'t be read can\'t be stepped', () async {
      pc.level = null;
      final outcome = await actions.volume(change: 'up');
      expect(outcome.ok, isFalse);
      expect(pc.calls.where((call) => call.startsWith('setVolume')), isEmpty);
    });
  });

  group('tasks: only the Mochi folder, only by name', () {
    late FakePcPlatform pc;
    late PcActionsImpl actions;
    setUp(() {
      pc = FakePcPlatform();
      actions = PcActionsImpl(pc);
    });

    test('names with a slash or a backslash, dots or control characters never reach the PC', () async {
      for (final name in [r'\Microsoft\Windows\Defrag', 'Mochi/Backup', r'..\Backup', '../Backup', '..', '.', 'a\nb', r'\Mochi\Backup']) {
        final outcome = await actions.runTask(name);
        expect(outcome.ok, isFalse, reason: name);
        expect(outcome.text, contains('only run tasks by their name from your Mochi folder'), reason: name);
      }
      expect((await actions.runTask('  ')).ok, isFalse);
      expect(pc.calls, isEmpty);
      expect(PcMatch.plainTaskName('Backup my files'), isTrue);
      expect(PcMatch.plainTaskName('x' * 257), isFalse);
    });

    test('a task is started by its name and the reply does not wait for it to finish', () async {
      final outcome = await actions.runTask('Backup');
      expect(outcome.text, 'Started “Backup”.');
      expect(outcome.ok, isTrue);
      expect(pc.calls, ['runTask Backup']);
      pc.runResult = PcTaskRun.notFound;
      expect((await actions.runTask('Nope')).text, 'There is no task called “Nope” in your Mochi folder.');
      pc.runResult = PcTaskRun.failed;
      expect((await actions.runTask('Backup')).ok, isFalse);
    });

    test('a missing folder says how to make it', () async {
      pc.mochiTasks = const PcTasks(PcTaskState.noFolder);
      final listed = await actions.listTasks();
      expect(listed.text, contains('create a folder called Mochi'));
      expect(listed.text, contains('Task Scheduler'));
      pc.runResult = PcTaskRun.noFolder;
      final ran = await actions.runTask('Backup');
      expect(ran.ok, isFalse);
      expect(ran.text, contains('create a folder called Mochi'));
    });

    test('list_tasks lists names, sorted, and says when there are none', () async {
      expect((await actions.listTasks()).text, 'Tasks in your Mochi folder: Backup, Clean up.');
      pc.mochiTasks = const PcTasks(PcTaskState.ok);
      expect((await actions.listTasks()).text, 'There are no tasks in your Mochi folder yet.');
      pc.mochiTasks = const PcTasks(PcTaskState.failed);
      expect((await actions.listTasks()).ok, isFalse);
    });

    test('the music keys: three words and nothing else', () async {
      expect((await actions.media('playPause')).text, 'Pressed play/pause.');
      expect((await actions.media('next')).text, 'Skipped ahead.');
      expect((await actions.media('previous')).text, 'Went back a track.');
      expect(pc.calls, ['media playPause', 'media next', 'media previous']);
    });
  });

  group('the brain\'s tools', () {
    late BrainRig rig;
    late FakePcActions pc;
    late AskMochi ask;
    late bool allowed;
    late _Url urls;
    var calls = 0;

    setUp(() {
      calls = 0;
      allowed = true;
      rig = BrainRig();
      addTearDown(rig.brain.dispose);
      pc = FakePcActions();
      urls = _Url();
      ask = AskMochi(
        sessions: rig.sessions,
        runner: () => null,
        cue: (_) {},
        brainFactory: (self) => rig.brain,
        opener: urls,
        pc: pc,
        pcAllowed: () => allowed,
        log: rig.logs.add,
        clock: () => DateTime(2026, 11, 9, 10),
      );
      rig.tools = ask.brainTool;
    });

    /// Starts a request and lets the brain come up, with a connection ready for its tool calls.
    Future<(Future<BrainAnswer?>, FakeChannel)> startRequest(String text) async {
      final answer = await rig.ask(text);
      rig.process.print(FakeBrainProcess.init());
      await rig.settle();
      return (answer, rig.connect());
    }

    Future<({String text, bool isError})> call(FakeChannel channel, String tool, [Map<String, Object?> arguments = const {}]) async {
      channel.send(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': ++calls,
          'method': 'tools/call',
          'params': {'name': tool, 'arguments': arguments},
        }),
      );
      await rig.settle();
      final result = channel.replies.last['result'] as Map;
      return (text: ((result['content'] as List).single as Map)['text'] as String, isError: result['isError'] == true);
    }

    test('each tool reaches the PC with its arguments and answers in words', () async {
      final (answer, channel) = await startRequest('do things');
      expect((await call(channel, 'open_app', {'name': 'Slack'})).text, 'Opening Slack.');
      expect((await call(channel, 'list_apps')).text, 'Running: Google Chrome');
      expect((await call(channel, 'focus_window', {'app': 'chrome', 'title': 'inbox'})).text, "Here's Google Chrome.");
      expect((await call(channel, 'media', {'action': 'next'})).text, 'Pressed play/pause.');
      expect((await call(channel, 'set_volume', {'level': 29.6})).text, 'Volume 30%.');
      expect((await call(channel, 'list_tasks')).text, 'Backup');
      expect(pc.calls, ['openApp Slack', 'listApps', 'focusWindow chrome inbox', 'media next', 'volume 30 -', 'listTasks']);
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
    });

    test('media and volume default as the Mac\'s do; a task is run by name', () async {
      final (answer, channel) = await startRequest('x');
      await call(channel, 'media', {'action': 'something else'});
      await call(channel, 'set_volume', {'change': 'mute'});
      await call(channel, 'set_volume', {'level': 'loud', 'change': 'down'});
      await call(channel, 'run_task', {'name': 'Backup'});
      expect(pc.calls, ['media playPause', 'volume - mute', 'volume - down', 'runTask Backup']);
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
    });

    test('show_project looks for the project\'s folder name when it knows the session, else the words given', () async {
      rig.sessions.apply(hook('UserPromptSubmit', project: 'mac-Tamagotchi', session: 's9'));
      final (answer, channel) = await startRequest('show my project');
      await call(channel, 'show_project', {'project': 'mac-tamagotchi-bb [856803]'});
      await call(channel, 'show_project', {'project': 'MAC-TAMAGOTCHI'});
      await call(channel, 'show_project', {'project': 'my blog'});
      expect(pc.calls, ['focusWindow - mac-Tamagotchi', 'focusWindow - mac-Tamagotchi', 'focusWindow - my blog']);
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
    });

    test('at most five PC actions per request: the sixth is refused, the lists and tricks don\'t count, the next request starts again', () async {
      var (answer, channel) = await startRequest('open lots of things');
      for (var i = 0; i < 5; i++) {
        expect((await call(channel, 'open_app', {'name': 'Slack $i'})).isError, isFalse);
      }
      // These don't count.
      expect((await call(channel, 'list_apps')).isError, isFalse);
      expect((await call(channel, 'list_tasks')).isError, isFalse);
      expect((await call(channel, 'claude_sessions')).isError, isFalse);
      expect((await call(channel, 'mochi', {'action': 'pet'})).isError, isFalse);
      final sixth = await call(channel, 'open_app', {'name': 'Slack 5'});
      expect(sixth.isError, isTrue);
      expect(sixth.text, "That's a lot at once, so I stopped. Ask me again.");
      // Every kind of PC action counts, so the sixth of any is refused.
      for (final (tool, arguments) in <(String, Map<String, Object?>)>[
        ('open_url', {'url': 'https://example.com'}),
        ('focus_window', {'title': 'x'}),
        ('show_project', {'project': 'x'}),
        ('media', {'action': 'next'}),
        ('set_volume', {'change': 'up'}),
        ('run_task', {'name': 'Backup'}),
      ]) {
        expect((await call(channel, tool, arguments)).isError, isTrue, reason: tool);
      }
      expect(pc.calls.where((c) => c.startsWith('openApp')), hasLength(5));
      expect(urls.opened, isEmpty);
      expect(rig.logs, contains('brain: action limit reached'));
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;

      // The next request has five again.
      pc.calls.clear();
      (answer, channel) = await startRequest('one more');
      final again = await call(channel, 'open_app', {'name': 'Slack'});
      expect(again.isError, isFalse);
      expect(again.text, 'Opening Slack.');
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
    });

    test('a PC action with no request being answered is refused', () async {
      final (answer, channel) = await startRequest('x');
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
      final late = await call(channel, 'open_app', {'name': 'Slack'});
      expect(late.isError, isTrue);
      expect(pc.calls, isEmpty);
    });

    test('the log says which tool and whether it worked, never what it was asked', () async {
      final (answer, channel) = await startRequest('x');
      await call(channel, 'open_app', {'name': 'Secret Project Tool'});
      await call(channel, 'run_task', {'name': 'Wipe the quarterly report'});
      await call(channel, 'open_url', {'url': 'http://not-https.example'});
      final logs = rig.logs.join('\n');
      expect(logs, contains('brain: action open_app ok'));
      expect(logs, contains('brain: action run_task ok'));
      expect(logs, contains('brain: action open_url failed'));
      for (final word in ['Secret', 'quarterly', 'example', 'Wipe']) {
        expect(logs, isNot(contains(word)));
      }
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
    });

    test('with "Let Mochi use my PC" off every PC tool, and open_url, says so and does nothing', () async {
      allowed = false;
      final (answer, channel) = await startRequest('x');
      for (final (tool, arguments) in <(String, Map<String, Object?>)>[
        ('open_app', {'name': 'Slack'}),
        ('list_apps', {}),
        ('focus_window', {'title': 'x'}),
        ('show_project', {'project': 'x'}),
        ('media', {'action': 'next'}),
        ('set_volume', {'change': 'up'}),
        ('list_tasks', {}),
      ]) {
        final result = await call(channel, tool, arguments);
        expect(result.isError, isTrue, reason: tool);
        expect(result.text, 'PC control is off in Settings › Assistant.', reason: tool);
      }
      // Mochi's own tricks and the sessions still work.
      expect((await call(channel, 'claude_sessions')).isError, isFalse);
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
      // (The five-action limit counts the refused ones too, so the rest is asked in the next request.)
      final (second, again) = await startRequest('y');
      for (final (tool, arguments) in <(String, Map<String, Object?>)>[
        ('run_task', {'name': 'Backup'}),
        ('open_url', {'url': 'https://example.com'}),
      ]) {
        final result = await call(again, tool, arguments);
        expect(result.isError, isTrue, reason: tool);
        expect(result.text, 'PC control is off in Settings › Assistant.', reason: tool);
      }
      expect(pc.calls, isEmpty);
      expect(urls.opened, isEmpty);
      rig.process.print(FakeBrainProcess.result('Done.'));
      await second;
    });

    test('step lines say what is happening and never a window title, a task name or a path', () {
      String? step(String tool, Map<String, Object?> input) => BrainStep.describe('mcp__mochi__$tool', input);
      expect(step('open_app', {'name': 'Slack'}), 'Opening Slack');
      expect(step('focus_window', {'app': 'chrome', 'title': _secret}), 'Bringing a window forward');
      expect(step('show_project', {'project': _secret}), 'Bringing a window forward');
      expect(step('media', {'action': 'play_pause'}), 'Pressing play/pause');
      expect(step('set_volume', {'level': 30}), 'Changing the volume');
      expect(step('run_task', {'name': 'Wipe the quarterly report'}), 'Running a task');
      for (final tool in ['open_app', 'list_apps', 'focus_window', 'show_project', 'media', 'set_volume', 'run_task', 'list_tasks']) {
        final line = step(tool, {'title': _secret, 'project': _secret, 'name': 'Wipe the quarterly report', 'app': r'C:\Users\Jane\x.exe'});
        expect(line, isNotNull, reason: tool);
        expect(line, isNot(contains('confidential')), reason: tool);
        if (tool != 'open_app') expect(line, isNot(contains('Wipe')), reason: tool);
        expect(line, isNot(contains('Jane')), reason: tool);
      }
    });

    test('a window title is never in what a tool returns, even when the PC could have said it', () async {
      final platform = FakePcPlatform()..shown = [_window(1, 'Google Chrome', _secret)];
      final real = AskMochi(sessions: rig.sessions, runner: () => null, cue: (_) {}, brainFactory: (self) => rig.brain, pc: PcActionsImpl(platform));
      rig.tools = real.brainTool;
      final (answer, channel) = await startRequest('x');
      for (final (tool, arguments) in <(String, Map<String, Object?>)>[
        ('list_apps', {}),
        ('focus_window', {'title': 'salary'}),
        ('focus_window', {'app': 'chrome', 'title': 'salary review confidential'}),
        ('focus_window', {'title': 'nothing like it'}),
        ('show_project', {'project': 'salary review'}),
        ('open_app', {'name': 'chrome'}),
      ]) {
        final result = await call(channel, tool, arguments);
        expect(result.text, isNot(contains('Salary')), reason: tool);
        expect(result.text, isNot(contains('confidential')), reason: tool);
      }
      rig.process.print(FakeBrainProcess.toolUse('t1', 'mcp__mochi__focus_window', {'title': _secret}));
      await rig.settle();
      expect(rig.brain.steps.map((step) => step.text), contains('Bringing a window forward'));
      expect(rig.brain.steps.map((step) => step.text).join(' '), isNot(contains('Salary')));
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
    });
  });

  group('quick commands', () {
    late AskMochi ask;
    late FakePcActions pc;
    late _Url urls;
    late bool allowed;

    setUp(() {
      allowed = true;
      pc = FakePcActions();
      urls = _Url();
      ask = AskMochi(sessions: BrainRig().sessions, runner: () => null, cue: (_) {}, opener: urls, pc: pc, pcAllowed: () => allowed);
    });

    test('music keys, volume and apps go to the PC, with no Claude', () async {
      expect((await ask.ask('pause')).text, 'Pressed play/pause.');
      await ask.ask('next song');
      await ask.ask('previous track');
      expect((await ask.ask('volume 30')).text, 'Volume 30%.');
      await ask.ask('louder');
      await ask.ask('mute');
      await ask.ask('unmute');
      expect((await ask.ask('open slack')).text, 'Opening Slack.');
      await ask.ask('open vs code');
      expect(pc.calls, [
        'media playPause',
        'media next',
        'media previous',
        'volume 30 -',
        'volume - up',
        'volume - mute',
        'volume - unmute',
        'openApp Slack',
        'openApp Visual Studio Code',
      ]);
    });

    test('switching to a running app is the same action, which switches to it', () async {
      expect((await ask.perform(const AppCommand('Google Chrome', running: true))).text, 'Opening Google Chrome.');
      await ask.ask('switch to chrome');
      expect(pc.calls, ['openApp Google Chrome', 'openApp Google Chrome']);
    });

    test('"open github" is still a link when no app has that name, and an app when one does', () async {
      await ask.ask('open github');
      expect(urls.opened, [Uri.parse('https://github.com')]);
      pc.installed = ['GitHub'];
      await ask.ask('open github');
      expect(pc.calls, ['openApp GitHub']);
      expect(urls.opened, hasLength(1));
    });

    test('with the switch off they say so and do nothing, links included', () async {
      allowed = false;
      for (final words in ['pause', 'volume up', 'open github', 'mute']) {
        final outcome = await ask.ask(words);
        expect(outcome.ok, isFalse, reason: words);
        expect(outcome.text, 'PC control is off in Settings › Assistant.', reason: words);
      }
      // "open slack" isn't known to be an app while the PC's list is not read, so it is left to the brain, whose tool refuses.
      await ask.ask('open slack');
      expect(pc.calls, isEmpty);
      expect(urls.opened, isEmpty);
      // The rest of Ask Mochi still answers.
      expect((await ask.ask('pet')).text, 'Purr…');
    });

    test('without a PC (the macOS development build) they say it can\'t be done here', () async {
      final plain = AskMochi(sessions: BrainRig().sessions, runner: () => null, cue: (_) {});
      final outcome = await plain.ask('volume up');
      expect(outcome.ok, isFalse);
      expect(outcome.text, "I can't do that on this PC yet.");
    });

    test('the quick command parser still gives the same commands', () {
      expect(QuickCommands.parse('pause'), const MediaCommand('playPause'));
      expect(QuickCommands.parse('volume to 250'), const VolumeCommand(level: 100));
    });
  });

  group('the settings switch', () {
    test('on at first, saved when turned off', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document);
      expect(settings.pcControl, isTrue);
      settings.pcControl = false;
      expect(document.json!['pcControl'], false);
      expect(DesktopSettings(MemorySettingsDocument(document.json)).pcControl, isFalse);
      settings.pcControl = true;
      expect(DesktopSettings(MemorySettingsDocument(document.json)).pcControl, isTrue);
    });

    late TestDesktop t;
    setUp(() => t = TestDesktop.make(clock: () => DateTime(2026, 11, 9, 12)));
    tearDown(() => t.dispose());

    testWidgets('Settings › Assistant has "Let Mochi use my PC", on, and it turns off and on', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          library: Future<PoseLibrary?>.value(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.assistant,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final row = find.text('Let Mochi use my PC');
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      expect(find.text('Open apps and links, bring windows forward, music and volume'), findsOneWidget);
      final toggle = find.descendant(
        of: find.ancestor(of: row, matching: find.byType(ToggleRow)),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pump();
      expect(t.desktop.settings.pcControl, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect(t.desktop.settings.pcControl, isTrue);
    });
  });
}
