// mochi_hook: the helper Claude Code runs as a hook command on Windows (and on the macOS development build).
//
// Build it with `dart compile exe bin/mochi_hook.dart -o mochi_hook.exe` (the Windows build does this itself, see
// apps/mochi_desktop/windows/CMakeLists.txt). Usage: HookCli in lib/src/hook_cli.dart.

import 'dart:async';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';

Future<void> main(List<String> arguments) async {
  final hook = arguments.isNotEmpty && arguments.first == HelperInfo.hookSubcommand;
  // A hook must never hang Claude Code: a hard deadline, then exit quietly.
  Timer(Duration(seconds: hook ? 3 : 5), () => exit(0));
  var code = 0;
  try {
    code = await HookCli(
      environment: Platform.environment,
      stdinBytes: stdin,
      stdinIsTerminal: stdin.hasTerminal,
      out: stdout,
      err: stderr,
    ).run(arguments);
  } on Object {
    // Whatever went wrong, Claude Code carries on.
    code = 0;
  }
  if (!hook) await stdout.flush();
  exit(hook ? 0 : code);
}
