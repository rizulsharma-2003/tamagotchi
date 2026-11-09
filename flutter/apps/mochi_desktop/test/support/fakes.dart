// Test doubles: a relay socket the test drives as the relay (frames sealed with the room key for real, so RelayLink
// runs unchanged), the relay's HTTP calls, `claude`, the native window, and a desktop wired from them in a temporary
// folder (never the real ~/.claude or app data).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' show TestWidgetsFlutterBinding;
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:mochi_desktop/src/core/ask_mochi.dart' show ClipboardText;
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/core/hook_setup.dart';
import 'package:mochi_desktop/src/core/hotkeys.dart';
import 'package:mochi_desktop/src/core/jump_list.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/session_store.dart';
import 'package:mochi_desktop/src/core/sounds.dart';
import 'package:mochi_desktop/src/core/toasts.dart';
import 'package:mochi_desktop/src/desktop.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/credential_vault.dart';
import 'package:mochi_desktop/src/platform/displays.dart';
import 'package:mochi_desktop/src/platform/foreground_window.dart';
import 'package:mochi_desktop/src/platform/startup.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/update/self_install.dart';
import 'package:mochi_desktop/src/update/updater.dart';
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

  /// The roles invitations were for, the devices that joined (role, platform, name) and the ones removed.
  final List<String?> inviteRoles = [];
  final List<({String role, String platform, String name})> joins = [];
  final List<String> removed = [];

  /// The room's devices as the relay lists them over HTTPS (null: it can't be reached).
  List<LinkPeer>? listed;

  /// Joining fails with this (once), as the relay can (`room_full`).
  LinkPairingException? failJoin;

  @override
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name}) async {
    final failure = failCreate;
    if (failure != null) throw failure;
    roomsMade++;
    return hostCredentials;
  }

  @override
  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName, String? role}) async {
    invites++;
    inviteRoles.add(role);
    return PairingCode(relay: credentials.relay, room: credentials.room, invite: 'invite-$invites', key: credentials.key, name: hostName);
  }

  @override
  Future<void> deleteRoom(LinkCredentials credentials) async => deleted.add(credentials);

  @override
  Future<LinkCredentials> join(PairingCode code, {required String role, required String platform, required String name}) async {
    final failure = failJoin;
    if (failure != null) {
      failJoin = null;
      throw failure;
    }
    joins.add((role: role, platform: platform, name: name));
    return LinkCredentials(
      relay: code.relay,
      room: code.room,
      device: 'dev_cloud_${joins.length + 1}',
      secret: 'cloud-secret-${joins.length + 1}',
      key: code.key,
      role: role,
      peerName: code.name,
    );
  }

  @override
  Future<void> remove(String device, {required LinkCredentials from}) async => removed.add(device);

  @override
  Future<List<LinkPeer>> devices(LinkCredentials credentials) async {
    final list = listed;
    if (list == null) throw const LinkPairingException("Couldn't reach the relay.");
    return list;
  }
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

  /// Each show's always-on-top and exact frame (the desktop pet).
  final List<({bool onTop, PixelRect? frame})> forms = [];
  final StreamController<ShellAction> controller = StreamController.broadcast();

  /// Where Mochi lives, each time the tray's ticks changed.
  final List<DesktopStyle> trayStyles = [];

  /// The tray icon each time it changed (null: the app's own) and what it said.
  final List<({String? path, String tooltip})> trayIcons = [];

  /// "Restart to Update" in the tray, each time it was shown or hidden.
  final List<bool> trayUpdate = [];
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
  Future<void> show(Surface surface, {Offset? petPosition, Size petSize = SurfaceSizes.pet, bool onTop = true, PixelRect? petFrame}) async {
    shown.add(surface);
    shows.add((surface: surface, position: petPosition, size: petSize));
    forms.add((onTop: onTop, frame: petFrame));
    if (petFrame != null) await petWindow?.setFrame(petFrame);
    if (surface == Surface.main) mainShows.add(mainSize);
  }

  @override
  Future<void> setStyle(DesktopStyle style) async => trayStyles.add(style);

  @override
  Future<void> setTrayIcon({String? path, required String tooltip}) async => trayIcons.add((path: path, tooltip: tooltip));

  @override
  Future<void> setUpdateReady(bool ready) async => trayUpdate.add(ready);

  /// "Start Focus" or "Stop Focus" in the tray, each time it changed.
  final List<bool> trayFocus = [];

  @override
  Future<void> setFocusing(bool focusing) async => trayFocus.add(focusing);

  /// The tray's Explore item, each time it changed (null: none).
  final List<String?> trayExplore = [];

  @override
  Future<void> setExploring(String? label) async => trayExplore.add(label);

  @override
  Future<void> popUpMenu() async => menus++;

  @override
  Future<void> startDragging() async => drags++;

  /// Each edge a resize started from.
  final List<WindowEdge> resizes = [];

  /// What [size] answers: the main window's size, unless a test set another.
  Size? sizeNow;

  @override
  Future<void> startResizing(WindowEdge edge) async => resizes.add(edge);

  @override
  Future<Size?> size() async => sizeNow ?? mainSize;

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

  /// The landmarks that same call found (X6; none: UI Automation didn't say).
  @override
  TaskbarLandmarks landmarks = TaskbarLandmarks.none;
  bool busy = false;
  bool inFront = false;
  (int, int)? pointer;
  int reads = 0;
  int cursorReads = 0;
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

  /// What [fingerprint] says (null: can't tell, so the stroll measures each time it checks).
  Object? print;

  @override
  Object? fingerprint() => print;

  @override
  bool fullscreenBusy() => busy;

  @override
  bool taskbarInFront() => inFront;

  @override
  (int, int)? cursor() {
    cursorReads++;
    return pointer;
  }
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

/// Windows notifications: records each toast; [availability] is whatever the test says.
class FakeToasts implements ToastService {
  FakeToasts({this.availability = ToastAvailability.ready});

  @override
  ToastAvailability availability;
  final List<Toast> shown = [];
  void Function(ToastTarget target)? onOpen;
  int refreshes = 0;
  int settingsOpened = 0;

  /// The user clicks a toast.
  void click(ToastTarget target) => onOpen?.call(target);

  @override
  Future<void> start(void Function(ToastTarget target) onOpen) async => this.onOpen = onOpen;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<bool> show(Toast toast) async {
    if (!availability.works) return false;
    shown.add(toast);
    return true;
  }

  @override
  Future<void> openSystemSettings() async => settingsOpened++;

  @override
  void dispose() {}
}

/// The speakers: records each WAV played.
class FakeSound implements SoundOutput {
  final List<Uint8List> played = [];

  @override
  bool supported = true;

  @override
  bool systemSoundsOn = true;

  @override
  void play(Uint8List wav) => played.add(wav);
}

/// The PC's state, as the test sets it.
class FakeUsage implements UsageSampler {
  FakeUsage([this.activity]);

  SystemActivity? activity;
  final StreamController<void> _changes = StreamController.broadcast();

  /// Something changed (the display went off): the rhythm samples at once.
  void change(SystemActivity next) {
    activity = next;
    _changes.add(null);
  }

  @override
  bool get supported => true;

  @override
  SystemActivity? sample() => activity;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  void dispose() => unawaited(_changes.close());
}

/// RegisterHotKey: [taken] combinations belong to another app.
class FakeHotkeys implements HotkeyRegistrar {
  final Map<int, Hotkey> registered = {};
  final Set<Hotkey> taken = {};
  final List<String> calls = [];
  final StreamController<int> _pressed = StreamController.broadcast(sync: true);

  /// The user presses [shortcut]'s combination.
  void press(MochiShortcut shortcut) => _pressed.add(shortcut.id);

  @override
  bool supported = true;

  @override
  Future<bool> register(int id, Hotkey hotkey) async {
    calls.add('register $id ${hotkey.label}');
    if (taken.contains(hotkey)) return false;
    registered[id] = hotkey;
    return true;
  }

  @override
  Future<void> unregister(int id) async {
    calls.add('unregister $id');
    registered.remove(id);
  }

  @override
  Stream<int> get pressed => _pressed.stream;
}

/// The runner's jump list: how often it was asked, and what it answers (an HRESULT; 0 built).
class FakeJumpList implements JumpListService {
  int builds = 0;
  int answer = 0;
  bool throws = false;

  @override
  Future<int> build() async {
    builds++;
    if (throws) throw StateError('no runner');
    return answer;
  }
}

/// A clipboard that counts how often it is read (X15).
class FakeClipboard implements ClipboardText {
  FakeClipboard([this.text]);

  String? text;
  int reads = 0;

  @override
  Future<String?> read() async {
    reads++;
    return text;
  }
}

/// A desktop wired from fakes in a temporary folder.
class TestDesktop {
  TestDesktop._(
    this.temp,
    this.desktop,
    this.sockets,
    this.api,
    this.claude,
    this.vault,
    this.document,
    this.startup,
    this.toasts,
    this.sound,
    this.usage,
    this.hotkeys,
    this.worldStore,
    this.stores,
  );

  /// Where Mochi's world is kept (memory).
  final MemoryWorldStore worldStore;

  /// The features' own files (memory), by name: `focus-log.json`, `journal.json`, `seasons.json`.
  final Map<String, MemoryJsonStore> stores;

  final FakeToasts toasts;
  final FakeSound sound;
  final FakeUsage usage;
  final FakeHotkeys hotkeys;

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
    Updater? updater,
    SelfInstaller? installer,
    FakeToasts? toasts,
    SystemActivity? activity,
    double Function()? uptime,
    int? worldSeed = 0x5EED5,
    MemoryWorldStore? worldStore,
    Map<String, Object?> files = const {},
    bool stage = true,
    bool Function()? fullScreen,
    Stream<void>? sessionEnding,
    JumpListService? jumpList,
  }) {
    final stores = {for (final entry in files.entries) entry.key: MemoryJsonStore(entry.value)};
    final temp = Directory.systemTemp.createTempSync('mochi_desktop_test');
    final toastService = toasts ?? FakeToasts();
    final sound = FakeSound();
    final usage = FakeUsage(activity);
    final hotkeys = FakeHotkeys();
    final paths = BridgePaths(home ?? '${temp.path}/mochi', windows: false);
    final sockets = <FakeSocket>[];
    final api = FakeLinkApi();
    final claude = FakeClaude(output: FakeClaude.result('Hi!'));
    final vault = MemoryVault(saved);
    final document = MemorySettingsDocument(settings);
    final start = startup ?? FakeStartup();
    final store = worldStore ?? MemoryWorldStore();
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
      updater: updater,
      installer: installer,
      toasts: toastService,
      sound: sound,
      usage: usage,
      hotkeys: hotkeys,
      jumpList: jumpList,
      worldStore: store,
      stores: (file) => stores.putIfAbsent(file, MemoryJsonStore.new),
      uptime: uptime ?? testSeconds,
      worldSeed: worldSeed,
      stage: stage,
      fullScreen: fullScreen,
      sessionEnding: sessionEnding,
    );
    return TestDesktop._(temp, desktop, sockets, api, claude, vault, document, start, toastService, sound, usage, hotkeys, store, stores);
  }

  Future<void> dispose() async {
    await desktop.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

final Stopwatch _testWatch = Stopwatch()..start();

/// Seconds on the test's clock, for Mochi's world: inside `testWidgets` the fake clock (it moves with `pump`, as the
/// stroll's does), elsewhere a stopwatch.
double testSeconds() {
  try {
    return TestWidgetsFlutterBinding.instance.clock.now().microsecondsSinceEpoch / 1e6;
  } on Object {
    return _testWatch.elapsedMicroseconds / 1e6;
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

/// The PC's displays, as the test sets them (none: the pet is placed through window_manager, as on the macOS build).
class FakeDisplays implements Displays {
  FakeDisplays([List<DisplayArea>? displays]) : displays = displays ?? [main1080];

  List<DisplayArea> displays;

  /// The display the foreground window is on (X8), or null.
  DisplayArea? front;

  /// A 1920×1080 main display at 100% with a 48-pixel taskbar, and a 2560×1440 one at 150% to its right.
  static const DisplayArea main1080 = DisplayArea(
    key: r'\\.\DISPLAY1 1920x1080',
    monitor: PixelRect(0, 0, 1920, 1080),
    workArea: PixelRect(0, 0, 1920, 1032),
    scale: 1,
    primary: true,
  );
  static const DisplayArea side1440 = DisplayArea(
    key: r'\\.\DISPLAY2 2560x1440',
    monitor: PixelRect(1920, 0, 4480, 1440),
    workArea: PixelRect(1920, 0, 4480, 1440),
    scale: 1.5,
  );

  @override
  List<DisplayArea> list() => List.of(displays);

  @override
  DisplayArea? foreground() => front;
}

/// Other apps' windows, as the test sets them: front to back, physical pixels (W19, X1).
class FakeWindowFrames implements WindowFrames {
  FakeWindowFrames([List<WindowFrame>? windows]) : windows = windows ?? [];

  List<WindowFrame> windows;

  /// Windows that are minimised (still there, but not on screen: neither listed nor read).
  final Set<int> minimised = {};

  /// How many times the whole list was read, and how many times one window was.
  int lists = 0;
  int reads = 0;

  @override
  List<WindowFrame> list() {
    lists++;
    return [
      for (final window in windows)
        if (!minimised.contains(window.hwnd)) window,
    ];
  }

  @override
  WindowFrame? frame(int hwnd) {
    reads++;
    if (minimised.contains(hwnd)) return null;
    return windows.where((window) => window.hwnd == hwnd).firstOrNull;
  }
}

/// The window with the focus, as the test sets it (Peekaboo, X3).
class FakeForegroundWindows implements ForegroundWindows {
  FakeForegroundWindows([this.window]);

  ForegroundWindow? window;

  /// How many times it was read.
  int reads = 0;

  @override
  ForegroundWindow? read() {
    reads++;
    return window;
  }
}
