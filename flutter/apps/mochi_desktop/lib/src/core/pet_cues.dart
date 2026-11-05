/// Moments Mochi reacts to: a pet, play or treat (here or from a phone), how a request is going, and what Claude just
/// did (as the pocket's `PetCue`, plus Claude's own moments the desktop sees first hand).
enum PetCue {
  pet,
  play,
  treat,

  /// A request went out.
  sending,

  /// Claude is thinking about a request.
  working,
  replied,
  failed,

  /// A Claude turn finished.
  finished,

  /// A Claude session needs you.
  needsYou,

  /// A turn ended with an error.
  snag,
}
