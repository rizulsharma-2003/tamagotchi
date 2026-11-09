// The Start menu's jump list (X16): "Ask Mochi" and "Explore" tasks on Mochi's Start-menu entry and taskbar button,
// each starting `Mochi.exe` with `--ask` or `--explore` (a second launch hands the argument to the running copy,
// ui/shell.dart's LaunchRequest). The runner builds it (windows/runner/jump_list.cpp, ICustomDestinationList).

import 'package:flutter/foundation.dart';

/// Asks the runner to build the jump list.
abstract interface class JumpListService {
  /// The HRESULT of the attempt (0: built).
  Future<int> build();
}

/// Builds the jump list once at startup, and only for the installed copy (the one whose Start-menu shortcut carries
/// Mochi's AppUserModelID; a copy run from Downloads or a build folder has no entry for tasks to hang on). A failure
/// is a line in the debug log and nothing else.
class StartMenuJumpList {
  StartMenuJumpList({required this.service, required bool Function() installed}) : _installed = installed;

  final JumpListService service;
  final bool Function() _installed;
  bool _asked = false;

  /// Whether the runner was asked (it is, once, for the installed copy).
  bool get asked => _asked;

  Future<void> buildOnce() async {
    if (_asked || !_installed()) return;
    _asked = true;
    try {
      final result = await service.build();
      if (result != 0) debugPrint('Mochi: the Start-menu jump list was not built (0x${(result & 0xFFFFFFFF).toRadixString(16)})');
    } on Object catch (error) {
      debugPrint('Mochi: the Start-menu jump list was not built (${error.runtimeType})');
    }
  }
}
