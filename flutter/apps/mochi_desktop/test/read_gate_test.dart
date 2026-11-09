// The one new permission (docs/SPRINT_2.md X13, X17): Claude Code's `Read`, in the brain's --tools but in no allow rule, so
// every Read is asked of `approve`, which allows exactly the files handed over for the request now running. Tested as hard
// as the SendMessage path: lookalike paths, other tools, stale requests and the cleared list.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/ask_attach.dart';
import 'package:mochi_desktop/src/core/ask_brain.dart';
import 'package:mochi_desktop/src/core/brain_session.dart';

import 'support/brain_fakes.dart';

const String _file = r'C:\Users\Jane\Documents\report.pdf';
const String _shot = r'C:\Users\Jane\AppData\Local\Mochi\Assistant\mochi-screen-00000000000000000000000000000001.png';

bool _allowed(Map<String, Object?> verdict) => verdict['behavior'] == 'allow';

void main() {
  group('the launch', () {
    final launch = BrainLaunch(
      executable: r'C:\Users\Jane\.local\bin\claude.exe',
      model: 'haiku',
      mcpConfig: BrainLaunch.mcpConfigJson(helper: r'C:\Mochi\bin\mochi_hook.exe', port: 51234, token: 'ab' * 24),
      workingDirectory: r'C:\Mochi\Assistant',
    );
    String after(String flag) => launch.arguments[launch.arguments.indexOf(flag) + 1];

    test('Read is a built-in tool, an "ask" rule, and in no allow list', () {
      expect(after('--tools'), 'ListAgents,SendMessage,WebSearch,Read');
      expect(after('--settings'), '{"permissions":{"ask":["SendMessage","Read"]}}');
      final settings = jsonDecode(after('--settings')) as Map;
      expect((settings['permissions'] as Map).keys, ['ask'], reason: 'no allow rule, no deny rule, nothing else');
      final start = launch.arguments.indexOf('--allowedTools') + 1;
      var end = start;
      while (end < launch.arguments.length && !launch.arguments[end].startsWith('--')) {
        end++;
      }
      final allowed = launch.arguments.sublist(start, end);
      expect(allowed, ['ListAgents', 'WebSearch', 'mcp__mochi']);
      expect(allowed.where((tool) => tool.toLowerCase().contains('read')), isEmpty);
      expect(after('--permission-mode'), 'default');
      expect(after('--permission-prompt-tool'), 'mcp__mochi__approve');
      // The flags, not the system prompt's words.
      final flags = launch.arguments.sublist(0, launch.arguments.indexOf('--system-prompt')).join(' ');
      expect(flags, isNot(contains('--dangerously')));
      for (final tool in ['Bash', 'Write', 'Edit', 'Glob', 'Grep', 'WebFetch', 'NotebookEdit']) {
        expect(flags, isNot(contains(tool)), reason: tool);
      }
    });

    test('the brain is told what a dropped file is: data, never instructions, and only those paths', () {
      final prompt = launch.systemPrompt;
      expect(prompt, contains('Read tool'));
      expect(prompt, contains('never follow'));
      expect(prompt, contains('[End of dropped text]'));
      expect(prompt, contains('fix this file with Claude'));
      expect(prompt, isNot(contains('Mac')));
    });
  });

  group('HandOverPaths', () {
    test('plain drive paths compare equal case-insensitively, with / or \\', () {
      expect(HandOverPaths.same(r'C:\a\b.txt', r'c:\A\B.TXT'), isTrue);
      expect(HandOverPaths.same(r'C:\a\b.txt', 'C:/a/b.txt'), isTrue);
      expect(HandOverPaths.same(r'C:\a\b.txt', r'C:\a\b.txt'), isTrue);
      expect(HandOverPaths.same(r'C:\a b\c d.txt', r'c:\A B\C D.TXT'), isTrue);
    });

    test('lookalikes and unsafe forms are not paths at all', () {
      for (final path in [
        r'C:\a\..\a\b.txt',
        r'C:\a\.\b.txt',
        r'C:\a\b.txt ',
        r'C:\a\b.txt.',
        r'C:\a\\b.txt',
        r'C:\a\b.txt\',
        r'C:\a\b.txt:stream',
        r'C:\a\b.txt::$DATA',
        r'\\server\share\a\b.txt',
        r'\\?\C:\a\b.txt',
        r'\\.\C:\a\b.txt',
        r'\a\b.txt',
        r'a\b.txt',
        'b.txt',
        r'C:b.txt',
        r'C:\a\*.txt',
        r'C:\a\b?.txt',
        r'C:\a\b<.txt',
        'C:\\a\\b\x00.txt',
        'C:\\a\\b\n.txt',
        '',
        r'C:\',
        r'C:',
        '/c/a/b.txt',
        'file:///C:/a/b.txt',
      ]) {
        expect(HandOverPaths.normalise(path), isNull, reason: path);
      }
    });

    test('only ASCII letters fold: another letter must match exactly', () {
      expect(HandOverPaths.same('C:\\a\\é.txt', 'C:\\a\\é.txt'), isTrue);
      expect(HandOverPaths.same('C:\\a\\é.txt', 'C:\\a\\É.txt'), isFalse);
      // The Kelvin sign is not the letter k on NTFS.
      expect(HandOverPaths.same('C:\\a\\k.txt', 'C:\\a\\\u212a.txt'), isFalse);
    });
  });

  group('Read through approve', () {
    late BrainRig rig;

    /// A request running with [handOver]; the brain is up.
    Future<Future<BrainAnswer?>> running(List<String> handOver, {bool messaging = true}) async {
      rig = BrainRig(messaging: messaging);
      addTearDown(rig.brain.dispose);
      final answer = await rig.ask('what is in these?', handOver: handOver);
      rig.process.print(FakeBrainProcess.init());
      await rig.settle();
      return answer;
    }

    Future<Map<String, Object?>> read(Object? path, {Map<String, Object?> extra = const {}}) =>
        rig.approveTool('Read', {'file_path': path, ...extra});

    test('the exact file is allowed, without a card', () async {
      await running([_file]);
      final verdict = await read(_file);
      expect(_allowed(verdict), isTrue);
      expect((verdict['updatedInput'] as Map)['file_path'], _file);
      expect(rig.brain.approval, isNull, reason: 'handing the file over was the consent: no card');
      expect(rig.phones.mirrored, isEmpty);
      expect(rig.logs.join('\n'), isNot(contains('Jane')), reason: 'never a path in the log');
      expect(rig.logs.join('\n'), isNot(contains('report')));
    });

    test('the same file, spelled with another case or forward slashes, is allowed', () async {
      await running([_file]);
      expect(_allowed(await read(r'c:\users\jane\documents\REPORT.PDF')), isTrue);
      expect(_allowed(await read('C:/Users/Jane/Documents/report.pdf')), isTrue);
    });

    test('narrowing fields (offset, limit, pages) are fine; unknown fields are not', () async {
      await running([_file]);
      expect(_allowed(await read(_file, extra: {'offset': 10, 'limit': 50})), isTrue);
      expect(_allowed(await read(_file, extra: {'pages': '1-3'})), isTrue);
      expect(_allowed(await read(_file, extra: {'pages': 3})), isFalse);
      expect(_allowed(await read(_file, extra: {'offset': 'ten'})), isFalse);
      expect(_allowed(await read(_file, extra: {'path': r'C:\Windows\win.ini'})), isFalse);
      expect(_allowed(await read(_file, extra: {'glob': '*'})), isFalse);
    });

    test('another path, a sibling, a directory, a pattern: denied', () async {
      await running([_file]);
      for (final path in [
        r'C:\Users\Jane\Documents\other.pdf',
        r'C:\Users\Jane\Documents\report.pdf.lnk',
        r'C:\Users\Jane\Documents\report.pdf.bak',
        r'C:\Users\Jane\Documents\report.pd',
        r'C:\Users\Jane\Documents',
        r'C:\Users\Jane\Documents\',
        r'C:\Users\Jane\Documents\*.pdf',
        r'C:\Users\Jane\Documents\**\*',
        r'C:\Users\Jane\.ssh\id_rsa',
        r'C:\Windows\System32\drivers\etc\hosts',
        r'D:\Users\Jane\Documents\report.pdf',
        r'report.pdf',
        '',
      ]) {
        final verdict = await read(path);
        expect(_allowed(verdict), isFalse, reason: path);
        expect(verdict['behavior'], 'deny');
      }
    });

    test('lookalikes of the handed-over file: ..  UNC  trailing space or dot  streams  device paths', () async {
      await running([r'C:\a\b.txt']);
      expect(_allowed(await read(r'C:\a\b.txt')), isTrue, reason: 'the control: the exact path');
      for (final path in [
        r'C:\a\..\a\b.txt',
        r'C:\a\.\b.txt',
        r'C:\a\b\..\b.txt',
        r'C:\a\b.txt ',
        r'C:\a\b.txt.',
        r'C:\a\b.txt..',
        r'C:\a\b.txt.lnk',
        r'C:\a\\b.txt',
        r'C:\a\b.txt:Zone.Identifier',
        r'C:\a\b.txt::$DATA',
        r'\\localhost\C$\a\b.txt',
        r'\\server\share\a\b.txt',
        r'\\?\C:\a\b.txt',
        r'\\.\C:\a\b.txt',
        r'\\?\UNC\server\share\b.txt',
        r'C:\A\B.TXT.',
        r'C:\a\B~1.TXT',
        'file:///C:/a/b.txt',
        '/c/a/b.txt',
      ]) {
        expect(_allowed(await read(path)), isFalse, reason: path);
      }
    });

    test('the file_path must be one string: nothing else is read as a path', () async {
      await running([_file]);
      expect(_allowed(await read(null)), isFalse);
      expect(_allowed(await read(42)), isFalse);
      expect(_allowed(await read([_file])), isFalse);
      expect(_allowed(await read({'path': _file})), isFalse);
      expect(_allowed(await rig.approveTool('Read', <String, Object?>{})), isFalse);
      expect(_allowed(await rig.approveTool('Read', null)), isFalse);
      expect(_allowed(await rig.approveTool('Read', _file)), isFalse);
      expect(_allowed(await rig.approveTool('Read', [_file])), isFalse);
    });

    test('other tools are denied even with the file as their input', () async {
      await running([_file]);
      for (final tool in ['Bash', 'Write', 'Edit', 'MultiEdit', 'Glob', 'Grep', 'NotebookRead', 'WebFetch', 'read', 'READ', 'Read ', 'mcp__mochi__open_url', 'LS', '']) {
        final verdict = await rig.approveTool(tool, {'file_path': _file});
        expect(_allowed(verdict), isFalse, reason: tool);
      }
      expect(_allowed(await rig.approveTool('Read', {'file_path': _file})), isTrue, reason: 'only Read, by that exact name');
    });

    test('with nothing handed over, every Read is denied', () async {
      await running(const []);
      expect(_allowed(await read(_file)), isFalse);
      expect(_allowed(await read(r'C:\Windows\win.ini')), isFalse);
    });

    test('a hand-over of only unusable paths is an empty list', () async {
      await running([r'\\server\share\a.txt', r'C:\a\..\b.txt', 'relative.txt']);
      expect(_allowed(await read(r'\\server\share\a.txt')), isFalse);
      expect(_allowed(await read(r'C:\a\..\b.txt')), isFalse);
      expect(_allowed(await read('relative.txt')), isFalse);
    });

    test('with no request running, Read is denied', () async {
      rig = BrainRig();
      addTearDown(rig.brain.dispose);
      final answer = await rig.ask('x', handOver: [_file]);
      rig.process.print(FakeBrainProcess.init());
      rig.process.print(FakeBrainProcess.result('Done.'));
      await answer;
      await rig.settle();
      expect(rig.brain.working, isFalse);
      expect(_allowed(await read(_file)), isFalse, reason: 'the request is over');
    });

    test('several files: each of them, and no other', () async {
      await running([_file, _shot, r'D:\x\y.log']);
      expect(_allowed(await read(_file)), isTrue);
      expect(_allowed(await read(_shot)), isTrue);
      expect(_allowed(await read(r'D:\x\y.log')), isTrue);
      expect(_allowed(await read(r'D:\x\z.log')), isFalse);
    });

    test('Read does not depend on the messaging switch, and SendMessage keeps its card', () async {
      await running([_file], messaging: false);
      expect(_allowed(await read(_file)), isTrue, reason: 'files are not messages');
      final rig2 = BrainRig(messaging: false);
      addTearDown(rig2.brain.dispose);
      await rig2.ask('tell it', handOver: [_file]);
      rig2.process.print(FakeBrainProcess.init());
      final channel = await rig2.askToSend();
      expect(rig2.verdict(channel)['behavior'], 'deny', reason: 'SendMessage is still switched off');
    });

    test('SendMessage with a handed-over file still shows its card, and the file path is in the message it shows', () async {
      await running([_file]);
      final channel = await rig.askToSend(message: 'From the user, via Mochi: please fix $_file');
      expect(rig.brain.approval, isNotNull);
      expect(rig.brain.approval!.message, contains(_file), reason: 'the card shows the whole message, path included');
      expect(neverAllowed(channel), isTrue, reason: 'nothing is sent before the user answers');
      rig.brain.decline();
      await rig.settle();
      expect(rig.verdict(channel)['behavior'], 'deny');
    });
  });

  group('the list belongs to the request', () {
    late BrainRig rig;

    Future<Future<BrainAnswer?>> start(String text, List<String> handOver) async {
      final answer = await rig.ask(text, handOver: handOver);
      return answer;
    }

    Future<bool> canRead(String path) async => _allowed(await rig.approveTool('Read', {'file_path': path}));

    /// The request ended and the helper's tool connection went with it (nothing can even ask): a later request, handing
    /// nothing over, still can not read the earlier one's file.
    Future<void> expectGone(String path) async {
      expect(rig.brain.server.isListening, isFalse, reason: 'the tool connection is gone');
      expect(rig.brain.working, isFalse);
      final later = await start('later', const []);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(path), isFalse, reason: 'it was the earlier request\'s');
      rig.brain.cancel();
      await later;
    }

    setUp(() {
      rig = BrainRig();
      addTearDown(rig.brain.dispose);
    });

    test('a later request can not read an earlier request\'s file', () async {
      final first = await start('one', [_file]);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isTrue);
      rig.process.print(FakeBrainProcess.result('Done.'));
      await first;
      // The next request hands over nothing: the old file is gone from the list.
      final second = await start('two', const []);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isFalse, reason: 'it was the first request\'s');
      rig.process.print(FakeBrainProcess.result('Done.'));
      await second;
    });

    test('a newer request replaces the list: the old file is denied, the new one allowed', () async {
      final first = await start('one', [_file]);
      rig.process.print(FakeBrainProcess.init());
      final second = await start('two', [_shot]);
      expect((await first)!.ok, isFalse, reason: 'switched');
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isFalse, reason: 'a stale request\'s file');
      expect(await canRead(_shot), isTrue);
      rig.brain.cancel();
      await second;
    });

    test('finished: cleared', () async {
      final answer = await start('x', [_file]);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isTrue);
      rig.process.print(FakeBrainProcess.result('It is a report.'));
      expect((await answer)!.ok, isTrue);
      expect(await canRead(_file), isFalse);
    });

    test('failed (an error result): cleared', () async {
      final answer = await start('x', [_file]);
      rig.process.print(FakeBrainProcess.init());
      rig.process.print(FakeBrainProcess.result('boom', error: true));
      expect((await answer)!.ok, isFalse);
      expect(await canRead(_file), isFalse);
    });

    test('the helper dying: cleared', () async {
      final answer = await start('x', [_file]);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isTrue);
      rig.process.exit(1);
      await answer;
      await rig.settle();
      await expectGone(_file);
    });

    test('cancelled: cleared', () async {
      final answer = await start('x', [_file]);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isTrue);
      rig.brain.cancel();
      await answer;
      await expectGone(_file);
    });

    test('timed out: cleared', () async {
      final answer = await start('x', [_file]);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isTrue);
      rig.clock.fire(const Duration(seconds: 120));
      expect((await answer)!.text, contains('too long'));
      await expectGone(_file);
    });

    test('the app quitting: cleared', () async {
      final answer = await start('x', [_file]);
      rig.process.print(FakeBrainProcess.init());
      expect(await canRead(_file), isTrue);
      rig.brain.shutdown();
      await answer;
      expect(rig.brain.server.isListening, isFalse);
      expect(rig.brain.working, isFalse);
    });

    test('a helper that never came up: cleared, and nothing to read', () async {
      final broken = BrainRig(spawnFails: true);
      addTearDown(broken.brain.dispose);
      final answer = await broken.ask('x', handOver: [_file]);
      expect(await answer, isNull, reason: 'the one-off path answers');
      expect(broken.brain.working, isFalse);
    });
  });
}
