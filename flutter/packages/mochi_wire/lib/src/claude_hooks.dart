import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'bridge_paths.dart';
import 'wire_event.dart';

/// The Claude Code hook events Mochi listens to (Swift `ClaudeHookEvent`, same names).
enum ClaudeHookEvent {
  sessionStart('SessionStart', 'A session starts, resumes or is cleared'),
  userPromptSubmit('UserPromptSubmit', 'You submit a prompt (the prompt text is not kept)'),
  preToolUse('PreToolUse', 'A tool is about to run (tool name only)'),
  postToolUse('PostToolUse', 'A tool finished successfully'),
  postToolUseFailure('PostToolUseFailure', 'A tool reported an error (exit code only)'),
  postToolBatch('PostToolBatch', 'A batch of parallel tool calls finished'),
  permissionRequest('PermissionRequest', 'Claude asks permission to use a tool'),
  notification('Notification', 'Claude Code needs your attention'),
  subagentStart('SubagentStart', 'A subagent starts'),
  subagentStop('SubagentStop', 'A subagent finishes'),
  stop('Stop', 'Claude finishes responding to a turn'),
  stopFailure('StopFailure', 'A turn ends with an API error'),
  sessionEnd('SessionEnd', 'A session ends');

  const ClaudeHookEvent(this.wireName, this.purpose);

  /// The name in settings.json and in the hook's input.
  final String wireName;

  /// Plain-language explanation for Settings.
  final String purpose;

  /// SessionEnd hooks share a short budget; Claude Code's default is kept there rather than raised.
  int? get timeoutSeconds => this == sessionEnd ? null : 5;

  static ClaudeHookEvent? tryParse(String name) {
    for (final event in values) {
      if (event.wireName == name) return event;
    }
    return null;
  }
}

/// How hook commands are written into settings.json.
enum HookCommandStyle {
  /// `'<helper>' claude-hook Stop 2>/dev/null || true`, run by `sh -c` (macOS and Linux, as the Mac app writes it):
  /// it exits 0 even if the helper is deleted.
  shell,

  /// Claude Code's exec form, `{"command": "<helper.exe>", "args": ["claude-hook", "Stop"]}`: no shell at all, so no
  /// quoting of `C:\Users\Jane Doe\…`, and it doesn't matter whether Claude Code would use Git Bash or PowerShell.
  exec,
}

/// Why a merge was refused.
class HookMergeException implements Exception {
  const HookMergeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Pure functions that add or remove Mochi's hook entries in a Claude Code settings document without disturbing
/// anything else (Swift `HookSettingsMerger`). The document is decoded JSON: maps keep their key order.
abstract final class HookSettingsMerger {
  /// True for a hook handler Mochi installed: its command names `mochi_hook` and runs `claude-hook`, in either style.
  static bool isOurs(Object? handler) {
    if (handler is! Map) return false;
    final command = handler['command'];
    if (command is! String || !command.contains(HelperInfo.executableName)) return false;
    final args = handler['args'];
    if (args is List && args.isNotEmpty && args.first == HelperInfo.hookSubcommand) return true;
    return command.contains(' ${HelperInfo.hookSubcommand}');
  }

  /// POSIX single quotes.
  static String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// Our handler for [event].
  static Map<String, Object?> handler({required String helperPath, required ClaudeHookEvent event, required HookCommandStyle style}) {
    final timeout = event.timeoutSeconds;
    return switch (style) {
      HookCommandStyle.shell => {
        'type': 'command',
        'command': '${shellQuote(helperPath)} ${HelperInfo.hookSubcommand} ${event.wireName} 2>/dev/null || true',
        'timeout': ?timeout,
      },
      HookCommandStyle.exec => {
        'type': 'command',
        'command': helperPath,
        'args': [HelperInfo.hookSubcommand, event.wireName],
        'timeout': ?timeout,
      },
    };
  }

  /// Event name → our installed handler(s).
  static Map<String, List<Map<String, Object?>>> installed(Object? root) {
    final result = <String, List<Map<String, Object?>>>{};
    final hooks = root is Map ? root['hooks'] : null;
    if (hooks is! Map) return result;
    hooks.forEach((event, groups) {
      if (groups is! List) return;
      for (final group in groups) {
        final handlers = group is Map ? group['hooks'] : null;
        if (handlers is! List) continue;
        for (final handler in handlers) {
          if (isOurs(handler)) (result[event as String] ??= []).add((handler as Map).cast<String, Object?>());
        }
      }
    });
    return result;
  }

  /// Adds or updates our handler for each event in [handlers], and removes ours from every other event.
  static Map<String, Object?> merge(Object? root, Map<ClaudeHookEvent, Map<String, Object?>> handlers) {
    if (root is! Map<String, Object?>) throw const HookMergeException('settings.json does not contain a JSON object');
    final object = Map<String, Object?>.of(root);
    final existing = object['hooks'];
    if (existing != null && existing is! Map) throw const HookMergeException('the "hooks" setting is not an object');
    // Remove ours everywhere first (moved, duplicated or outdated entries), keeping the position of the keys we're
    // about to write again, then add exactly one fresh handler per event.
    final hooks = _strip(
      existing == null ? <String, Object?>{} : (existing as Map).cast<String, Object?>(),
      keeping: {for (final event in handlers.keys) event.wireName},
    );
    for (final event in ClaudeHookEvent.values) {
      final handler = handlers[event];
      if (handler == null) continue;
      final current = hooks[event.wireName];
      if (current != null && current is! List) throw HookMergeException('hooks.${event.wireName} is not an array');
      hooks[event.wireName] = [
        ...?current as List?,
        {
          'hooks': [handler],
        },
      ];
    }
    object['hooks'] = hooks;
    final problems = verifyPreserved(root, object);
    if (problems.isNotEmpty) throw HookMergeException('safety check failed: ${problems.join('; ')}');
    return object;
  }

  /// Removes every handler we installed. Groups and event keys that become empty because of that are dropped;
  /// nothing else is touched.
  static Map<String, Object?> removeOurs(Object? root) {
    if (root is! Map<String, Object?>) throw const HookMergeException('settings.json does not contain a JSON object');
    final object = Map<String, Object?>.of(root);
    final existing = object['hooks'];
    if (existing == null) return object;
    if (existing is! Map) throw const HookMergeException('the "hooks" setting is not an object');
    final hooks = existing.cast<String, Object?>();
    final stripped = _strip(hooks, keeping: const {});
    if (stripped.isEmpty && hooks.isNotEmpty) {
      object.remove('hooks');
    } else {
      object['hooks'] = stripped;
    }
    final problems = verifyPreserved(root, object);
    if (problems.isNotEmpty) throw HookMergeException('safety check failed: ${problems.join('; ')}');
    return object;
  }

  static Map<String, Object?> _strip(Map<String, Object?> hooks, {required Set<String> keeping}) {
    final result = <String, Object?>{};
    hooks.forEach((key, groups) {
      if (groups is! List) {
        // Not ours to judge.
        result[key] = groups;
        return;
      }
      final kept = <Object?>[];
      var removedAny = false;
      for (final group in groups) {
        final handlers = group is Map ? group['hooks'] : null;
        if (group is! Map || handlers is! List) {
          kept.add(group);
          continue;
        }
        final others = handlers.where((handler) => !isOurs(handler)).toList();
        if (others.length == handlers.length) {
          kept.add(group);
        } else {
          removedAny = true;
          if (others.isNotEmpty) kept.add({...group.cast<String, Object?>(), 'hooks': others});
        }
      }
      if (kept.isEmpty && removedAny && !keeping.contains(key)) return;
      result[key] = kept;
    });
    return result;
  }

  /// Every setting and every hook that isn't Mochi's in [original] must survive unchanged (and in order) in
  /// [updated]. The problems found; empty when it's safe to write.
  static List<String> verifyPreserved(Object? original, Object? updated) {
    if (original is! Map || updated is! Map) return const ['root is not an object'];
    final problems = <String>[];
    for (final entry in original.entries) {
      if (entry.key == 'hooks') continue;
      if (!updated.containsKey(entry.key) || !jsonEquals(updated[entry.key], entry.value)) {
        problems.add('setting "${entry.key}" would change');
      }
    }
    for (final key in updated.keys) {
      if (key != 'hooks' && !original.containsKey(key)) problems.add('unexpected new setting "$key"');
    }
    final before = _foreign(original['hooks']), after = _foreign(updated['hooks']);
    before.forEach((event, groups) {
      if (!jsonEquals(groups, after[event] ?? const [])) problems.add('existing hooks for $event would change');
    });
    after.forEach((event, groups) {
      if (!before.containsKey(event) && groups.isNotEmpty) problems.add('unexpected hooks added for $event');
    });
    return problems;
  }

  /// Everything under `hooks` that isn't ours, normalized for comparison.
  static Map<String, List<Object?>> _foreign(Object? hooks) {
    final result = <String, List<Object?>>{};
    if (hooks is! Map) return result;
    hooks.forEach((event, groups) {
      if (groups is! List) {
        result[event as String] = [groups];
        return;
      }
      final kept = <Object?>[];
      for (final group in groups) {
        final handlers = group is Map ? group['hooks'] : null;
        if (group is! Map || handlers is! List) {
          kept.add(group);
          continue;
        }
        final foreign = handlers.where((handler) => !isOurs(handler)).toList();
        if (foreign.isEmpty && handlers.isNotEmpty) continue;
        kept.add({...group.cast<String, Object?>(), 'hooks': foreign});
      }
      if (kept.isNotEmpty) result[event as String] = kept;
    });
    return result;
  }

  /// Deep equality of decoded JSON (maps compared by key order too, as Swift's `semanticallyEquals` compares members).
  static bool jsonEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      final ak = a.keys.toList(), bk = b.keys.toList();
      for (var i = 0; i < ak.length; i++) {
        if (ak[i] != bk[i] || !jsonEquals(a[ak[i]], b[bk[i]])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!jsonEquals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is num && b is num) return a == b;
    return a == b;
  }
}

/// Whether Mochi's hooks are in settings.json.
enum HookStatus {
  /// None of Mochi's hooks.
  notInstalled,

  /// Every event has exactly the current handler.
  installed,

  /// Some events are missing, duplicated, or point at an old helper.
  needsUpdate,

  /// settings.json couldn't be read or isn't valid JSON.
  unreadable,
}

/// What [ClaudeHookInstaller.inspect] found.
class HookInspection {
  const HookInspection({
    required this.settingsFile,
    required this.fileExists,
    required this.status,
    this.installedEvents = const [],
    this.missing = const [],
    this.outdated = const [],
    this.otherHookCount = 0,
    this.hooksDisabled = false,
    this.managedHooksOnly = false,
    this.problem,
  });

  final String settingsFile;
  final bool fileExists;
  final HookStatus status;
  final List<String> installedEvents;
  final List<String> missing;
  final List<String> outdated;

  /// Hook handlers in the file that aren't Mochi's.
  final int otherHookCount;

  /// `disableAllHooks` is on: Claude Code runs no hooks at all.
  final bool hooksDisabled;

  /// The administrator allows managed hooks only.
  final bool managedHooksOnly;
  final String? problem;
}

/// What an install or uninstall did.
class HookChange {
  const HookChange({required this.changed, this.backup});

  final bool changed;

  /// The copy of settings.json made before changing it.
  final String? backup;
}

class HookInstallException implements Exception {
  const HookInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads, backs up, merges and atomically writes Claude Code's settings.json (Swift `ClaudeHookInstaller`). Every
/// path comes in from outside, so tests point it at a temporary home.
class ClaudeHookInstaller {
  ClaudeHookInstaller({
    required this.settingsFile,
    required this.backupDirectory,
    required this.helperPath,
    required this.style,
    this.managedSettingsFile,
    this.events = ClaudeHookEvent.values,
  });

  /// The user's settings: `$CLAUDE_CONFIG_DIR/settings.json` when set (Claude Code's own override), else
  /// `%USERPROFILE%\.claude\settings.json` on Windows and `~/.claude/settings.json` elsewhere.
  static String defaultSettingsFile({Map<String, String>? environment, bool? windows}) {
    final env = environment ?? Platform.environment;
    final isWindows = windows ?? Platform.isWindows;
    final separator = isWindows ? r'\' : '/';
    final config = env['CLAUDE_CONFIG_DIR'];
    if (config != null && config.isNotEmpty) return '$config${separator}settings.json';
    final home = isWindows ? (env['USERPROFILE'] ?? r'C:\') : (env['HOME'] ?? '/');
    return '$home$separator.claude${separator}settings.json';
  }

  /// Where an administrator's managed settings live (`allowManagedHooksOnly`).
  static String defaultManagedSettingsFile({bool? windows}) => (windows ?? Platform.isWindows)
      ? r'C:\Program Files\ClaudeCode\managed-settings.json'
      : (Platform.isMacOS ? '/Library/Application Support/ClaudeCode/managed-settings.json' : '/etc/claude-code/managed-settings.json');

  final String settingsFile;
  final String backupDirectory;
  final String helperPath;
  final HookCommandStyle style;
  final String? managedSettingsFile;
  final List<ClaudeHookEvent> events;

  Map<ClaudeHookEvent, Map<String, Object?>> get handlers => {
    for (final event in events) event: HookSettingsMerger.handler(helperPath: helperPath, event: event, style: style),
  };

  /// Follows a symlinked settings file (dotfile managers), so the target is edited.
  String get _target {
    final file = File(settingsFile);
    try {
      return file.existsSync() ? file.resolveSymbolicLinksSync() : settingsFile;
    } on FileSystemException {
      return settingsFile;
    }
  }

  ({String? text, Object? value}) _read() {
    final file = File(_target);
    if (!file.existsSync()) return (text: null, value: <String, Object?>{});
    String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (error) {
      throw HookInstallException("Couldn't read Claude Code's settings: ${error.message}");
    }
    if (text.trim().isEmpty) return (text: text, value: <String, Object?>{});
    try {
      return (text: text, value: jsonDecode(text));
    } on FormatException catch (error) {
      throw HookInstallException("Claude Code's settings aren't valid JSON (${error.message}). Nothing was changed.");
    }
  }

  HookInspection inspect() {
    final exists = File(settingsFile).existsSync();
    final managedOnly = _managedHooksOnly();
    Object? current;
    try {
      current = _read().value;
    } on HookInstallException catch (error) {
      return HookInspection(
        settingsFile: settingsFile,
        fileExists: exists,
        status: HookStatus.unreadable,
        managedHooksOnly: managedOnly,
        problem: error.message,
      );
    }
    final found = HookSettingsMerger.installed(current);
    final expected = handlers;
    final missing = <String>[], outdated = <String>[];
    for (final event in events) {
      final mine = found[event.wireName] ?? const [];
      if (mine.isEmpty) {
        missing.add(event.wireName);
      } else if (mine.length != 1 || !HookSettingsMerger.jsonEquals(mine.first, expected[event])) {
        outdated.add(event.wireName);
      }
    }
    for (final key in found.keys) {
      if (!events.any((event) => event.wireName == key)) outdated.add(key);
    }
    var others = 0;
    final hooks = current is Map ? current['hooks'] : null;
    if (hooks is Map) {
      for (final groups in hooks.values) {
        for (final group in groups is List ? groups : const []) {
          final list = group is Map ? group['hooks'] : null;
          if (list is List) others += list.where((handler) => !HookSettingsMerger.isOurs(handler)).length;
        }
      }
    }
    return HookInspection(
      settingsFile: settingsFile,
      fileExists: exists,
      status: found.isEmpty
          ? HookStatus.notInstalled
          : (missing.isEmpty && outdated.isEmpty ? HookStatus.installed : HookStatus.needsUpdate),
      installedEvents: found.keys.toList()..sort(),
      missing: missing,
      outdated: outdated..sort(),
      otherHookCount: others,
      hooksDisabled: current is Map && current['disableAllHooks'] == true,
      managedHooksOnly: managedOnly,
    );
  }

  /// The exact text that would be written.
  String preview() => _serialize(HookSettingsMerger.merge(_read().value, handlers), trailingNewline: true);

  /// Adds (or refreshes) Mochi's hooks. Safe to run again: a second run changes nothing.
  HookChange install({DateTime? now}) {
    if (!File(helperPath).existsSync()) throw HookInstallException('The hook helper is missing at $helperPath.');
    return _rewrite((value) => HookSettingsMerger.merge(value, handlers), now: now);
  }

  /// Takes out every hook Mochi added, and nothing else.
  HookChange uninstall({DateTime? now}) => _rewrite(HookSettingsMerger.removeOurs, now: now);

  HookChange _rewrite(Map<String, Object?> Function(Object? value) transform, {DateTime? now}) {
    final target = _target;
    final current = _read();
    Map<String, Object?> updated;
    try {
      updated = transform(current.value);
    } on HookMergeException catch (error) {
      throw HookInstallException("Couldn't merge the hooks safely: ${error.message}. Nothing was changed.");
    }
    if (current.text != null && HookSettingsMerger.jsonEquals(updated, current.value)) return const HookChange(changed: false);
    if (current.text == null && updated.isEmpty) return const HookChange(changed: false);

    // Keep the file's trailing-newline habit (default: a newline).
    final output = _serialize(updated, trailingNewline: current.text == null || current.text!.endsWith('\n'));
    if (!HookSettingsMerger.jsonEquals(jsonDecode(output), updated)) {
      throw const HookInstallException("Couldn't merge the hooks safely: the new settings didn't read back. Nothing was changed.");
    }
    final backup = current.text == null ? null : _backup(current.text!, now ?? DateTime.now());
    // Refuse if someone else changed the file since it was read.
    final file = File(target);
    final latest = file.existsSync() ? file.readAsStringSync() : null;
    if (latest != current.text) {
      throw const HookInstallException('settings.json changed while Mochi was editing it. Nothing was changed; please try again.');
    }
    _atomicWrite(target, output);
    return HookChange(changed: true, backup: backup);
  }

  static String _serialize(Object? value, {required bool trailingNewline}) {
    final text = const JsonEncoder.withIndent('  ').convert(value);
    return trailingNewline ? '$text\n' : text;
  }

  String _backup(String text, DateTime now) {
    if (!BridgePaths.ensurePrivateDirectory(backupDirectory)) {
      throw HookInstallException("Couldn't back up settings.json (can't create $backupDirectory). Nothing was changed.");
    }
    String two(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}-${two(now.millisecond, 3)}';
    final separator = backupDirectory.contains(r'\') ? r'\' : '/';
    var path = '$backupDirectory${separator}claude-settings-$stamp.json';
    var attempt = 1;
    while (File(path).existsSync()) {
      attempt++;
      path = '$backupDirectory${separator}claude-settings-$stamp-$attempt.json';
    }
    try {
      File(path).writeAsStringSync(text, flush: true);
      BridgePaths.restrict(path);
    } on FileSystemException catch (error) {
      throw HookInstallException("Couldn't back up settings.json (${error.message}). Nothing was changed.");
    }
    _pruneBackups(keep: 20);
    return path;
  }

  /// Backups, newest first.
  List<String> backups() {
    final directory = Directory(backupDirectory);
    if (!directory.existsSync()) return const [];
    final names = directory.listSync().whereType<File>().map((file) => file.path).where((path) {
      final name = path.split(RegExp(r'[\\/]')).last;
      return name.startsWith('claude-settings-');
    }).toList();
    names.sort((a, b) => b.compareTo(a));
    return names;
  }

  void _pruneBackups({required int keep}) {
    for (final path in backups().skip(keep)) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // Next time.
      }
    }
  }

  static void _atomicWrite(String target, String text) {
    final file = File(target);
    try {
      file.parent.createSync(recursive: true);
      final temporary = File('${file.parent.path}${Platform.pathSeparator}.settings.json.mochi-${Random().nextInt(1 << 32)}.tmp');
      temporary.writeAsStringSync(text, flush: true);
      temporary.renameSync(target);
    } on FileSystemException catch (error) {
      throw HookInstallException("Couldn't write settings.json (${error.message}).");
    }
  }

  bool _managedHooksOnly() {
    final path = managedSettingsFile;
    if (path == null) return false;
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      return json is Map && json['allowManagedHooksOnly'] == true;
    } on Object {
      return false;
    }
  }
}
