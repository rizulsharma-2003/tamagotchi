import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';

import '../../core/desktop_world.dart';
import '../../core/notifications.dart' show AttentionLevel;
import '../../core/pc_rhythm.dart';
import '../../core/purr.dart';
import '../../core/session_store.dart';
import 'companion_director.dart';
import 'pet_director.dart';
import 'pose_sprites.dart';
import 'stroller.dart';
import '../../platform/taskbar.dart' show HomeStage;
import 'taskbar_stroll.dart' show DuoLayout;

/// Mochi, alive: drawn by mochi_art's renderer from Mochi's world ([world]: what it does, its moments and its poses,
/// the Mac's), following Claude's sessions. With animations off (Windows' Animation effects, macOS' Reduce Motion),
/// Mochi keeps living, calmer (the world's Reduced Motion).
///
/// It's drawn only as often as what it's doing needs ([frameRate], as the Mac's menu-bar stage does): smooth while
/// it walks or plays a moment, a calm 12 frames a second otherwise, 6 asleep, and not at all while nobody can see the
/// screen (the display off, the PC locked or asleep: [PcRhythm.unseen]). Each pose of a loop is drawn once into a
/// picture and reused after that ([PoseSprites]; world_poses.dart plays loops on a ring so their poses repeat).
///
/// On the taskbar with Patch ([duo]), the view is Patch's and Mochi's stage: Patch at his desk (with the laptop and
/// the desk thing) and Mochi wherever its stroll has it, or both playing a moment together; and Claude's finishes get
/// a burst of confetti there ([burst]), as in the Mac's menu bar.
class MochiView extends StatefulWidget {
  const MochiView({
    super.key,
    required this.world,
    required this.sessions,
    required this.lastActivity,
    this.onMood,
    this.fill = 0.82,
    this.feet = 0.06,
    this.stroll,
    this.detail = RenderDetail.standard,
    this.color = PetColor.cream,
    this.accessory,
    this.companion,
    this.duo,
    this.theme = OfficeTheme.cozyDesk,
    this.companionAccessory,
    this.deskAccessory,
    this.burst = false,
    this.rhythm,
    this.badge,
    this.sprites = true,
    this.time,
    this.purr,
    this.season,
    this.petAway = false,
  });

  /// Mochi is out on the desktop (the native stage draws it): only Patch is drawn here.
  final bool petAway;

  /// Mochi's world: what Mochi (and Patch) do, and their poses.
  final DesktopWorld world;
  final SessionStore sessions;

  /// The last hook event, pet or launch (the mood's quiet time, when the world doesn't say).
  final DateTime Function() lastActivity;

  /// Called when the mood changes.
  final ValueChanged<PetMood>? onMood;

  /// How much of the height Mochi fills.
  final double fill;

  /// How high its feet are above the bottom edge, as a part of the height.
  final double feet;

  /// On the taskbar: what Mochi is doing there right now (it walks, turns, sits and naps by it).
  final StrollSample? Function()? stroll;

  /// The drawing's detail: [RenderDetail.tiny] at taskbar size (bolder lines, small hops, no shadow), as in the Mac's
  /// menu bar.
  final RenderDetail detail;

  /// The coat (Settings › Characters).
  final PetColor color;

  /// What Mochi wears: your choice, or the holiday's costume (DesktopSettings.wornByPet).
  final Accessory? accessory;

  /// Patch, for the moments he shares with Mochi and (with [duo]) to draw him.
  final CompanionDirector? companion;

  /// On the taskbar with Patch: where his desk and Mochi's place are in the view (null: Mochi alone, centred).
  final DuoLayout? Function()? duo;

  /// Patch's desk: the room's style, what Patch wears and what stands on his desk.
  final OfficeTheme theme;
  final Accessory? companionAccessory;
  final Accessory? deskAccessory;

  /// Claude's finishes get a burst of confetti (on the taskbar, as in the Mac's menu bar).
  final bool burst;

  /// The PC's rhythm: Mochi naps while the PC rests (null: after a long quiet stretch).
  final PcRhythm? rhythm;

  /// The dot beside Mochi while something waits for you (the Mac's menu-bar badge), by how much it matters.
  final AttentionLevel? badge;

  /// Each pose is drawn once into a picture and reused ([PoseSprites]); false draws the art every frame.
  final bool sprites;

  /// The animations' clock (seconds; tests): the world's otherwise.
  final double Function()? time;

  /// Press and hold Mochi (W21): while it purrs, little purr lines tremble at its sides.
  final PurrSession? purr;

  /// Today's holiday (W20): on the taskbar with Patch, a little decoration stands beside his desk (the Mac's beside the
  /// bed in the menu bar), as Settings › Fun › Holidays says.
  final SeasonalEvent? Function()? season;

  /// Loops are played on a grid (seconds) when [sprites] are on, so their poses repeat exactly as a loop comes round:
  /// 15 a second when Mochi is drawn at most that often, and 30 when it walks or plays a moment (24–25 frames a
  /// second).
  static double quantum(double fps) => fps > 15 ? 1 / 30 : 1 / 15;

  @override
  State<MochiView> createState() => MochiViewState();

  /// Frames a second for Mochi doing this: 25 while it walks (the window moves as often), 24 for a moment (a pet, a
  /// finished turn, a stretch), 12 for a calm loop (8 at the taskbar's size, [small]: its breathing moves less than a
  /// pixel there, and no blink is ever skipped), 6 asleep; at most 10 with animations off.
  static double frameRate({
    required PetMood mood,
    StrollSample? roam,
    bool oneShot = false,
    bool calm = false,
    double companion = 0,
    bool small = false,
  }) {
    final rate = math.max(_petRate(mood: mood, roam: roam, oneShot: oneShot, small: small), companion);
    return calm ? math.min(rate, 10) : rate;
  }

  static double _petRate({required PetMood mood, StrollSample? roam, bool oneShot = false, bool small = false}) {
    final double rate;
    if (roam?.travelling ?? false) {
      rate = 25;
    } else if (oneShot || (roam?.oneShot ?? false)) {
      rate = 24;
    } else {
      final loop = roam?.animation ?? mood.loop;
      rate = loop == PetAnimation.sleep || loop == PetAnimation.curl ? 6 : (small ? 8 : 12);
    }
    return rate;
  }
}

class MochiViewState extends State<MochiView> {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final PoseSprites _sprites = PoseSprites();
  late PetDirector _director = PetDirector(widget.world);
  Timer? _moodTimer;
  Timer? _frames;
  double _fps = 0;
  bool _calm = false;

  double get _time => widget.time?.call() ?? widget.world.now();

  /// Frames a second now (0: not drawing), and the pictures kept (tests).
  double get fps => _frames == null ? 0 : _fps;
  PoseSprites get sprites => _sprites;

  @override
  void initState() {
    super.initState();
    _frame();
    widget.world.addListener(_worldChanged);
    widget.sessions.addListener(_follow);
    widget.rhythm?.addListener(_rhythmChanged);
    // The mood also changes with time alone (a finish fades, a nap begins).
    _watchMood();
    widget.companion?.addListener(_frame);
    widget.purr?.addListener(_frame);
    _follow();
  }

  @override
  void didUpdateWidget(MochiView old) {
    super.didUpdateWidget(old);
    if (old.sessions != widget.sessions) {
      old.sessions.removeListener(_follow);
      widget.sessions.addListener(_follow);
    }
    if (old.rhythm != widget.rhythm) {
      old.rhythm?.removeListener(_rhythmChanged);
      widget.rhythm?.addListener(_rhythmChanged);
    }
    if (old.world != widget.world) {
      old.world.removeListener(_worldChanged);
      widget.world.addListener(_worldChanged);
      _director = PetDirector(widget.world)..mood = _director.mood;
    }
    if (old.companion != widget.companion) {
      old.companion?.removeListener(_frame);
      widget.companion?.addListener(_frame);
    }
    if (old.purr != widget.purr) {
      old.purr?.removeListener(_frame);
      widget.purr?.addListener(_frame);
    }
  }

  /// What Patch needs drawn: on the taskbar beside Mochi, his loop and moments; elsewhere only a burst.
  double _companionRate() {
    final companion = widget.companion;
    if (companion == null) return 0;
    final t = companion.time;
    if (widget.duo?.call() != null) return companion.frameRate(t);
    return widget.burst && companion.burstAt(t) != null ? 24 : 0;
  }

  /// The PC rested or woke, or the screen went out of sight or came back.
  void _rhythmChanged() {
    _follow();
    _watchMood();
    if (mounted) _frame();
  }

  /// The mood is looked at again every 5 seconds, while the screen can be seen.
  void _watchMood() {
    if (widget.rhythm?.unseen ?? false) {
      _moodTimer?.cancel();
      _moodTimer = null;
    } else {
      _moodTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _follow());
    }
  }

  /// Any of the view's timers is running (tests).
  bool get ticking => _frames != null || _moodTimer != null;

  /// One frame: Mochi's clock moves on (so it's repainted), and the frame rate follows what it's doing. Nothing while
  /// nobody can see the screen: the last frame stays, and drawing carries on when it's back.
  void _frame() {
    if (widget.rhythm?.unseen ?? false) {
      _frames?.cancel();
      _frames = null;
      _fps = 0;
      return;
    }
    final time = _time;
    _clock.value = time;
    final fps = MochiView.frameRate(
      mood: _director.mood,
      roam: widget.stroll?.call(),
      oneShot: _director.playing || (widget.purr?.active ?? false),
      calm: _calm,
      companion: _companionRate(),
      small: widget.detail == RenderDetail.tiny,
    );
    if (fps == _fps) return;
    _fps = fps;
    _frames?.cancel();
    _frames = Timer.periodic(Duration(microseconds: (1e6 / fps).round()), (_) => _frame());
  }

  /// The world started or ended a moment, Patch came or went, Mochi fell asleep or woke.
  void _worldChanged() {
    _follow();
    _frame();
  }

  void _follow() {
    final mood = PetMood.of(
      widget.sessions,
      now: widget.sessions.now,
      lastActivity: widget.lastActivity(),
      rhythm: widget.rhythm,
      asleep: widget.world.asleep,
    );
    if (mood == _director.mood) return;
    _director.follow(mood);
    if (mounted) _frame();
    // Never during a build (the first call comes from initState).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onMood?.call(_director.mood);
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_follow);
    widget.rhythm?.removeListener(_rhythmChanged);
    widget.companion?.removeListener(_frame);
    widget.purr?.removeListener(_frame);
    widget.world.removeListener(_worldChanged);
    _moodTimer?.cancel();
    _frames?.cancel();
    _clock.dispose();
    _sprites.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calm = MediaQuery.disableAnimationsOf(context);
    if (calm != _calm) {
      _calm = calm;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _frame();
      });
    }
    return Semantics(
      container: true,
      label: _director.mood.description,
      image: true,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _MochiPainter(
            director: _director,
            clock: _clock,
            calm: calm,
            dark: Theme.of(context).brightness == Brightness.dark,
            fill: widget.fill,
            feet: widget.feet,
            stroll: widget.stroll,
            detail: widget.detail,
            color: widget.color,
            accessory: widget.accessory,
            companion: widget.companion,
            duo: widget.duo,
            theme: widget.theme,
            companionAccessory: widget.companionAccessory,
            deskAccessory: widget.deskAccessory,
            burst: widget.burst,
            badge: widget.badge,
            sprites: widget.sprites ? _sprites : null,
            ratio: MediaQuery.devicePixelRatioOf(context),
            window: MediaQuery.sizeOf(context),
            quantum: () => MochiView.quantum(_fps),
            purr: widget.purr,
            season: widget.season,
            petAway: widget.petAway,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// How far Mochi's art reaches from its feet, and Patch's (with his desk and laptop) from the desk's spot, in art
/// units: measured over their loops, both ways round, with everything they can wear or hold (with a margin;
/// test/performance_test.dart checks every pose fits). A picture of a pose holds that much (of what can be seen).
abstract final class ArtReach {
  static const Rect pet = Rect.fromLTRB(-92, -125, 92, 30);
  static const Rect patch = Rect.fromLTRB(-72, -150, 76, 20);

  /// A pose of Mochi's that stays within [pet]: everything but the toys it bats far away (a ball, a butterfly).
  static bool fits(PetPose pose) => pose.effects.every((effect) => effect.x.abs() <= 1.2);
}

class _MochiPainter extends CustomPainter {
  _MochiPainter({
    required this.director,
    required this.clock,
    required this.calm,
    required this.dark,
    required this.fill,
    required this.feet,
    required this.stroll,
    required this.detail,
    required this.color,
    required this.accessory,
    required this.companion,
    required this.duo,
    required this.theme,
    required this.companionAccessory,
    required this.deskAccessory,
    required this.burst,
    required this.badge,
    this.sprites,
    this.ratio = 1,
    this.window,
    this.quantum,
    this.purr,
    this.season,
    this.petAway = false,
  }) : super(repaint: clock);

  /// Mochi is out on the desktop: only Patch is drawn.
  final bool petAway;

  /// Today's holiday, for the decoration beside Patch's desk.
  final SeasonalEvent? Function()? season;

  /// While Mochi purrs, its purr lines are drawn with it (and it isn't a picture).
  final PurrSession? purr;

  bool get _purring => purr?.active ?? false;

  final AttentionLevel? badge;

  /// The pictures of poses already drawn (null: the art is drawn every frame).
  final PoseSprites? sprites;

  /// The display's scale (physical pixels per logical pixel), for the pictures.
  final double ratio;

  /// The window (logical pixels): the view sits at its bottom, so only that much above it can be seen. Null: the
  /// view is all there is.
  final Size? window;

  /// The animations' grid right now (seconds), with [sprites].
  final double Function()? quantum;

  /// The Mac's badge colours: grey for a note, orange when Claude needs you, red for an API error.
  static Color badgeColor(AttentionLevel level) => switch (level) {
    AttentionLevel.info => const Color(0xFF9A93A6),
    AttentionLevel.attention => const Color(0xFFFF9F0A),
    AttentionLevel.alert => const Color(0xFFFF453A),
  };

  /// A dot at the top right of Mochi, on a light (or, in the dark, dark) rim.
  void _paintBadge(Canvas canvas, Offset feet, double petHeight) {
    final level = badge;
    if (level == null) return;
    final radius = math.max(3.2, petHeight * 0.085);
    final centre = Offset(feet.dx + petHeight * 0.42, feet.dy - petHeight * 0.92);
    canvas.drawCircle(centre, radius * 1.28, Paint()..color = dark ? const Color(0x8C000000) : const Color(0xEBFFFFFF));
    canvas.drawCircle(centre, radius, Paint()..color = badgeColor(level));
  }

  final PetDirector director;
  final ValueNotifier<double> clock;
  final bool calm;
  final bool dark;
  final double fill;
  final double feet;
  final StrollSample? Function()? stroll;
  final RenderDetail detail;
  final PetColor color;
  final Accessory? accessory;
  final CompanionDirector? companion;
  final DuoLayout? Function()? duo;
  final OfficeTheme theme;
  final Accessory? companionAccessory;
  final Accessory? deskAccessory;
  final bool burst;

  /// Everything the pictures depend on besides the pose: the display's scale, the art's scale, the coat, what's worn,
  /// light or dark, the detail level, the room's style.
  String _context(double scale, double k) =>
      '$ratio|$scale|$k|${color.name}|${accessory?.name}|$dark|${detail.name}|${PetRenderer.stage.name}|${theme.name}|'
      '${companionAccessory?.name}|${deskAccessory?.name}|$calm';

  /// Mochi in [pose] with its feet at [at]: its picture if there are pictures and the pose [repeats] (and it isn't
  /// fading or throwing something far), else the art. [across]: the picture may be cut at the window's sides (Mochi
  /// stays put in it).
  void _pet(Canvas canvas, Size size, PetPose pose, Offset at, double scale, {required bool across, bool repeats = true}) {
    final sprites = this.sprites;
    if (sprites == null || !repeats || pose.opacity != 1 || !ArtReach.fits(pose)) {
      PetRenderer.draw(pose, GContext(canvas), at, scale, PetPalette(color), accessory: accessory, dark: dark, detail: detail);
      return;
    }
    sprites.draw(
      canvas,
      'pet ${jsonEncode(pose.toJson())}',
      at: at,
      bounds: _bounds(ArtReach.pet, scale, size, at, across: across),
      ratio: ratio,
      moving: !across,
      paint: (c) =>
          PetRenderer.draw(pose, GContext(c), Offset.zero, scale, PetPalette(color), accessory: accessory, dark: dark, detail: detail),
    );
  }

  /// [reach] (art units) at [scale] around [at], cut to what can be seen of the window: above the view, as much as the
  /// window shows; at the sides, the view's own edges when [across] (otherwise all of the reach, as the origin moves).
  Rect _bounds(Rect reach, double scale, Size size, Offset at, {required bool across}) {
    final above = math.max(0.0, (window?.height ?? size.height) - size.height);
    var bounds = Rect.fromLTRB(reach.left * scale, reach.top * scale, reach.right * scale, reach.bottom * scale);
    final seen = Rect.fromLTRB(across ? 0 : double.negativeInfinity, -above, across ? size.width : double.infinity, size.height).shift(-at);
    bounds = bounds.intersect(seen);
    return bounds.isEmpty ? Rect.zero : bounds;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height - size.height * feet;
    final layout = duo?.call();
    final patch = companion;
    final scale = size.height * fill / 66;
    sprites?.use(_context(scale, layout?.home.unit ?? 0));
    if (layout != null && patch != null) return _paintDuo(canvas, size, baseline, layout, patch);
    if (petAway) return;
    final roam = stroll?.call();
    final frame = director.pose(clock.value, roam: roam, quantum: sprites == null ? null : quantum?.call());
    final purring = _purring;
    final pose = purring ? PurrSession.decorate(frame.pose, clock.value, calm: calm) : frame.pose;
    _pet(canvas, size, pose, Offset(size.width / 2, baseline), scale, across: true, repeats: frame.repeats && !purring);
    final g = GContext(canvas);
    _paintBadge(canvas, Offset(size.width / 2, baseline), PetRenderer.bodyHeight * scale);
    final elapsed = burst ? patch?.burstAt(clock.value) : null;
    if (elapsed != null) {
      CelebrationArt.draw(
        g,
        elapsed,
        center: Offset(size.width / 2, baseline),
        petHeight: PetRenderer.bodyHeight * scale,
        spread: size.width * 0.42,
        unit: size.height / 24,
        reduced: calm,
      );
    }
  }

  /// Patch at his desk and Mochi beside him (or wherever it's pottering), or both in a moment together: its path runs
  /// from where Mochi stands (0) to Patch's desk (1).
  void _paintDuo(Canvas canvas, Size size, double baseline, DuoLayout layout, CompanionDirector patch) {
    final g = GContext(canvas);
    final home = layout.home;
    final k = home.unit;
    final sprites = this.sprites;
    final quantum = sprites == null ? null : this.quantum?.call();
    final now = clock.value;
    final t = PetDirector.quantize(now, quantum);
    final scene = patch.scene(now);
    final art = 100 + (calm ? t * 0.5 : t);
    final roam = stroll?.call();
    // A moment together runs from Mochi's spot to Patch's desk.
    final from = roam?.x ?? home.petHome;
    final span = math.max(1.0, home.deskX - from);
    if (patch.visible) {
      final patchFrame = scene == null ? patch.frame(now, quantum: quantum) : (pose: scene.companion, repeats: false);
      final pose = patchFrame.pose;
      final desk = Offset(layout.local(home.deskX), baseline);
      void draw(Canvas c, Offset at) => CompanionRenderer.draw(
        pose,
        GContext(c),
        at,
        k,
        offsetX: pose.x * span,
        accessory: companionAccessory,
        dark: dark,
        time: art,
        reduced: calm,
        deskFront: (desk) => ThemeRenderer.deskFront(theme, desk, dark: dark, accessory: deskAccessory),
      );
      // At his desk in a loop he's a picture too; stepping away from it or in a moment of his own, he's drawn.
      if (sprites == null || pose.x != 0 || !patchFrame.repeats) {
        draw(canvas, desk);
      } else {
        final time = CompanionRenderer.timeKey(pose, art, scale: k, accessory: companionAccessory, reduced: calm);
        sprites.draw(
          canvas,
          'patch $time ${jsonEncode(pose.toJson())}',
          at: desk,
          bounds: _bounds(ArtReach.patch, k, size, desk, across: true),
          ratio: ratio,
          paint: (c) => draw(c, Offset.zero),
        );
      }
    }
    // The holiday's little decoration on the floor, just left of Patch's desk.
    final occasion = season?.call();
    if (occasion != null && SeasonRenderContext.decorateMenuBar) {
      SeasonArt.menuBarAccent(occasion, g, Offset(layout.local(home.deskX - (HomeStage.deskHalf + 2) * k), baseline), k * 2.4, dark: dark);
    }
    final PetPose pet;
    final double x;
    var repeats = false;
    if (scene != null) {
      // The moment's own Mochi, from its spot (its x in path units towards Patch; each frame is a fresh pose, so it
      // can be changed).
      pet = scene.pet;
      x = from + pet.x * span;
      pet.x = 0;
    } else {
      final frame = director.pose(now, roam: roam, quantum: quantum);
      pet = frame.pose;
      repeats = frame.repeats;
      x = from;
    }
    final purring = _purring;
    if (!petAway) {
      _pet(
        canvas,
        size,
        purring ? PurrSession.decorate(pet, now, calm: calm) : pet,
        Offset(layout.local(x), baseline),
        k,
        across: false,
        repeats: repeats && !purring,
      );
      _paintBadge(canvas, Offset(layout.local(x), baseline), PetRenderer.bodyHeight * k);
    }
    for (final prop in scene?.props ?? const <SceneProp>[]) {
      final point = Offset(layout.local(from + prop.x * span), baseline - prop.y * PetRenderer.bodyHeight * k);
      EffectRenderer.drawProp(prop, g, point, k, dark);
    }
    final elapsed = burst ? patch.burstAt(now) : null;
    if (elapsed != null) {
      CelebrationArt.draw(
        g,
        elapsed,
        center: Offset(layout.local((home.petHome + home.deskX) / 2), baseline),
        petHeight: PetRenderer.bodyHeight * k,
        spread: home.span * 0.85,
        unit: size.height / 24,
        big: patch.burst?.big ?? false,
        reduced: calm,
      );
    }
  }

  @override
  bool shouldRepaint(_MochiPainter old) =>
      old.director != director ||
      old.calm != calm ||
      old.dark != dark ||
      old.fill != fill ||
      old.feet != feet ||
      old.stroll != stroll ||
      old.detail != detail ||
      old.color != color ||
      old.accessory != accessory ||
      old.companion != companion ||
      old.duo != duo ||
      old.theme != theme ||
      old.companionAccessory != companionAccessory ||
      old.deskAccessory != deskAccessory ||
      old.burst != burst ||
      old.badge != badge ||
      old.sprites != sprites ||
      old.ratio != ratio ||
      old.window != window ||
      old.purr != purr ||
      old.season != season ||
      old.petAway != petAway;
}
