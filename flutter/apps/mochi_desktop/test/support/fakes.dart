// Test doubles: a relay socket the test drives as the relay (frames sealed with the room key for real, so RelayLink
// runs unchanged), the relay's HTTP calls, `claude`, the native window, and a desktop wired from them in a temporary
// folder (never the real ~/.claude or app data).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/hook_setup.dart';
import 'package:mochi_desktop/src/core/session_store.dart';
import 'package:mochi_desktop/src/desktop.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/credential_vault.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

final List<int> roomKey = List.filled(32, 9);

final LinkCredentials hostCredentials = LinkCredentials(
  relay: 'relay.test',
  room: 'room_pc',
  device: 'dev_pc',
  secret: 'pc-secret',
  key: LinkCrypto.base64url(roomKey),
  role: 'host',
);

final LinkCredentials phoneCredentials = LinkCredentials(
  relay: 'relay.test',
  room: 'room_pc',
  device: 'dev_phone',
  secret: 'phone-secret',
  key: LinkCrypto.base64url(roomKey),
  role: 'pocket',
  peerName: 'TEST-PC',
);

/// One socket to the relay, opened as soon as it's made.
class FakeSocket implements LinkSocket {
  FakeSocket(this.url, this.headers) {
    _ready.complete();
  }

  final Uri url;
  final Map<String, String> headers;
  final Completer<void> _ready = Completer();
  final StreamController<Object?> _frames = StreamController();
  final List<Map<String, Object?>> sent = [];
  int? _closeCode;
  bool closed = false;

  void deliver(Map<String, Object?> frame) {
    if (!_frames.isClosed) _frames.add(jsonEncode(frame));
  }

  void drop([int? code]) {
    _closeCode = code;
    unawaited(_frames.close());
  }

  /// Frames this device sent with [op] (and [key]).
  List<Map<String, Object?>> sentFrames(String op, [String? key]) =>
      sent.where((frame) => frame['op'] == op && (key == null || frame['key'] == key)).toList();

  /// The values this device put or sent for [key], opened with the room key.
  List<Object?> values(LinkKey key) => [
    for (final frame in sent)
      if (frame['key'] == key.name)
        RelayLink.open(jsonEncode(frame), hostCredentials, from: hostCredentials.device, roomKey: roomKey)!.value,
  ];

  /// The relay's `sync` (with the room's devices) and `presence`.
  void sync({List<Map<String, Object?>> devices = const [], List<Map<String, Object?>> state = const []}) =>
      deliver({'v': 1, 'op': 'sync', 'state': state, 'queue': <Object?>[], 'devices': devices, 'minClientVersion': 1});

  void presence(List<Map<String, Object?>> devices) => deliver({'v': 1, 'op': 'presence', 'presence': devices});

  /// A value a phone sealed, as the relay forwards it.
  void fromPhone(Object? value, LinkKey key, {String? id, num? at}) => deliver({
    ...(jsonDecode(RelayLink.frame(value, key, phoneCredentials, roomKey, id: id, at: at)) as Map).cast<String, Object?>(),
    'from': phoneCredentials.device,
  });

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<Object?> get stream => _frames.stream;

  @override
  void send(String text) {
    if (!closed) sent.add((jsonDecode(text) as Map).cast<String, Object?>());
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    if (!_frames.isClosed) await _frames.close();
  }

  @override
  int? get closeCode => _closeCode;
}

/// The relay's HTTP calls.
class FakeLinkApi implements LinkApi {
  int roomsMade = 0;
  int invites = 0;
  final List<LinkCredentials> deleted = [];
  Object? failCreate;

  @override
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name}) async {
    final failure = failCreate;
    if (failure != null) throw failure;
    roomsMade++;
    return hostCredentials;
  }

  @override
  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName}) async {
    invites++;
    return PairingCode(relay: credentials.relay, room: credentials.room, invite: 'invite-$invites', key: credentials.key, name: hostName);
  }

  @override
  Future<void> deleteRoom(LinkCredentials credentials) async => deleted.add(credentials);
}

/// `claude`, answering with [output] (and recording what it was asked).
class FakeClaude implements ClaudeRunner {
  FakeClaude({this.output, this.exitCode = 0, this.errorTail = '', this.timedOut = false});

  String? output;
  int exitCode;
  String errorTail;
  bool timedOut;
  final List<({List<String> arguments, String input})> runs = [];

  /// A `--output-format json` result.
  static String result(String text, {bool error = false}) =>
      jsonEncode({'type': 'result', 'subtype': error ? 'error' : 'success', 'is_error': error, 'result': text});

  @override
  Future<ClaudeRun> run(List<String> arguments, {required String input, Duration timeout = const Duration(seconds: 90)}) async {
    runs.add((arguments: arguments, input: input));
    return ClaudeRun(exitCode: exitCode, output: output ?? '', errorTail: errorTail, timedOut: timedOut);
  }
}

/// The native window: records what was shown.
class FakeShell implements DesktopShell {
  final List<Surface> shown = [];
  final StreamController<ShellAction> controller = StreamController.broadcast();
  int drags = 0;
  bool quit_ = false;

  @override
  Stream<ShellAction> get actions => controller.stream;

  @override
  Future<void> show(Surface surface, {Offset? petPosition}) async => shown.add(surface);

  @override
  Future<void> startDragging() async => drags++;

  @override
  Future<Offset?> position() async => const Offset(100, 200);

  @override
  Future<void> quit() async => quit_ = true;
}

/// A desktop wired from fakes in a temporary folder.
class TestDesktop {
  TestDesktop._(this.temp, this.desktop, this.sockets, this.api, this.claude, this.vault);

  final Directory temp;
  final MochiDesktop desktop;
  final List<FakeSocket> sockets;
  final FakeLinkApi api;
  final FakeClaude claude;
  final MemoryVault vault;

  FakeSocket get socket => sockets.last;

  static TestDesktop make({
    LinkCredentials? saved,
    bool claudeInstalled = true,
    DateTime Function()? clock,
    Map<String, Object?>? settings,
    String? bundledHelper,
    String? home,
  }) {
    final temp = Directory.systemTemp.createTempSync('mochi_desktop_test');
    final paths = BridgePaths(home ?? '${temp.path}/mochi', windows: false);
    final sockets = <FakeSocket>[];
    final api = FakeLinkApi();
    final claude = FakeClaude(output: FakeClaude.result('Hi!'));
    final vault = MemoryVault(saved);
    final desktop = MochiDesktop(
      paths: paths,
      settings: DesktopSettings(MemorySettingsDocument(settings)),
      sessions: SessionStore(clock: clock),
      hooks: HookSetup(
        paths: paths,
        settingsFile: '${temp.path}/home/.claude/settings.json',
        style: HookCommandStyle.shell,
        bundledHelper: bundledHelper,
      ),
      link: LinkHost(
        vault: vault,
        api: api,
        connect: (credentials) => RelayLink(
          credentials,
          platform: 'windows',
          app: 'test',
          connect: (url, headers) {
            final socket = FakeSocket(url, headers);
            sockets.add(socket);
            return socket;
          },
          backoff: (_) => const Duration(milliseconds: 1),
        ),
        hostName: 'TEST-PC',
        clock: clock,
      ),
      motion: SystemMotion(read: () => false),
      claude: () => claudeInstalled ? claude : null,
      clock: clock,
    );
    return TestDesktop._(temp, desktop, sockets, api, claude, vault);
  }

  Future<void> dispose() async {
    await desktop.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

/// A sanitized hook event, as the helper would send it.
WireEvent hook(
  String event, {
  String session = 's1',
  String project = 'web',
  String? tool,
  String? toolUseId,
  String? notificationType,
  String? summary,
  String? file,
  DateTime? at,
}) {
  final when = at ?? DateTime.now();
  return WireEvent(
      id: 'id-$event-${when.microsecondsSinceEpoch}',
      ts: when.microsecondsSinceEpoch / 1e6,
      origin: WireOrigin.hook,
      event: event,
    )
    ..session = session
    ..project = project
    ..projectKey = ProjectIdentity.key('/code/$project')
    ..projectPath = '/code/$project'
    ..tool = tool
    ..toolCategory = tool == null ? null : ToolCategoryClassifier.category(tool)
    ..toolUseId = toolUseId
    ..notificationType = notificationType
    ..summary = summary
    ..file = file;
}
