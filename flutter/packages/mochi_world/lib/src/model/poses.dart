// Port of the pose vocabulary in Sources/TamagotchiCore/Animation/Poses.swift (and the PetPose helpers in
// PetChoreography.swift). Enum case names equal the Swift raw values and JSON keys the Swift property names, so the
// poses read and write the same JSON as mochi_art's model and flutter/tools/pose_export.
//
// Swift's poses are value types; here they are mutable classes. Code that copies a pose or an effect in Swift
// (`var q = p`) calls `copy()` here.

import 'dart:math' as math;

import 'animations.dart';
import 'ease.dart';
import 'json.dart';

/// `PetPoseEvaluator.bodyWidthsPerPathUnit`: body widths per path unit (pet home → companion home) in the popover
/// scene. World-space props (a ball on the floor) use it to stay put while Mochi moves.
const double bodyWidthsPerPathUnit = 2.25;

/// `PetPoseEvaluator.maxEffects`: upper bound on particles per pet pose.
const int petMaxEffects = 24;

enum HeldItem {
  coffee,
  ball,
  document,
  taskCard,
  magnifier,
  codeCard,
  trophy,
  gradCap,
  rock,
  paper,
  scissors,
  errorBoard,
  treat,
  detectiveHat;

  /// Cards, boards and hand signs go in the left hand (towards the pet); the rest in the right.
  bool get heldInLeftHand => switch (this) {
    HeldItem.document || HeldItem.taskCard || HeldItem.codeCard || HeldItem.errorBoard => true,
    HeldItem.rock || HeldItem.paper || HeldItem.scissors => true,
    _ => false,
  };
}

enum EffectKind {
  z,
  sparkle,
  heart,
  question,
  exclamation,
  sweat,
  note,
  star,
  confetti,
  steam,
  speechDots,
  speechLock,
  speechQuestion,
  plug,
  clap,
  thinkingDots,
  ball,
  treat,
  orb,
  dust,
  streak,
  purr,
  crumb,
  yarn,
  tangle,
  butterfly,
  bubble,
  pop,
  fish,
  berry,
  cupcake,
  sniff,
  sneeze,
  noseBubble,
  shakeLines,
  burst,
  droplet,
  heartPop,
  shadow,
  frosting,
  notice,
}

/// A small particle or symbol drawn relative to a character (body units, origin at the character's feet, y up).
class Effect {
  Effect(
    this.kind, {
    this.x = 0,
    this.y = 0,
    this.scale = 1,
    this.opacity = 1,
    this.rotation = 0,
    this.variant = 0,
    this.stretch = 0,
    this.phase = 0,
    this.x2 = 0,
    this.y2 = 0,
    this.followsFacing = false,
    this.worldSpace = false,
  });

  factory Effect.fromJson(Map<String, Object?> j) => Effect(
    enumByName(EffectKind.values, j['kind']) ?? EffectKind.sparkle,
    x: dbl(j, 'x', 0),
    y: dbl(j, 'y', 0),
    scale: dbl(j, 'scale', 1),
    opacity: dbl(j, 'opacity', 1),
    rotation: dbl(j, 'rotation', 0),
    variant: integer(j, 'variant', 0),
    stretch: dbl(j, 'stretch', 0),
    phase: dbl(j, 'phase', 0),
    x2: dbl(j, 'x2', 0),
    y2: dbl(j, 'y2', 0),
    followsFacing: boolean(j, 'followsFacing', false),
    worldSpace: boolean(j, 'worldSpace', false),
  );

  EffectKind kind;
  double x, y, scale, opacity, rotation;
  int variant;

  /// Squash (negative) or stretch (positive) of a prop.
  double stretch;

  /// Free animation phase for props (wing beat, wobble, burst age).
  double phase;

  /// Secondary anchor relative to (x, y), e.g. the far end of a yarn strand.
  double x2, y2;

  /// Legacy: the renderer mirrors `x` with the character's facing.
  bool followsFacing;

  /// A prop placed in world space (`PetPose.addWorld`).
  bool worldSpace;

  Effect copy() => Effect(
    kind,
    x: x,
    y: y,
    scale: scale,
    opacity: opacity,
    rotation: rotation,
    variant: variant,
    stretch: stretch,
    phase: phase,
    x2: x2,
    y2: y2,
    followsFacing: followsFacing,
    worldSpace: worldSpace,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'x': x,
    'y': y,
    if (scale != 1) 'scale': scale,
    if (opacity != 1) 'opacity': opacity,
    if (rotation != 0) 'rotation': rotation,
    if (variant != 0) 'variant': variant,
    if (stretch != 0) 'stretch': stretch,
    if (phase != 0) 'phase': phase,
    if (x2 != 0) 'x2': x2,
    if (y2 != 0) 'y2': y2,
    if (followsFacing) 'followsFacing': true,
    if (worldSpace) 'worldSpace': true,
  };
}

/// Per-character inputs every pose is a pure function of (Swift `PoseContext`).
class PoseContext {
  PoseContext({
    required this.time,
    this.reducedMotion = false,
    this.intensity = AnimationIntensity.normal,
    this.seed = 1,
    this.returnLoop = PetAnimation.idle,
  });

  /// Global monotonic time, for breathing and blinking that continue across animations.
  double time;
  bool reducedMotion;
  AnimationIntensity intensity;

  /// Per-character seed (a UInt64's bit pattern) so blinks and glances never look synchronized.
  int seed;

  /// The loop the character returns to when a one-shot ends.
  PetAnimation returnLoop;

  PoseContext copy() =>
      PoseContext(time: time, reducedMotion: reducedMotion, intensity: intensity, seed: seed, returnLoop: returnLoop);

  /// Scale applied to translation, rotation and squash amplitudes.
  double get motion {
    if (reducedMotion) return 0;
    return switch (intensity) {
      AnimationIntensity.calm => 0.75,
      AnimationIntensity.normal => 1,
      AnimationIntensity.lively => 1.12,
    };
  }
}

// MARK: - Pet

enum PetEyes { open, closed, happy, wide, worried, dizzy, heart, wink, sleepy, squint }

enum Brows { none, worried, raised, confused }

enum PetMouth { cat, smile, open, o, flat, wavy, blep, nom, yawn, chomp, lick, grin, pant, tiny }

/// Mochi's pose. Channels are in screen space for the pose's `facing` unless noted; use [mirrored] to turn a pose
/// around.
class PetPose {
  PetPose();

  factory PetPose.fromJson(Map<String, Object?> j) => PetPose()
    ..x = dbl(j, 'x', 0)
    ..y = dbl(j, 'y', 0)
    ..scaleX = dbl(j, 'scaleX', 1)
    ..scaleY = dbl(j, 'scaleY', 1)
    ..rotation = dbl(j, 'rotation', 0)
    ..tilt = dbl(j, 'tilt', 0)
    ..facing = dbl(j, 'facing', 1)
    ..eyes = enumByName(PetEyes.values, j['eyes']) ?? PetEyes.open
    ..eyeOpenness = dbl(j, 'eyeOpenness', 1)
    ..lookX = dbl(j, 'lookX', 0.15)
    ..lookY = dbl(j, 'lookY', 0)
    ..brows = enumByName(Brows.values, j['brows']) ?? Brows.none
    ..mouth = enumByName(PetMouth.values, j['mouth']) ?? PetMouth.cat
    ..blush = dbl(j, 'blush', 0.35)
    ..earPerk = dbl(j, 'earPerk', 0)
    ..leftArm = dbl(j, 'leftArm', 0)
    ..rightArm = dbl(j, 'rightArm', 0)
    ..tailWag = dbl(j, 'tailWag', 0)
    ..step = dbl(j, 'step', 0)
    ..held = enumByName(HeldItem.values, j['held'])
    ..hat = enumByName(HeldItem.values, j['hat'])
    ..effects = list(j, 'effects').map(Effect.fromJson).toList()
    ..shadow = dbl(j, 'shadow', 1)
    ..opacity = dbl(j, 'opacity', 1)
    ..earLeft = dbl(j, 'earLeft', 0)
    ..earRight = dbl(j, 'earRight', 0)
    ..tailCurl = dbl(j, 'tailCurl', 0)
    ..tailLift = dbl(j, 'tailLift', 0)
    ..lean = dbl(j, 'lean', 0)
    ..breath = dbl(j, 'breath', 0)
    ..cheekLeft = dbl(j, 'cheekLeft', 0)
    ..cheekRight = dbl(j, 'cheekRight', 0)
    ..eyeSparkle = dbl(j, 'eyeSparkle', 0)
    ..eyeScale = dbl(j, 'eyeScale', 1)
    ..crossEyed = dbl(j, 'crossEyed', 0)
    ..stride = dbl(j, 'stride', 0)
    ..kick = dbl(j, 'kick', 0)
    ..pawToMouth = dbl(j, 'pawToMouth', 0)
    ..holdFront = dbl(j, 'holdFront', 0)
    ..headTurn = dbl(j, 'headTurn', 0)
    ..earListen = dbl(j, 'earListen', 0);

  /// Horizontal offset in scene-path units (0 = pet home, 1 = companion home).
  double x = 0;

  /// Lift off the ground in body heights.
  double y = 0;
  double scaleX = 1;
  double scaleY = 1;

  /// Whole-body rotation in radians (positive = clockwise).
  double rotation = 0;

  /// Head/face tilt in radians.
  double tilt = 0;

  /// 1 = facing the companion (right), -1 = facing left.
  double facing = 1;
  PetEyes eyes = PetEyes.open;
  double eyeOpenness = 1;
  double lookX = 0.15;
  double lookY = 0;
  Brows brows = Brows.none;
  PetMouth mouth = PetMouth.cat;
  double blush = 0.35;

  /// -1 drooped … 1 perked.
  double earPerk = 0;

  /// 0 = resting, 1 = raised straight up.
  double leftArm = 0;
  double rightArm = 0;
  double tailWag = 0;
  double step = 0;
  HeldItem? held;
  HeldItem? hat;
  List<Effect> effects = [];
  double shadow = 1;
  double opacity = 1;

  // Secondary motion and finer expression (all default to the neutral pose).
  double earLeft = 0;
  double earRight = 0;
  double tailCurl = 0;
  double tailLift = 0;
  double lean = 0;
  double breath = 0;
  double cheekLeft = 0;
  double cheekRight = 0;
  double eyeSparkle = 0;
  double eyeScale = 1;
  double crossEyed = 0;
  double stride = 0;
  double kick = 0;
  double pawToMouth = 0;
  double holdFront = 0;
  double headTurn = 0;
  double earListen = 0;

  /// A deep copy (Swift's value semantics).
  PetPose copy() => PetPose()
    ..x = x
    ..y = y
    ..scaleX = scaleX
    ..scaleY = scaleY
    ..rotation = rotation
    ..tilt = tilt
    ..facing = facing
    ..eyes = eyes
    ..eyeOpenness = eyeOpenness
    ..lookX = lookX
    ..lookY = lookY
    ..brows = brows
    ..mouth = mouth
    ..blush = blush
    ..earPerk = earPerk
    ..leftArm = leftArm
    ..rightArm = rightArm
    ..tailWag = tailWag
    ..step = step
    ..held = held
    ..hat = hat
    ..effects = [for (final e in effects) e.copy()]
    ..shadow = shadow
    ..opacity = opacity
    ..earLeft = earLeft
    ..earRight = earRight
    ..tailCurl = tailCurl
    ..tailLift = tailLift
    ..lean = lean
    ..breath = breath
    ..cheekLeft = cheekLeft
    ..cheekRight = cheekRight
    ..eyeSparkle = eyeSparkle
    ..eyeScale = eyeScale
    ..crossEyed = crossEyed
    ..stride = stride
    ..kick = kick
    ..pawToMouth = pawToMouth
    ..holdFront = holdFront
    ..headTurn = headTurn
    ..earListen = earListen;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'scaleX': scaleX,
    'scaleY': scaleY,
    'rotation': rotation,
    'tilt': tilt,
    'facing': facing,
    'eyes': eyes.name,
    'eyeOpenness': eyeOpenness,
    'lookX': lookX,
    'lookY': lookY,
    'brows': brows.name,
    'mouth': mouth.name,
    'blush': blush,
    'earPerk': earPerk,
    'leftArm': leftArm,
    'rightArm': rightArm,
    'tailWag': tailWag,
    'step': step,
    if (held != null) 'held': held!.name,
    if (hat != null) 'hat': hat!.name,
    if (effects.isNotEmpty) 'effects': effects.map((e) => e.toJson()).toList(),
    'shadow': shadow,
    'opacity': opacity,
    'earLeft': earLeft,
    'earRight': earRight,
    'tailCurl': tailCurl,
    'tailLift': tailLift,
    'lean': lean,
    'breath': breath,
    'cheekLeft': cheekLeft,
    'cheekRight': cheekRight,
    'eyeSparkle': eyeSparkle,
    'eyeScale': eyeScale,
    'crossEyed': crossEyed,
    'stride': stride,
    'kick': kick,
    'pawToMouth': pawToMouth,
    'holdFront': holdFront,
    'headTurn': headTurn,
    'earListen': earListen,
  };

  /// The same pose facing the other way (the only supported way to make Mochi face left).
  PetPose mirrored() {
    final p = copy();
    p.facing = -facing;
    p.lookX = -lookX;
    p.x = -x;
    p.rotation = -rotation;
    p.tilt = -tilt;
    p.leftArm = rightArm;
    p.rightArm = leftArm;
    p.cheekLeft = cheekRight;
    p.cheekRight = cheekLeft;
    for (final e in p.effects) {
      if (e.followsFacing) continue;
      e.x = -e.x;
      e.x2 = -e.x2;
      e.rotation = -e.rotation;
    }
    return p;
  }

  // MARK: Helpers from PetChoreography.swift (`extension PetPose`)

  /// Body widths per path unit; used to keep world-space props still while Mochi moves.
  static const double worldScale = bodyWidthsPerPathUnit;

  /// Art units the face slides per unit of `headTurn` (the renderer uses the same).
  static const double faceShift = 2.4;

  /// Appends an effect (at most [petMaxEffects]). The pose keeps [effect] itself: pass a copy if you change it later.
  void add(Effect effect) {
    if (effects.length < petMaxEffects) effects.add(effect);
  }

  /// Where a point on Mochi (art units: origin at the feet, y negative upwards, the 60 × 54 body) is drawn, in effect
  /// units, following squash, lean and rotation the way the renderer does; `face` points also turn with the head tilt.
  ({double x, double y}) bodyPoint(double ax, double ay, {bool face = false}) {
    var x = ax;
    var y = ay;
    if (face && tilt != 0) {
      final c = math.cos(tilt), s = math.sin(tilt);
      final dy = y + 27;
      (x, y) = (x * c - dy * s, x * s + dy * c - 27);
    }
    final side = facing >= 0 ? 1.0 : -1.0;
    x *= scaleX;
    y *= scaleY;
    x -= lean * side * y;
    final c = math.cos(rotation), s = math.sin(rotation);
    final dy = y + 27;
    (x, y) = (x * c - dy * s, x * s + dy * c - 27);
    return (x: x / 60, y: -y / 54);
  }

  /// The mouth, in effect units (see [bodyPoint]).
  ({double x, double y}) get mouthPoint {
    final side = facing >= 0 ? 1.0 : -1.0;
    final shift = 1.6 * Ease.clamp(lookX, -1, 1) * (1 - crossEyed) + faceShift * headTurn * side;
    return bodyPoint(shift, -20, face: true);
  }

  /// Adds a prop positioned in world space: `x` in body widths from Mochi's home, `y` in body heights above the floor.
  /// Call after the pose's own x/y are final.
  void addWorld(Effect effect) {
    final e = effect.copy();
    e.x -= x * worldScale;
    e.y -= y;
    e.worldSpace = true;
    add(e);
  }
}

// MARK: - Companion

enum VisorEyes { normal, happy, focused, worried, sleepy, wide, star, wink, off, heart, closed }

enum VisorMouth { none, smile, flat, o, grin, wavy }

enum AntennaTint { calm, working, attention, alert, off }

enum LaptopScreen { idle, code, terminal, web, search, docs, error, celebrate, off }

class LaptopPose {
  LaptopPose({this.visible = true, this.openness = 1, this.screen = LaptopScreen.idle, this.scroll = 0});

  factory LaptopPose.fromJson(Map<String, Object?> j) => LaptopPose(
    visible: boolean(j, 'visible', true),
    openness: dbl(j, 'openness', 1),
    screen: enumByName(LaptopScreen.values, j['screen']) ?? LaptopScreen.idle,
    scroll: dbl(j, 'scroll', 0),
  );

  bool visible;

  /// 0 closed … 1 open.
  double openness;
  LaptopScreen screen;

  /// Animation phase for scrolling content.
  double scroll;

  LaptopPose copy() => LaptopPose(visible: visible, openness: openness, screen: screen, scroll: scroll);

  Map<String, Object?> toJson() => {'visible': visible, 'openness': openness, 'screen': screen.name, 'scroll': scroll};
}

class CompanionPose {
  CompanionPose();

  factory CompanionPose.fromJson(Map<String, Object?> j) => CompanionPose()
    ..x = dbl(j, 'x', 0)
    ..y = dbl(j, 'y', 0)
    ..scaleX = dbl(j, 'scaleX', 1)
    ..scaleY = dbl(j, 'scaleY', 1)
    ..rotation = dbl(j, 'rotation', 0)
    ..facing = dbl(j, 'facing', -1)
    ..eyes = enumByName(VisorEyes.values, j['eyes']) ?? VisorEyes.normal
    ..eyeOpenness = dbl(j, 'eyeOpenness', 1)
    ..lookX = dbl(j, 'lookX', 0)
    ..lookY = dbl(j, 'lookY', 0)
    ..mouth = enumByName(VisorMouth.values, j['mouth']) ?? VisorMouth.none
    ..visorBrightness = dbl(j, 'visorBrightness', 1)
    ..antennaGlow = dbl(j, 'antennaGlow', 0.35)
    ..antennaTint = enumByName(AntennaTint.values, j['antennaTint']) ?? AntennaTint.calm
    ..antennaBend = dbl(j, 'antennaBend', 0)
    ..leftArm = dbl(j, 'leftArm', 0)
    ..rightArm = dbl(j, 'rightArm', 0)
    ..reach = dbl(j, 'reach', 0)
    ..held = enumByName(HeldItem.values, j['held'])
    ..hat = enumByName(HeldItem.values, j['hat'])
    ..laptop = j['laptop'] is Map ? LaptopPose.fromJson(asMap(j['laptop'])) : LaptopPose()
    ..effects = list(j, 'effects').map(Effect.fromJson).toList()
    ..shadow = dbl(j, 'shadow', 1)
    ..opacity = dbl(j, 'opacity', 1);

  double x = 0;
  double y = 0;
  double scaleX = 1;
  double scaleY = 1;
  double rotation = 0;
  double facing = -1;
  VisorEyes eyes = VisorEyes.normal;
  double eyeOpenness = 1;
  double lookX = 0;
  double lookY = 0;
  VisorMouth mouth = VisorMouth.none;
  double visorBrightness = 1;
  double antennaGlow = 0.35;
  AntennaTint antennaTint = AntennaTint.calm;

  /// Antenna sway in radians.
  double antennaBend = 0;

  /// 0 = resting, 1 = raised up.
  double leftArm = 0;
  double rightArm = 0;

  /// 0 = arms at the side, 1 = reaching forward to the keyboard.
  double reach = 0;
  HeldItem? held;
  HeldItem? hat;
  LaptopPose laptop = LaptopPose();
  List<Effect> effects = [];
  double shadow = 1;
  double opacity = 1;

  CompanionPose copy() => CompanionPose()
    ..x = x
    ..y = y
    ..scaleX = scaleX
    ..scaleY = scaleY
    ..rotation = rotation
    ..facing = facing
    ..eyes = eyes
    ..eyeOpenness = eyeOpenness
    ..lookX = lookX
    ..lookY = lookY
    ..mouth = mouth
    ..visorBrightness = visorBrightness
    ..antennaGlow = antennaGlow
    ..antennaTint = antennaTint
    ..antennaBend = antennaBend
    ..leftArm = leftArm
    ..rightArm = rightArm
    ..reach = reach
    ..held = held
    ..hat = hat
    ..laptop = laptop.copy()
    ..effects = [for (final e in effects) e.copy()]
    ..shadow = shadow
    ..opacity = opacity;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'scaleX': scaleX,
    'scaleY': scaleY,
    'rotation': rotation,
    'facing': facing,
    'eyes': eyes.name,
    'eyeOpenness': eyeOpenness,
    'lookX': lookX,
    'lookY': lookY,
    'mouth': mouth.name,
    'visorBrightness': visorBrightness,
    'antennaGlow': antennaGlow,
    'antennaTint': antennaTint.name,
    'antennaBend': antennaBend,
    'leftArm': leftArm,
    'rightArm': rightArm,
    'reach': reach,
    if (held != null) 'held': held!.name,
    if (hat != null) 'hat': hat!.name,
    'laptop': laptop.toJson(),
    if (effects.isNotEmpty) 'effects': effects.map((e) => e.toJson()).toList(),
    'shadow': shadow,
    'opacity': opacity,
  };
}
