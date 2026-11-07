/// Moments Mochi reacts to: a pet, play or treat (here or from a phone), how a request is going, and what Claude just
/// did (as the pocket's `PetCue`, plus Claude's own moments the desktop sees first hand: the Mac's reactions, each
/// played only when its category's "Animate" is on in Settings › Notifications).
enum PetCue {
  pet,
  play,
  treat,

  /// A request went out.
  sending,

  /// Claude is thinking about a request (and a subagent started: Mochi looks around).
  working,
  replied,
  failed,

  /// A Claude turn finished.
  finished,

  /// A Claude session needs you.
  needsYou,

  /// A turn ended with an error.
  snag,

  /// A Claude Code session started: Mochi says hello.
  greet,

  /// A session ended: Mochi waves goodbye.
  goodbye,

  /// You sent Claude a prompt: Mochi leans in.
  attend,

  /// A tool call went fine: a small nod (now and then).
  nod,

  /// A tool was interrupted, or auto mode declined a call: a puzzled tilt.
  puzzled,

  /// A build or test passed, or a commit was recorded: a happy bounce.
  cheer,

  /// A tool reported an error, or a build or test failed: Mochi looks concerned.
  worry,

  /// A milestone, or a build or test your script reported passing: a victory pose.
  celebrate,

  /// A new Mochi is downloaded and verified: restart to update.
  updateReady,

  /// Mochi was just updated (this launch is the new version).
  updated,
}
