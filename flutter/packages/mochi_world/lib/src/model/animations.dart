// Port of Sources/TamagotchiCore/Animation/CharacterAnimations.swift and the animation settings in
// Settings/AppSettings.swift. Enum case names equal the Swift raw values.

/// Interrupt priority. A new one-shot may replace the current one only if its priority is at least as high;
/// lower-priority requests are dropped, never queued, so stale reactions can never pile up and play late.
enum AnimationPriority implements Comparable<AnimationPriority> {
  base,
  ambient,
  interaction,
  reaction,
  user,
  attention,
  critical;

  @override
  int compareTo(AnimationPriority other) => index - other.index;

  bool operator <(AnimationPriority other) => index < other.index;
  bool operator <=(AnimationPriority other) => index <= other.index;
  bool operator >(AnimationPriority other) => index > other.index;
  bool operator >=(AnimationPriority other) => index >= other.index;

  static AnimationPriority max(AnimationPriority a, AnimationPriority b) => a >= b ? a : b;
}

enum AnimationIntensity {
  calm('Calm'),
  normal('Normal'),
  lively('Lively');

  const AnimationIntensity(this.title);
  final String title;

  /// Multiplier applied to gaps between ambient behaviours.
  double get gapMultiplier => switch (this) {
    AnimationIntensity.calm => 2.5,
    AnimationIntensity.normal => 1,
    AnimationIntensity.lively => 0.6,
  };
}

/// What the animator needs to know about an animation (Swift `CharacterAnimationKind`).
abstract interface class CharacterAnimationKind {
  /// Loops are base states (idle, working, sleeping…); everything else is a one-shot.
  bool get isLoop;
  double get defaultDuration;

  /// Minimum time before the same one-shot may start again.
  double get cooldown;
}

/// Character A: the user's pet.
enum PetAnimation implements CharacterAnimationKind {
  // Loops
  idle,
  sleep,
  watch,
  waveGently,
  // One-shots
  lookAround,
  happyBounce,
  excitedJump,
  roll,
  dance,
  confusedTilt,
  concerned,
  victory,
  greet,
  petted,
  play,
  leanForward,
  nod,
  blep,
  yawn,
  treat,
  wakeUp,
  wave,
  // Building blocks used inside interaction scripts
  walk,
  carry,
  offer,
  highFive,
  sit,
  rpsShake,
  curl,
  // Locomotion and play building blocks (also used by roaming activities)
  run,
  pounce,
  bat,
  tumble,
  sniff,
  stretch,
  scratch,
  shake,
  leapCatch,

  /// Driven by an `InteractionScript`.
  scripted;

  @override
  bool get isLoop => switch (this) {
    idle || sleep || watch || waveGently || walk || carry || sit || curl || run => true,
    _ => false,
  };

  @override
  double get defaultDuration => switch (this) {
    lookAround => 2.6,
    happyBounce => 1.0,
    excitedJump => 1.4,
    roll => 1.6,
    dance => 3.2,
    confusedTilt => 1.8,
    concerned => 2.4,
    victory => 2.4,
    greet => 1.8,
    petted => 3.2,
    play => 5.0,
    leanForward => 1.4,
    nod => 0.8,
    blep => 1.4,
    yawn => 1.8,
    treat => 4.4,
    wakeUp => 1.2,
    wave => 1.8,
    offer => 1.0,
    highFive => 0.7,
    rpsShake => 1.5,
    pounce => 1.3,
    bat => 0.6,
    tumble => 1.3,
    sniff => 1.8,
    stretch => 2.6,
    scratch => 2.0,
    shake => 1.1,
    leapCatch => 1.1,
    _ => 1.0,
  };

  @override
  double get cooldown => switch (this) {
    nod => 12,
    leanForward => 6,
    lookAround => 20,
    dance || roll => 60,
    // Ambient play stories are special; the user's Play button ignores this.
    play => 90,
    blep => 45,
    yawn => 60,
    _ => 0,
  };

  String get title => switch (this) {
    waveGently => 'Gentle wave',
    lookAround => 'Look around',
    happyBounce => 'Happy bounce',
    excitedJump => 'Excited jump',
    confusedTilt => 'Confused tilt',
    leanForward => 'Lean forward',
    wakeUp => 'Wake up',
    highFive => 'High five',
    rpsShake => 'Rock-paper-scissors',
    leapCatch => 'Leap and catch',
    _ => name[0].toUpperCase() + name.substring(1),
  };
}

/// Character B: the AI coding companion.
enum CompanionAnimation implements CharacterAnimationKind {
  // Loops
  absent,
  idleAtDesk,
  thinking,
  typing,
  reading,
  searching,
  runningCommand,
  browsing,
  delegating,
  waiting,
  detective,
  rest,
  sleep,
  offline,
  // One-shots
  arrive,
  setup,
  readTaskCard,
  concerned,
  celebrate,
  trophy,
  packUp,
  depart,
  greet,
  nod,
  wakeUp,
  stretch,
  sip,
  dance,
  presentCode,
  highFive,
  catchBall,
  doubleTake,
  pat,
  rpsShake,
  scripted;

  @override
  bool get isLoop => switch (this) {
    absent ||
    idleAtDesk ||
    thinking ||
    typing ||
    reading ||
    searching ||
    runningCommand ||
    browsing ||
    delegating ||
    waiting ||
    detective ||
    rest ||
    sleep ||
    offline => true,
    _ => false,
  };

  @override
  double get defaultDuration => switch (this) {
    arrive => 1.8,
    setup => 1.8,
    readTaskCard => 2.0,
    concerned => 2.6,
    celebrate => 2.4,
    trophy => 2.8,
    packUp => 2.0,
    depart => 1.4,
    greet => 1.6,
    nod => 0.9,
    wakeUp => 1.2,
    stretch => 2.0,
    sip => 2.0,
    dance => 3.2,
    presentCode => 2.4,
    highFive => 0.7,
    catchBall => 1.2,
    doubleTake => 1.4,
    pat => 1.6,
    rpsShake => 1.5,
    _ => 1.0,
  };

  @override
  double get cooldown => switch (this) {
    nod => 10,
    readTaskCard => 3,
    concerned => 4,
    _ => 0,
  };

  /// True for loops that show the workstation in use.
  bool get isWorking => switch (this) {
    thinking || typing || reading || searching || runningCommand || browsing || delegating || detective => true,
    _ => false,
  };

  String get title => switch (this) {
    idleAtDesk => 'Idle at desk',
    runningCommand => 'Watching a command',
    readTaskCard => 'Reading task card',
    packUp => 'Packing up',
    wakeUp => 'Waking up',
    presentCode => 'Showing code',
    highFive => 'High five',
    catchBall => 'Catching',
    doubleTake => 'Double take',
    _ => name[0].toUpperCase() + name.substring(1),
  };
}
