// Port of the pose vocabulary in Sources/TamagotchiCore/Animation/Poses.swift. Enum case names
// equal the Swift raw values and JSON keys equal the Swift property names, so poses exported
// from Swift (flutter/tools/pose_export) map straight onto these types.

import 'json.dart';

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

/// A small particle or symbol drawn relative to a character (body units, origin at the
/// character's feet, y up).
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
  double stretch, phase, x2, y2;
  bool followsFacing, worldSpace;

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

  /// Linear blend of two effects of the same kind (for smooth playback of sampled tracks).
  static Effect lerp(Effect a, Effect b, double t) => Effect(
    a.kind,
    x: _l(a.x, b.x, t),
    y: _l(a.y, b.y, t),
    scale: _l(a.scale, b.scale, t),
    opacity: _l(a.opacity, b.opacity, t),
    rotation: _l(a.rotation, b.rotation, t),
    variant: t < 0.5 ? a.variant : b.variant,
    stretch: _l(a.stretch, b.stretch, t),
    phase: _l(a.phase, b.phase, t),
    x2: _l(a.x2, b.x2, t),
    y2: _l(a.y2, b.y2, t),
    followsFacing: a.followsFacing,
    worldSpace: a.worldSpace,
  );
}

double _l(double a, double b, double t) => a + (b - a) * t;

enum PetEyes { open, closed, happy, wide, worried, dizzy, heart, wink, sleepy, squint }

enum Brows { none, worried, raised, confused }

enum PetMouth { cat, smile, open, o, flat, wavy, blep, nom, yawn, chomp, lick, grin, pant, tiny }

/// Mochi's pose. Channels are in screen space for the pose's `facing` unless noted; use
/// [mirrored] to turn a pose around.
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

  // Secondary motion and finer expression.
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

  PetPose copy() => PetPose.fromJson(toJson());

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
    p.effects = effects.map((effect) {
      if (effect.followsFacing) return effect.copy();
      return effect.copy()
        ..x = -effect.x
        ..x2 = -effect.x2
        ..rotation = -effect.rotation;
    }).toList();
    return p;
  }

  /// Blends two sampled poses (numbers interpolate, discrete channels switch at the middle;
  /// effects interpolate when both frames have the same kinds in the same order).
  static PetPose lerp(PetPose a, PetPose b, double t) {
    final n = t < 0.5 ? a : b;
    final p = PetPose()
      ..x = _l(a.x, b.x, t)
      ..y = _l(a.y, b.y, t)
      ..scaleX = _l(a.scaleX, b.scaleX, t)
      ..scaleY = _l(a.scaleY, b.scaleY, t)
      ..rotation = _l(a.rotation, b.rotation, t)
      ..tilt = _l(a.tilt, b.tilt, t)
      ..facing = n.facing
      ..eyes = n.eyes
      ..eyeOpenness = _l(a.eyeOpenness, b.eyeOpenness, t)
      ..lookX = _l(a.lookX, b.lookX, t)
      ..lookY = _l(a.lookY, b.lookY, t)
      ..brows = n.brows
      ..mouth = n.mouth
      ..blush = _l(a.blush, b.blush, t)
      ..earPerk = _l(a.earPerk, b.earPerk, t)
      ..leftArm = _l(a.leftArm, b.leftArm, t)
      ..rightArm = _l(a.rightArm, b.rightArm, t)
      ..tailWag = _l(a.tailWag, b.tailWag, t)
      ..step = _l(a.step, b.step, t)
      ..held = n.held
      ..hat = n.hat
      ..effects = _lerpEffects(a.effects, b.effects, t)
      ..shadow = _l(a.shadow, b.shadow, t)
      ..opacity = _l(a.opacity, b.opacity, t)
      ..earLeft = _l(a.earLeft, b.earLeft, t)
      ..earRight = _l(a.earRight, b.earRight, t)
      ..tailCurl = _l(a.tailCurl, b.tailCurl, t)
      ..tailLift = _l(a.tailLift, b.tailLift, t)
      ..lean = _l(a.lean, b.lean, t)
      ..breath = _l(a.breath, b.breath, t)
      ..cheekLeft = _l(a.cheekLeft, b.cheekLeft, t)
      ..cheekRight = _l(a.cheekRight, b.cheekRight, t)
      ..eyeSparkle = _l(a.eyeSparkle, b.eyeSparkle, t)
      ..eyeScale = _l(a.eyeScale, b.eyeScale, t)
      ..crossEyed = _l(a.crossEyed, b.crossEyed, t)
      ..stride = _l(a.stride, b.stride, t)
      ..kick = _l(a.kick, b.kick, t)
      ..pawToMouth = _l(a.pawToMouth, b.pawToMouth, t)
      ..holdFront = _l(a.holdFront, b.holdFront, t)
      ..headTurn = _l(a.headTurn, b.headTurn, t)
      ..earListen = _l(a.earListen, b.earListen, t);
    return p;
  }
}

List<Effect> _lerpEffects(List<Effect> a, List<Effect> b, double t) {
  final same = a.length == b.length && List.generate(a.length, (i) => a[i].kind == b[i].kind).every((x) => x);
  if (!same) return (t < 0.5 ? a : b).map((e) => e.copy()).toList();
  return List.generate(a.length, (i) => Effect.lerp(a[i], b[i], t));
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

  CompanionPose copy() => CompanionPose.fromJson(toJson());

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

  /// Blends two sampled poses; the pixel mascot snaps its limbs to whole pixels anyway.
  static CompanionPose lerp(CompanionPose a, CompanionPose b, double t) {
    final n = t < 0.5 ? a : b;
    return n.copy()
      ..x = _l(a.x, b.x, t)
      ..y = _l(a.y, b.y, t)
      ..scaleX = _l(a.scaleX, b.scaleX, t)
      ..scaleY = _l(a.scaleY, b.scaleY, t)
      ..rotation = _l(a.rotation, b.rotation, t)
      ..eyeOpenness = _l(a.eyeOpenness, b.eyeOpenness, t)
      ..lookX = _l(a.lookX, b.lookX, t)
      ..lookY = _l(a.lookY, b.lookY, t)
      ..antennaGlow = _l(a.antennaGlow, b.antennaGlow, t)
      ..antennaBend = _l(a.antennaBend, b.antennaBend, t)
      ..leftArm = _l(a.leftArm, b.leftArm, t)
      ..rightArm = _l(a.rightArm, b.rightArm, t)
      ..reach = _l(a.reach, b.reach, t)
      ..laptop.openness = _l(a.laptop.openness, b.laptop.openness, t)
      ..laptop.scroll = _l(a.laptop.scroll, b.laptop.scroll, t)
      ..effects = _lerpEffects(a.effects, b.effects, t)
      ..shadow = _l(a.shadow, b.shadow, t)
      ..opacity = _l(a.opacity, b.opacity, t);
  }
}

/// `PetPoseEvaluator.bodyWidthsPerPathUnit`: how far one unit of `PetPose.x` moves Mochi in
/// the popover, in body widths.
const double bodyWidthsPerPathUnit = 2.25;
