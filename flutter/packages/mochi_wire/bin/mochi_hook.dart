// mochi_hook: the helper Claude Code runs as a hook command on Windows (and on the macOS development build). It also
// installs Mochi's updates and uninstalls Mochi (UpdateCli in lib/src/update_cli.dart).
//
// Build it with `dart compile exe bin/mochi_hook.dart -o mochi_hook.exe` (the Windows build does this itself, see
// apps/mochi_desktop/windows/CMakeLists.txt). Usage: HookCli in lib/src/hook_cli.dart and UpdateCli.

import 'dart:async';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';

Future<void> main(List<String> arguments) async {
  final command = arguments.isEmpty ? null : arguments.first;
  if (UpdateCli.commands.contains(command)) {
    // Updates and the uninstall take as long as they take (each waits with its own limits). Only the uninstall has a
    // console to talk in; the others run without one, so nothing goes to stdout.
    var code = 1;
    try {
      final quiet = command != 'uninstall';
      code = await UpdateCli(environment: Platform.environment, out: quiet ? StringBuffer() : stdout).run(arguments);
    } on Object catch (error) {
      if (command == 'uninstall') stderr.writeln('mochi_hook: $command failed (${error.runtimeType})');
    }
    try {
      await stdout.flush();
    } on Object {
      // No console.
    }
    exit(code);
  }

  final hook = command == HelperInfo.hookSubcommand;
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
