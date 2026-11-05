/// Claude Code hooks for Mochi's desktop app: the Dart twin of Sources/TamagotchiWire and ClaudeHookInstaller.
///
/// - [HookPayloadSanitizer] turns a hook's stdin JSON into a [WireEvent] (an allow-list: never prompts, tool input
///   or output; Claude's closing message only while summaries are shared). [ToolCategoryClassifier] and
///   [CommandClassifier] bucket tools and recognise builds and tests.
/// - [HookCli] is `mochi_hook` (bin/mochi_hook.dart); [BridgeClient] / [BridgeServer] carry events from it to the
///   app over a loopback socket with a token from the user's private folder ([BridgePaths]); [EventSpool] keeps
///   what arrives while the app isn't running.
/// - [ClaudeHookInstaller] adds Mochi's hooks to Claude Code's settings.json and takes them out again without
///   touching anything else ([HookSettingsMerger]), with a backup first.
library;

export 'src/bridge.dart';
export 'src/bridge_paths.dart';
export 'src/claude_hooks.dart';
export 'src/classifiers.dart';
export 'src/event_spool.dart';
export 'src/event_validator.dart';
export 'src/hook_cli.dart';
export 'src/hook_sanitizer.dart';
export 'src/wire_event.dart';
export 'src/wire_text.dart';
