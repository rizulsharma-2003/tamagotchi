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
import 'package:mochi_desktop/src/platform/startup.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
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

/// The native window: records what was shown (and where the pet went).
class FakeShell implements DesktopShell {
  FakeShell({this.petWindow});

  final List<Surface> shown = [];
  final List<({Surface surface, Offset? position, Size size})> shows = [];
  final StreamController<ShellAction> controller = StreamController.broadcast();
  final List<bool> trayRoaming = [];
  int drags = 0;
  int menus = 0;
  bool quit_ = false;

  /// Where a drag leaves the window (window_manager's logical top-left).
  Offset dropAt = const Offset(100, 200);

  @override
  final FakePetWindow? petWindow;

  @override
  Stream<ShellAction> get actions => controller.stream;

  @override
  Size mainSize = SurfaceSizes.main;

  /// The main window's size at each show of it.
  final List<Size> mainShows = [];

  @override
  Future<void> show(Surface surface, {Offset? petPosition, Size petSize = SurfaceSizes.pet}) async {
    shown.add(surface);
    shows.add((surface: surface, position: petPosition, size: petSize));
    if (surface == Surface.main) mainShows.add(mainSize);
  }

  @override
  Future<void> setRoaming(bool roaming) async => trayRoaming.add(roaming);

  @override
  Future<void> popUpMenu() async => menus++;

  @override
  Future<void> startDragging() async => drags++;

  @override
  Future<Offset?> position() async => dropAt;

  @override
  Future<void> quit() async => quit_ = true;
}

/// The pet's window in physical pixels: records every move and resize, and whether clicks go through it. With a
/// [minimum], it never gets smaller than that, as Windows keeps a window with a title bar at least 136 × 39 at 100%.
class FakePetWindow implements PetWindow {
  FakePetWindow({this.minimum});

  final (int, int)? minimum;
  PixelRect? current;
  final List<PixelRect> frames = [];
  final List<PixelRect> moves = [];
  final List<bool> clickThrough = [];
  int raises = 0;

  @override
  void move(int left, int top) {
    final now = current!;
    current = PixelRect.ltwh(left, top, now.width, now.height);
    moves.add(current!);
  }

  /// For each [frames] entry, whether the window was covered when it was set.
  final List<bool> framedCovered = [];

  @override
  Future<void> setFrame(PixelRect frame) async {
    framedCovered.add(covered);
    final least = minimum;
    current = least == null
        ? frame
        : PixelRect.ltwh(frame.left, frame.top, frame.width < least.$1 ? least.$1 : frame.width, frame.height < least.$2 ? least.$2 : frame.height);
    frames.add(current!);
  }

  @override
  PixelRect? frame() => current;

  @override
  void raise() => raises++;

  @override
  void setClickThrough(bool through) => clickThrough.add(through);

  int settles = 0;

  @override
  void settle() => settles++;

  /// The window with the focus (the test sets it), and where the focus was given back to.
  int focused = 42;
  final List<int> focusGiven = [];

  @override
  int focusOwner() => focused;

  @override
  void giveFocus(int window) => focusGiven.add(window);

  /// The window's covers ([cover], [uncover]) in order: true for each cover, false for each uncover.
  final List<bool> covers = [];

  /// Whether [cover] puts a picture up (a real window's does).
  bool coverable = true;
  bool covered = false;

  @override
  bool cover() {
    if (!coverable) return false;
    covered = true;
    covers.add(true);
    return true;
  }

  @override
  void uncover() {
    if (!covered) return;
    covered = false;
    covers.add(false);
  }

  /// Whether the timers are precise now (an animation runs), and every change.
  bool precise = false;
  final List<bool> preciseChanges = [];

  @override
  void preciseTimers(bool on) {
    if (on == precise) return;
    precise = on;
    preciseChanges.add(on);
  }
}

/// A taskbar the test sets up: at the bottom of a 1920×1080 screen at 100% by default, with the tray at the right,
/// the widgets tile at the left and the buttons centred.
class FakeTaskbar implements TaskbarInfo {
  FakeTaskbar([TaskbarReading? reading, this.measured]) : reading = reading ?? bottomTaskbar();

  TaskbarReading? reading;

  /// What UI Automation finds (null: nothing, so the zones are estimated).
  List<PixelRect>? measured;
  bool busy = false;
  bool inFront = false;
  (int, int)? pointer;
  int reads = 0;
  int measures = 0;

  /// A [width]×[height] screen at [scale] with a 48-logical-pixel taskbar along the bottom (and a 280-wide tray).
  static TaskbarReading bottomTaskbar({
    int width = 1920,
    int height = 1080,
    double scale = 1,
    bool autoHide = false,
    bool centred = true,
    bool widgets = true,
    TaskbarEdge edge = TaskbarEdge.bottom,
  }) {
    final bar = (48 * scale).round();
    return TaskbarReading(
      edge: edge,
      bounds: PixelRect(0, height - bar, width, height),
      monitor: PixelRect(0, 0, width, height),
      workArea: PixelRect(0, 0, width, autoHide ? height : height - bar),
      autoHide: autoHide,
      scale: scale,
      tray: PixelRect(width - (280 * scale).round(), height - bar, width, height),
      centred: centred,
      widgets: widgets,
    );
  }

  /// Windows 11's buttons as UI Automation reports them on [reading]'s taskbar: the widgets tile (0–150), Start to
  /// the last app (a centred group [group] logical pixels wide) and the tray.
  static List<PixelRect> windows11Buttons(TaskbarReading reading, {double group = 480}) {
    final bar = reading.bounds;
    int px(double logical) => (logical * reading.scale).round();
    final centre = bar.left + bar.width ~/ 2;
    return [
      // The taskbar itself and a full-width frame: not buttons.
      bar,
      PixelRect(bar.left, bar.top, bar.right - 4, bar.bottom),
      PixelRect(bar.left, bar.top + px(4), bar.left + px(150), bar.bottom - px(4)),
      for (var i = 0; i < (group / 48).floor(); i++)
        PixelRect(centre - px(group / 2) + px(48.0 * i), bar.top + px(4), centre - px(group / 2) + px(48.0 * i + 44), bar.bottom - px(4)),
      reading.tray!,
    ];
  }

  @override
  bool get available => true;

  @override
  TaskbarReading? read() {
    reads++;
    return reading;
  }

  @override
  Future<List<PixelRect>?> buttons() async {
    measures++;
    return measured;
  }

  @override
  bool fullscreenBusy() => busy;

  @override
  bool taskbarInFront() => inFront;

  @override
  (int, int)? cursor() => pointer;
}

/// "Start Mochi with Windows", without the registry: on or off, or refusing with [problem].
class FakeStartup implements StartupItem {
  FakeStartup({this.enabled = false, this.supported = true, this.problem, this.note});

  bool enabled;
  String? problem;
  String? note;
  final List<bool> changes = [];

  @override
  bool supported;

  @override
  StartupStatus status() => StartupStatus(enabled: enabled, note: note);

  @override
  String? setEnabled(bool on) {
    changes.add(on);
    if (problem != null) return problem;
    enabled = on;
    return null;
  }
}

/// HKEY_CURRENT_USER in memory: key → value name → string or bytes.
class MemoryStartupRegistry implements StartupRegistry {
  final Map<String, Map<String, Object>> keys = {};
  bool refuse = false;

  @override
  String? readString(String key, String name) => keys[key]?[name] as String?;

  @override
  List<int>? readBinary(String key, String name) => keys[key]?[name] as List<int>?;

  @override
  void writeString(String key, String name, String value) {
    if (refuse) throw const StartupException('Access is denied.');
    (keys[key] ??= {})[name] = value;
  }

  @override
  void delete(String key, String name) {
    if (refuse) throw const StartupException('Access is denied.');
    keys[key]?.remove(name);
  }
}

/// A desktop wired from fakes in a temporary folder.
class TestDesktop {
  TestDesktop._(this.temp, this.desktop, this.sockets, this.api, this.claude, this.vault, this.document, this.startup);

  final Directory temp;
  final MochiDesktop desktop;
  final List<FakeSocket> sockets;
  final FakeLinkApi api;
  final FakeClaude claude;
  final MemoryVault vault;

  /// Where the settings are saved.
  final MemorySettingsDocument document;
  final FakeStartup startup;

  FakeSocket get socket => sockets.last;

  static TestDesktop make({
    LinkCredentials? saved,
    bool claudeInstalled = true,
    DateTime Function()? clock,
    Map<String, Object?>? settings,
    String? bundledHelper,
    String? home,
    FakeStartup? startup,
    String? claudePath = '/usr/local/bin/claude',
  }) {
    final temp = Directory.systemTemp.createTempSync('mochi_desktop_test');
    final paths = BridgePaths(home ?? '${temp.path}/mochi', windows: false);
    final sockets = <FakeSocket>[];
    final api = FakeLinkApi();
    final claude = FakeClaude(output: FakeClaude.result('Hi!'));
    final vault = MemoryVault(saved);
    final document = MemorySettingsDocument(settings);
    final start = startup ?? FakeStartup();
    final desktop = MochiDesktop(
      paths: paths,
      settings: DesktopSettings(document, clock: clock),
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
      startup: start,
      locateClaude: () => claudeInstalled ? claudePath : null,
      clock: clock,
    );
    return TestDesktop._(temp, desktop, sockets, api, claude, vault, document, start);
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
