// A stand-in Mac for trying Mochi for Android against a real relay, in a throwaway room of its own (never anyone's
// real room). It creates the room as `host`, prints a pairing link for the phone, shares sample state (the look,
// Claude working, sessions and "Waiting for you" from link-spec/fixtures), answers every command with a reply, and
// sends sealed alerts. The room is deleted when it quits (`quit`, Ctrl-C, or after --minutes).
//
//   cd flutter/apps/mochi_pocket
//   dart run tool/fake_mac.dart --relay mochi-link.spike01.workers.dev [--control <file>] [--link-file <file>]
//       [--credentials <file>] [--pocket-credentials <file>] [--minutes 45] [--alert-on-join]
//   adb shell am start -a android.intent.action.VIEW -d '<the printed link>'
//
// --pocket-credentials makes a `pocket` device in the room as well and keeps its credentials in that file, for a debug
// build's DebugActionRoom (notification buttons tried end to end without pairing the phone away from its real room):
//   adb push <file> /data/local/tmp/mochi-room.json
//   adb shell run-as com.insideedge.mochi cp /data/local/tmp/mochi-room.json files/debug_action_room.json
//   adb shell rm /data/local/tmp/mochi-room.json
// then start the app once, so it registers for pushes in this room too.
//
// While it runs, append commands to the --control file (one per line):
//   alert [text]                a sealed alert to the phones
//   turn [text]                 "Claude finished" as the Mac sends it (Reply in the notification)
//   news                        Mochi's news about two new emails, with the card (Mark both done)
//   meeting                     a meeting heads-up with a video link, as Mochi Cloud sends it (Join, Mark done)
//   draft                       "Reply drafted", as Mochi Cloud sends it (Open in Gmail)
//   approval                    "Send to Claude?" for session-1
//   claude <phase> [category]   working · waiting · done · error · idle (category: think, edit, read, shell, …)
//   rest | wake                 the Mac rests (Mochi sleeps) or is in use again
//   pet | play | treat          a pet, play or treat from the Mac
//   away | back                 the Mac disconnects (the phone shows "Mac away") or comes back
//   invite                      a fresh pairing link
//   quit                        delete the room and exit
//
// `dart run tool/fake_mac.dart --delete <credentials file>` deletes a room left behind by a run that was killed.
//
// It prints the pairing link (that's its job) but never the room's credentials; --credentials keeps them in a file of
// your choosing (outside the repository) only so a stray room can be deleted.

// A command-line tool: printing is how it talks.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart';

Future<void> main(List<String> arguments) async {
  final options = _options(arguments);
  final deleting = options['delete'];
  if (deleting != null) {
    final saved = LinkCredentials.decode(await File(deleting).readAsString());
    if (saved == null) throw ArgumentError('No credentials in $deleting');
    await LinkPairing.deleteRoom(saved);
    await File(deleting).delete();
    print('Deleted the room.');
    return;
  }
  final relay = options['relay'] ?? 'mochi-link.spike01.workers.dev';
  final fake = FakeMac(
    relay: relay,
    name: options['name'] ?? 'Test Mac',
    control: options['control'],
    linkFile: options['link-file'],
    credentialsFile: options['credentials'],
    pocketFile: options['pocket-credentials'],
    alertOnJoin: options.containsKey('alert-on-join'),
  );
  await fake.start();
  final minutes = int.tryParse(options['minutes'] ?? '') ?? 45;
  Timer(Duration(minutes: minutes), () => fake.quit('time is up ($minutes minutes)'));
  ProcessSignal.sigint.watch().listen((_) => fake.quit('interrupted'));
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) => fake.quit('terminated'));
}

Map<String, String> _options(List<String> arguments) {
  final options = <String, String>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) continue;
    final name = argument.substring(2);
    final hasValue = i + 1 < arguments.length && !arguments[i + 1].startsWith('--');
    options[name] = hasValue ? arguments[++i] : '';
  }
  return options;
}

double _now() => DateTime.now().millisecondsSinceEpoch / 1000;

class FakeMac {
  FakeMac({
    required this.relay,
    required this.name,
    this.control,
    this.linkFile,
    this.credentialsFile,
    this.pocketFile,
    this.alertOnJoin = false,
  });

  final String relay;
  final String name;
  final String? control;
  final String? linkFile;
  final String? credentialsFile;
  final String? pocketFile;
  final bool alertOnJoin;

  late LinkCredentials _host;
  RelayLink? _link;
  final Set<String> _pocketsSeen = {};
  int _controlRead = 0;
  bool _quitting = false;
  Map<String, Object?> _fixtures = {};

  Future<void> start() async {
    _fixtures = await _loadFixtures();
    _host = await LinkPairing.createRoom(relay: relay, platform: 'macOS', name: '$name (fake_mac.dart)');
    final saveTo = credentialsFile;
    if (saveTo != null) await File(saveTo).writeAsString(_host.encode());
    print('Made a throwaway room on $relay.');
    final pocketPath = pocketFile;
    if (pocketPath != null) {
      final code = await LinkPairing.invite(_host, hostName: name, role: 'pocket');
      final pocket = await LinkPairing.join(code, role: 'pocket', platform: 'android', name: 'Mochi action test');
      await File(pocketPath).writeAsString(pocket.encode());
      print('Made a test pocket in the room; its credentials are in $pocketPath.');
    }
    await invite();
    _connect();
    _share();
    final controlPath = control;
    if (controlPath != null) {
      final file = File(controlPath);
      if (!file.existsSync()) file.writeAsStringSync('');
      _controlRead = file.lengthSync();
      Timer.periodic(const Duration(milliseconds: 300), (_) => _readControl(file));
      print('Reading commands from $controlPath.');
    }
  }

  Future<void> invite() async {
    final code = await LinkPairing.invite(_host, hostName: name, role: 'pocket');
    print('Pairing link (single use, 10 minutes):');
    print(code.url);
    final file = linkFile;
    if (file != null) await File(file).writeAsString(code.url);
  }

  void _connect() {
    final link = RelayLink(_host, platform: 'macOS', app: 'fake_mac', onLog: (message) => print('  link: $message'));
    _link = link;
    link.incoming.listen(_received);
    link.changes.listen((keys) {
      if (keys.contains(LinkKey.phoneDone)) {
        print('phone marked done: ${AgentDoneList.fromValue(link.value(LinkKey.phoneDone))?.ids.keys.join(', ')}');
      }
    });
    link.presence.listen((presence) {
      for (final peer in presence.peers.where((peer) => peer.role == 'pocket')) {
        if (peer.online && _pocketsSeen.add(peer.device)) {
          print('a phone is here: ${peer.name ?? peer.device} (${peer.platform ?? '?'})');
          if (alertOnJoin) Timer(const Duration(seconds: 4), () => alert('Hello from the fake Mac 👋'));
        }
      }
    });
    link.errors.listen((error) => print('relay refused: $error'));
    link.start();
  }

  /// The sample state, from link-spec/fixtures with fresh times and a few more items.
  void _share() {
    final link = _link!;
    final now = _now();
    final look = PetLook.fromJson(_fixture('look'))!;
    link.set(look.toValue(), LinkKey.look);
    link.set(ClaudeMirror(phase: 'working', category: 'edit', at: now).toValue(), LinkKey.claude);
    final fixtureSessions = PhoneSessions.fromJson(_fixture('sessions'))!;
    final first = fixtureSessions.sessions.first;
    link.set(
      PhoneSessions(
        enabled: true,
        updatedAt: now,
        sessions: [
          PhoneSessionCard(id: 'session-2', project: 'mochi-link', phase: 'working', files: const [], phaseSince: now - 120),
          PhoneSessionCard(
            id: first.id,
            project: first.project,
            phase: first.phase,
            summary: const TurnSummary(
              done: 'Gave Mochi its own voice and made Siri read reliably.',
              session: 'Mochi Pocket voice and Siri',
              next: ['Push it', 'Run the tests'],
            ),
            files: const ['KokoroVoice.swift', 'UpdatesReader.swift'],
            finishedAt: now - 600,
            phaseSince: now - 600,
          ),
        ],
      ).toValue(),
      LinkKey.sessions,
    );
    final agent = AgentPending.fromJson(_fixture('agent'))!;
    link.set(
      AgentPending(
        enabled: true,
        headline: 'A busy afternoon: the design review is at 4, and ${agent.headline}',
        lookedAt: now - 300,
        updatedAt: now - 300,
        items: [
          AgentNote(
            id: 'cal:review',
            source: AgentSource.calendar,
            title: 'Design review',
            detail: 'With Aditi and Sam · Google Meet',
            important: true,
            at: now,
            due: now + 2 * 3600,
            link: 'https://meet.google.com/abc-defg-hij',
          ),
          for (final item in agent.items)
            AgentNote(
              id: item.id,
              source: item.source,
              title: item.title,
              detail: item.detail,
              important: item.important,
              at: now - 1800,
              link: item.link,
              subject: item.subject,
              vip: item.vip,
            ),
          AgentNote(
            id: 'notion:checklist',
            source: AgentSource.notion,
            title: 'Finish the launch checklist',
            detail: 'Due today · Product',
            important: false,
            at: now - 7200,
            due: now + 5 * 3600,
            link: 'https://www.notion.so',
          ),
          AgentNote(
            id: 'mail:github',
            source: AgentSource.gmail,
            title: 'GitHub',
            detail: '1 new commit pushed to main.',
            important: false,
            at: now - 9000,
            link: 'https://mail.google.com/mail/u/0/#inbox/github',
            subject: '[tamagotchi] Mochi for Android',
          ),
          AgentNote(
            id: 'mail:aditi',
            source: AgentSource.gmail,
            title: 'Aditi Rao',
            detail: 'Shared the new onboarding flow; would love your notes before Friday.',
            important: true,
            at: now - 3600,
            link: 'https://mail.google.com/mail/u/0/#inbox/aditi',
            subject: 'Onboarding v2 for review',
          ),
        ],
      ).toValue(),
      LinkKey.agent,
    );
    print('Shared the look, Claude (working), two sessions and five things waiting.');
  }

  void _received(LinkIncoming message) {
    final link = _link!;
    switch (message.key) {
      case LinkKey.command:
        final command = LinkCommand.fromValue(message.value);
        if (command == null) return;
        final to = command.project == null ? '' : ' (to Claude in ${command.project})';
        print('command$to: ${command.text}');
        Timer(const Duration(milliseconds: 250), () {
          link.set(LinkReply(id: command.id, state: 'working', at: _now()).toValue(), LinkKey.reply);
        });
        Timer(const Duration(milliseconds: 700), () {
          final text = command.text == "What's pending?"
              ? 'Five things. The design review at 4 and Priya’s invoice need you.'
              : command.project != null
              ? 'Sent to Claude in ${command.project}.'
              : 'Done! You said “${command.text}”. (This is the fake Mac.)';
          link.set(LinkReply(id: command.id, state: 'done', text: text, at: _now()).toValue(), LinkKey.reply);
          print('  replied: $text');
        });
      case LinkKey.verdict:
        final verdict = LinkVerdict.fromValue(message.value);
        print('verdict for ${verdict?.id}: ${verdict?.allow == true ? 'send' : "don't send"}');
        link.set(null, LinkKey.approval);
      case LinkKey.phoneInteraction:
        print('the phone says: ${LinkInteraction.fromValue(message.value)?.kind}');
      default:
        break;
    }
  }

  void alert(String text) {
    _link?.sendAlert(
      {
        'title': 'Claude finished in mac-Tamagotchi',
        'body': text,
        'userInfo': {'card': 'session-1'},
      },
      category: 'turn',
      threadId: 'session-1',
    );
    print('sent a sealed alert: $text');
  }

  /// "Claude finished" exactly as the Mac's `PhoneAlertPayload.turnFinished` sends it through `LinkPush.alert`.
  void turn(String text) {
    final now = _now();
    final card = PhoneSessionCard(
      id: 'session-1',
      project: 'mac-Tamagotchi',
      phase: 'done',
      summary: TurnSummary(done: text, next: const ['Run the tests']),
      files: const ['UpdatesView.swift'],
      finishedAt: now.roundToDouble(),
    );
    _link?.sendAlert(
      {
        'title': card.project,
        'subtitle': 'Claude finished',
        'body': text,
        'userInfo': {'session': card.id, 'project': card.project, 'card': card.toJson()},
      },
      category: 'claude-turn',
      threadId: card.id,
    );
    print('sent "Claude finished" in ${card.project}: $text');
  }

  /// Mochi's news (`PhoneAlertPayload.agentNews`): two new emails, noted together, on top of an older one.
  void news() {
    final now = _now().roundToDouble();
    final card = AgentPending(
      enabled: true,
      lookedAt: now - 20,
      updatedAt: now + 1,
      items: [
        AgentNote(
          id: 'mail:test-priya-$now',
          source: AgentSource.gmail,
          title: 'Priya Sharma',
          detail: 'Can you send the November invoice?',
          important: true,
          at: now,
        ),
        AgentNote(
          id: 'mail:test-aditi-$now',
          source: AgentSource.gmail,
          title: 'Aditi Rao',
          detail: 'Notes on the onboarding flow?',
          important: true,
          at: now,
        ),
        AgentNote(
          id: 'mail:github',
          source: AgentSource.gmail,
          title: 'GitHub',
          detail: '1 new commit pushed to main.',
          important: false,
          at: now - 9000,
        ),
      ],
    );
    _link?.set(card.toValue(), LinkKey.agent);
    _link?.sendAlert(
      {
        'title': '2 new emails',
        'body': 'Priya Sharma needs you: the November invoice\nAditi Rao: notes on the onboarding flow?',
        'userInfo': {'kind': 'agent', 'quietIfKnown': true, 'pending': card.toJson()},
      },
      category: 'mochi-agent',
      threadId: 'mochi-agent',
    );
    print('sent news: two new emails');
  }

  /// Mochi Cloud's meeting heads-up (`heads_up` in mochi_cloud.py), with a harmless https page as the "video link".
  void meeting() {
    final now = _now().roundToDouble();
    final event = AgentNote(
      id: 'event:test-standup-$now',
      source: AgentSource.calendar,
      title: 'Stand-up',
      detail: 'In 5 min',
      important: true,
      at: now,
      due: now + 300,
      link: 'https://example.com/mochi-join-test',
    );
    final card = AgentPending(enabled: true, items: [event], lookedAt: now, updatedAt: now + 1, origin: 'cloud');
    _link?.sendAlert(
      {
        'title': 'Starting soon',
        'body': 'Stand-up (in 5 min)',
        'userInfo': {'kind': 'agent', 'origin': 'cloud', 'quietIfKnown': false, 'pending': card.toJson(), 'join': event.link},
      },
      category: 'mochi-meeting',
      threadId: 'mochi-agent',
    );
    print('sent a meeting heads-up');
  }

  /// Mochi Cloud's "Reply drafted" (`drafted` in mochi_cloud.py).
  void draft() {
    _link?.sendAlert(
      {
        'title': 'Reply drafted',
        'body': "To Priya Sharma: Invoice for November\nIt's in Gmail Drafts. Check it and send it when you're happy.",
        'userInfo': {'kind': 'draft', 'origin': 'cloud', 'link': 'https://example.com/mochi-draft-test'},
      },
      category: 'mochi-draft',
      threadId: 'mochi-agent',
    );
    print('sent "Reply drafted"');
  }

  Future<void> _readControl(File file) async {
    final length = file.lengthSync();
    if (length < _controlRead) _controlRead = 0;
    if (length == _controlRead) return;
    final raf = file.openSync()..setPositionSync(_controlRead);
    final added = utf8.decode(raf.readSync(length - _controlRead));
    raf.closeSync();
    _controlRead = length;
    for (final line in const LineSplitter().convert(added)) {
      await _command(line.trim());
    }
  }

  Future<void> _command(String line) async {
    if (line.isEmpty) return;
    final parts = line.split(RegExp(r'\s+'));
    final rest = line.substring(parts.first.length).trim();
    final link = _link;
    switch (parts.first) {
      case 'alert':
        alert(rest.isEmpty ? 'Tests pass. Mochi for Android talks to the Mac through Mochi Link.' : rest);
      case 'turn':
        turn(rest.isEmpty ? 'Added the week of updates to Mochi for Android.' : rest);
      case 'news':
        news();
      case 'meeting':
        meeting();
      case 'draft':
        draft();
      case 'approval':
        link?.set(
          ApprovalRequest(
            id: 'approval-${DateTime.now().millisecondsSinceEpoch}',
            target: 'session-1',
            project: 'mac-Tamagotchi',
            message: 'Run the tests and push.',
            at: _now(),
          ).toValue(),
          LinkKey.approval,
        );
        print('asked: Send to Claude?');
      case 'claude':
        final phase = parts.length > 1 ? parts[1] : 'idle';
        link?.set(ClaudeMirror(phase: phase, category: parts.length > 2 ? parts[2] : null, at: _now()).toValue(), LinkKey.claude);
        print('claude: $phase');
      case 'rest' || 'wake':
        link?.set(ClaudeMirror(phase: 'idle', resting: parts.first == 'rest', at: _now()).toValue(), LinkKey.claude);
        print(parts.first == 'rest' ? 'the Mac rests' : 'the Mac is in use');
      case 'pet' || 'play' || 'treat':
        link?.set(LinkInteraction(id: RelayLink.newId(), kind: parts.first, at: _now()).toValue(), LinkKey.macInteraction);
        print('the Mac says: ${parts.first}');
      case 'away':
        await link?.stop();
        print('the Mac went away');
      case 'back':
        link?.start();
        print('the Mac is back');
      case 'invite':
        await invite();
      case 'quit':
        await quit('asked to');
      default:
        print('unknown command: $line');
    }
  }

  Future<void> quit(String why) async {
    if (_quitting) return;
    _quitting = true;
    print('Quitting ($why): deleting the room.');
    try {
      await LinkPairing.deleteRoom(_host);
      final saved = credentialsFile;
      if (saved != null && File(saved).existsSync()) File(saved).deleteSync();
      print('Deleted the room.');
    } on Object catch (error) {
      print('Could not delete the room: $error');
    }
    await _link?.dispose();
    exit(0);
  }

  Map<String, Object?> _fixture(String key) => ((_fixtures[key] as Map?)?['value'] as Map?)?.cast<String, Object?>() ?? const {};

  /// link-spec/fixtures/*.json, found by walking up from this script.
  static Future<Map<String, Object?>> _loadFixtures() async {
    var directory = File.fromUri(Platform.script).parent;
    while (!Directory('${directory.path}/link-spec/fixtures').existsSync()) {
      final parent = directory.parent;
      if (parent.path == directory.path) throw StateError("Couldn't find link-spec/fixtures above ${Platform.script}");
      directory = parent;
    }
    final fixtures = <String, Object?>{};
    for (final entity in Directory('${directory.path}/link-spec/fixtures').listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json = jsonDecode(await entity.readAsString());
      final key = json is Map ? json['key'] : null;
      if (key is String) fixtures[key] = json;
    }
    return fixtures;
  }
}
