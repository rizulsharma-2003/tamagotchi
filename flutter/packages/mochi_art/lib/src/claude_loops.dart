// What Mochi and Patch do for what Claude is doing: the loops TamagotchiCore's EventToAnimationMapper picks
// (Mapping/EventToAnimationMapper.swift: `companionLoop`, `workLoop`, `petLoop`), shared by the rooms on Android and
// Windows and by Windows' taskbar.

import 'model/world.dart';

/// Mochi's and Patch's loops for Claude's state. [phase] is `ClaudeMirror.phase` (none · idle · working · waiting ·
/// done · error), or `ended` for a session that just closed; [category] is the running tool's category (read · search ·
/// edit · shell · web · agent · plan · ask · other), or `think` while Claude thinks between tools.
abstract final class ClaudeLoops {
  /// Patch's work for a tool (`workLoop(for:)`): typing, unless the tool says what kind of work it is.
  static CompanionAnimation workLoop(String? category) => switch (category) {
    'think' => CompanionAnimation.thinking,
    'read' => CompanionAnimation.reading,
    'search' => CompanionAnimation.searching,
    'shell' => CompanionAnimation.runningCommand,
    'web' => CompanionAnimation.browsing,
    'agent' => CompanionAnimation.delegating,
    'ask' => CompanionAnimation.waiting,
    _ => CompanionAnimation.typing,
  };

  /// Patch at his desk (`companionLoop(for:)`): working the way Claude works (handing out work while [helpers], the
  /// subagents, are running), waiting with you, idle between turns, resting once a session ends. He naps when the
  /// computer rests ([resting]), or when nothing has happened for a while between turns ([sleepy]: Settings ›
  /// Characters › "Naps after…").
  static CompanionAnimation companionLoop(String phase, {String? category, bool helpers = false, bool sleepy = false, bool resting = false}) {
    if (resting) return CompanionAnimation.sleep;
    switch (phase) {
      case 'working':
        if (category == 'think') return helpers ? CompanionAnimation.delegating : CompanionAnimation.thinking;
        return workLoop(category);
      case 'waiting':
        return CompanionAnimation.waiting;
      case 'ended':
        return sleepy ? CompanionAnimation.sleep : CompanionAnimation.rest;
      default:
        return sleepy ? CompanionAnimation.sleep : CompanionAnimation.idleAtDesk;
    }
  }

  /// Mochi (`petLoop(for:)`): watching Claude work, waving gently while Claude waits for you (or asks a question),
  /// asleep while the computer rests ([resting]), idle otherwise.
  static PetAnimation petLoop(String phase, {String? category, bool resting = false}) {
    if (resting) return PetAnimation.sleep;
    return switch (phase) {
      'working' => category == 'ask' ? PetAnimation.waveGently : PetAnimation.watch,
      'waiting' => PetAnimation.waveGently,
      _ => PetAnimation.idle,
    };
  }
}
