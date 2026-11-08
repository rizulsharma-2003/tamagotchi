// Sticky notes from Mochi (docs/SPRINT_2.md X9): little notes Mochi leaves on your desktop, in its own voice, on the
// native stage (N1): "Claude finished the tests ✓", "Claude finished while you were away", "Claude needs you",
// "Stretch break?". Each can be pinned (it stays, even after a restart) or dismissed (×); a click on the note opens
// Mochi's window. Never more than three: a new one sends the oldest unpinned one away, and with three pinned there's
// no room for more. Unpinned notes leave by themselves after a quarter of an hour.
//
// - Notes come only when Mischief may (MischiefGate: not over a full-screen app, in quiet hours, while reactions are
//   paused, or while nobody can see the screen); notes already up hide meanwhile and come back after.
// - Each note is one picture (its paper, Mochi's face, the words, the pin and the ×, drawn at the display's scale; a
//   hovered button is another picture), stacked at the top right of the main display's work area. It can be dragged
//   somewhere else. Nothing runs for them besides a short fade when one arrives or leaves, and one timer for the
//   oldest one's quarter of an hour (none while the screen can't be seen).
// - What they say: only what Mochi saw on this PC (a project's folder name at most), never prompts or files.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart' show mochiFontFamily;

import '../../core/desktop_settings.dart';
import '../../core/json_store.dart';
import '../../core/mischief.dart';
import '../../core/pc_rhythm.dart';
import '../../platform/displays.dart';
import '../../platform/native_stage.dart';
import 'stage_cast.dart';
import 'stage_sprites.dart';

/// What a note is about (its colour, and which older note it replaces).
enum NoteKind { testsPassed, finishedAway, needsYouAway, stretch, streak, hello }

/// One note.
class StickyNote {
  StickyNote({required this.id, required this.kind, required this.title, required this.detail, required this.created, this.pinned = false});

  final int id;
  final NoteKind kind;
  final String title;
  final String detail;
  final DateTime created;
  bool pinned;

  /// Where it was dragged to (its top-left, physical pixels); null: its place in the stack.
  (int, int)? movedTo;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'title': title,
    'detail': detail,
    'created': created.toIso8601String(),
    if (movedTo != null) 'at': [movedTo!.$1, movedTo!.$2],
  };

  static StickyNote? fromJson(Object? json, int id) {
    if (json is! Map) return null;
    final kind = NoteKind.values.where((kind) => kind.name == json['kind']).firstOrNull;
    final title = json['title'], detail = json['detail'];
    final created = json['created'] is String ? DateTime.tryParse(json['created'] as String) : null;
    if (kind == null || title is! String || detail is! String || created == null) return null;
    final note = StickyNote(id: id, kind: kind, title: title, detail: detail, created: created, pinned: true);
    final at = json['at'];
    if (at is List && at.length == 2 && at.every((value) => value is int)) note.movedTo = (at[0] as int, at[1] as int);
    return note;
  }
}

/// The words, in Mochi's voice (docs/MOCHI_VOICE.md: warm, brief, honest), naming this PC.
abstract final class NoteWords {
  static ({String title, String detail}) testsPassed(String? project) =>
      (title: 'Claude finished the tests ✓', detail: project == null ? 'All green on your PC.' : 'All green in $project on your PC.');

  static ({String title, String detail}) finishedAway(String? project) =>
      (title: 'Claude finished while you were away', detail: project == null ? 'It’s ready for you on your PC.' : '$project is ready for you on your PC.');

  static ({String title, String detail}) needsYouAway(String? project) =>
      (title: 'Claude needs you', detail: project == null ? 'It’s waiting on your PC.' : 'It’s waiting in $project on your PC.');

  static const ({String title, String detail}) stretch = (title: 'Stretch break?', detail: 'I’ll keep an eye on your PC.');

  static ({String title, String detail}) streak(int days) => (title: '$days days in a row!', detail: 'You and Claude, busy on your PC.');

  static const ({String title, String detail}) hello = (title: 'Hi! This is a note from me', detail: 'I leave these on your PC now and then.');
}

class StickyNotes {
  StickyNotes({
    required this.stage,
    required this.cast,
    required this.gate,
    required this.rhythm,
    required this.displays,
    required this.settings,
    required this.store,
    this.onOpen,
    DateTime Function()? clock,
    double Function()? seconds,
    this.fadeInterval = const Duration(milliseconds: 33),
  }) : sprites = StageSprites(stage, budget: 6 << 20),
       _clock = clock ?? DateTime.now,
       _seconds = seconds ?? _monotonic();

  final NativeStage stage;
  final StageCast cast;
  final MischiefGate gate;
  final PcRhythm rhythm;
  final Displays displays;
  final DesktopSettings settings;

  /// The pinned notes (`notes.json`), so they come back after a restart.
  final JsonStore store;

  /// A click on a note: Mochi's window.
  final void Function()? onOpen;
  final StageSprites sprites;
  final DateTime Function() _clock;
  final double Function() _seconds;
  final Duration fadeInterval;

  static double Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  /// At most this many notes.
  static const int most = 3;

  /// An unpinned note leaves after this long.
  static const Duration lasts = Duration(minutes: 15);

  /// A note's size (logical pixels), and its buttons (from its top-right corner).
  static const Size size = Size(248, 104);
  static const double button = 22;
  static const double gap = 12;

  /// A fade in or out takes this long (seconds).
  static const double fade = 0.3;

  final List<StickyNote> _notes = [];
  final Map<int, int> _actors = {};
  final Map<int, String?> _hover = {};
  final Map<int, (double, double)> _fades = {};
  int _nextId = 1;
  bool _started = false;
  bool _hidden = false;
  Timer? _fadeTimer;
  Timer? _expiry;
  StreamSubscription<StagePointer>? _pointer;
  ({int note, int x, int y, int left, int top, bool dragged})? _press;

  /// The notes up now, oldest first.
  List<StickyNote> get notes => List.unmodifiable(_notes);

  /// Notes are hidden for now (Mischief is paused).
  bool get hidden => _hidden;

  /// Any timer (tests: none while the screen can't be seen).
  bool get ticking => _fadeTimer != null || _expiry != null;

  /// The actor showing [note].
  int? actorOf(StickyNote note) => _actors[note.id];

  void start() {
    if (_started) return;
    _started = true;
    final saved = store.read();
    if (saved is List) {
      for (final json in saved) {
        final note = StickyNote.fromJson(json, _nextId);
        if (note != null && _notes.length < most) {
          _notes.add(note);
          _nextId++;
        }
      }
    }
    gate.addListener(_gateChanged);
    _pointer = stage.pointer.listen(_pointerEvent);
    _gateChanged();
  }

  bool get _may => gate.may(MischiefExtra.stickyNotes);

  /// Leaves a note (if Mischief may now, or [preview]: you asked in Settings). Replaces an older one about the same,
  /// and sends the oldest unpinned one away when there are already [most]. Null when it didn't.
  StickyNote? leave(NoteKind kind, ({String title, String detail}) words, {bool preview = false}) {
    final why = gate.why(MischiefExtra.stickyNotes);
    final allowed = preview ? !{MischiefPause.unsupported, MischiefPause.unseen, MischiefPause.fullScreen}.contains(why) : why == null;
    if (!allowed || !_started) return null;
    final same = _notes.where((note) => note.kind == kind && !note.pinned).toList();
    for (final note in same) {
      _remove(note, animate: false);
    }
    if (_notes.length >= most) {
      final oldest = _notes.where((note) => !note.pinned).firstOrNull;
      if (oldest == null) return null;
      _remove(oldest, animate: false);
    }
    final note = StickyNote(id: _nextId++, kind: kind, title: words.title, detail: words.detail, created: _clock());
    _notes.add(note);
    _hidden = false;
    _fades[note.id] = (_seconds(), 1);
    _layout();
    _armExpiry();
    return note;
  }

  /// Dismisses [note] (the ×).
  void dismiss(StickyNote note) => _remove(note, animate: true);

  /// Pins or unpins [note].
  void togglePin(StickyNote note) {
    note.pinned = !note.pinned;
    _save();
    _draw(note);
    _armExpiry();
  }

  /// [note] is fading out (on its way).
  bool _leaving(StickyNote note) => (_fades[note.id]?.$2 ?? 0) < 0;

  void _remove(StickyNote note, {required bool animate}) {
    if (!_notes.contains(note)) return;
    if (animate && !_hidden) {
      if (_leaving(note)) return;
      _fades[note.id] = (_seconds(), -1);
      _tickFades();
      return;
    }
    _notes.remove(note);
    _fades.remove(note.id);
    _hover.remove(note.id);
    final actor = _actors.remove(note.id);
    if (actor != null) cast.remove([actor]);
    if (note.pinned) _save();
    _layout();
    _armExpiry();
  }

  void _save() => store.write([for (final note in _notes.where((note) => note.pinned)) note.toJson()]);

  // MARK: Showing them

  void _gateChanged() {
    final hide = !_may && gate.why(MischiefExtra.stickyNotes) != MischiefPause.calm;
    if (hide == _hidden && _started) {
      if (!hide) _armExpiry();
      return;
    }
    _hidden = hide;
    if (hide) {
      _fadeTimer?.cancel();
      _fadeTimer = null;
      _expiry?.cancel();
      _expiry = null;
      for (final actor in _actors.values) {
        cast.hide(actor);
      }
      cast.flush();
    } else {
      _layout();
      _armExpiry();
    }
  }

  /// Where the stack starts: the top right of the main display's work area.
  DisplayArea? get _display {
    final list = displays.list();
    return list.isEmpty ? null : PetPlacing.primaryOf(list);
  }

  /// [note]'s top-left (physical pixels).
  (int, int)? _placeOf(StickyNote note, DisplayArea display) {
    final moved = note.movedTo;
    if (moved != null) return moved;
    final index = _notes.where((other) => other.movedTo == null).toList().indexOf(note);
    if (index < 0) return null;
    final s = display.scale;
    final work = display.workArea;
    return ((work.right - (size.width + 16) * s).round(), (work.top + (16 + index * (size.height + gap)) * s).round());
  }

  void _layout() {
    if (_hidden || !_started) return;
    for (final note in _notes) {
      _draw(note);
    }
  }

  void _draw(StickyNote note) {
    if (_hidden) return;
    final display = _display;
    if (display == null) return;
    final ratio = display.scale;
    sprites.use('note|$ratio');
    final hover = _hover[note.id];
    final key = 'note ${note.id} ${note.kind.name} ${note.pinned} $hover ${note.title} ${note.detail}';
    final ready = sprites.lookup(key);
    if (ready == null) {
      unawaited(
        sprites
            .ensure(
              key,
              SpriteRecipe(
                bounds: Rect.fromLTWH(-6, -4, size.width + 12, size.height + 12),
                ratio: ratio,
                paint: (canvas) => NoteArt.paint(canvas, note, hover: hover, color: settings.petColor),
              ),
            )
            .then((sprite) {
              if (sprite != null && _notes.contains(note)) _place(note, sprite, display);
            }),
      );
      return;
    }
    _place(note, ready, display);
  }

  void _place(StickyNote note, StageSprite sprite, DisplayArea display) {
    if (_hidden) return;
    final at = _placeOf(note, display);
    if (at == null) return;
    final actor = _actors.putIfAbsent(note.id, stage.newActor);
    var alpha = 255;
    var drop = 0;
    final fade = _fades[note.id];
    if (fade != null) {
      final u = ((_seconds() - fade.$1) / StickyNotes.fade).clamp(0.0, 1.0);
      final shown = fade.$2 > 0 ? u : 1 - u;
      alpha = (shown * 255).round();
      // Arriving, it drops in from a little above.
      if (fade.$2 > 0) drop = ((1 - u) * (1 - u) * -18 * display.scale).round();
      if (_fadeTimer == null) _tickFadesSoon();
    }
    cast.place(sprite.at(actor, at.$1, at.$2 + drop, alpha: alpha, topmost: true, hand: true));
    cast.flush();
  }

  void _tickFadesSoon() => _fadeTimer ??= Timer.periodic(fadeInterval, (_) => _tickFades());

  void _tickFades() {
    if (_hidden) return;
    final now = _seconds();
    for (final MapEntry(key: id, value: (start, direction)) in Map.of(_fades).entries) {
      final note = _notes.where((note) => note.id == id).firstOrNull;
      if (note == null) {
        _fades.remove(id);
        continue;
      }
      final done = now - start >= fade;
      if (done) {
        _fades.remove(id);
        if (direction < 0) {
          _remove(note, animate: false);
          continue;
        }
      }
      _draw(note);
    }
    if (_fades.isEmpty) {
      _fadeTimer?.cancel();
      _fadeTimer = null;
    } else {
      _tickFadesSoon();
    }
  }

  /// One timer, for when the oldest unpinned note's time is up (none while hidden).
  void _armExpiry() {
    _expiry?.cancel();
    _expiry = null;
    if (_hidden) return;
    final unpinned = _notes.where((note) => !note.pinned && !_leaving(note)).toList();
    if (unpinned.isEmpty) return;
    final due = unpinned.first.created.add(lasts).difference(_clock());
    _expiry = Timer(due.isNegative ? Duration.zero : due, () {
      _expiry = null;
      final now = _clock();
      for (final note in _notes.where((note) => !note.pinned && !_leaving(note) && !now.isBefore(note.created.add(lasts))).toList()) {
        dismiss(note);
      }
      _armExpiry();
    });
  }

  // MARK: The pointer

  StickyNote? _noteOf(int actor) {
    for (final MapEntry(key: id, value: shown) in _actors.entries) {
      if (shown == actor) return _notes.where((note) => note.id == id).firstOrNull;
    }
    return null;
  }

  void _pointerEvent(StagePointer event) {
    final note = _noteOf(event.actor);
    if (note == null) return;
    final display = _display;
    final sprite = cast.shown(event.actor);
    if (display == null || sprite == null) return;
    final s = display.scale;
    final stageSprite = sprites.lookup('note ${note.id} ${note.kind.name} ${note.pinned} ${_hover[note.id]} ${note.title} ${note.detail}');
    final origin = stageSprite == null ? (0, 0) : (stageSprite.originX, stageSprite.originY);
    // Where on the note (logical pixels from its top-left).
    final x = (event.x - origin.$1) / s, y = (event.y - origin.$2) / s;
    final target = NoteArt.hit(x, y);
    switch (event.kind) {
      case StagePointerKind.move || StagePointerKind.enter:
        final press = _press;
        if (press != null && press.note == note.id) {
          final dx = event.screenX - press.x, dy = event.screenY - press.y;
          if (press.dragged || dx.abs() + dy.abs() > 6) {
            _press = (note: press.note, x: press.x, y: press.y, left: press.left, top: press.top, dragged: true);
            note.movedTo = (press.left + dx, press.top + dy);
            _draw(note);
          }
          return;
        }
        if (_hover[note.id] != target) {
          _hover[note.id] = target;
          _draw(note);
        }
      case StagePointerKind.leave:
        if (_hover[note.id] != null) {
          _hover[note.id] = null;
          _draw(note);
        }
      case StagePointerKind.down:
        final at = _placeOf(note, display);
        if (at != null) _press = (note: note.id, x: event.screenX, y: event.screenY, left: at.$1, top: at.$2, dragged: false);
      case StagePointerKind.up:
        final press = _press;
        _press = null;
        if (press == null || press.note != note.id) return;
        if (press.dragged) {
          if (note.pinned) _save();
          return;
        }
        switch (target) {
          case 'close':
            dismiss(note);
          case 'pin':
            togglePin(note);
          default:
            onOpen?.call();
            if (!note.pinned) dismiss(note);
        }
      case StagePointerKind.cancel:
        _press = null;
      default:
        break;
    }
  }

  void stop() {
    _started = false;
    gate.removeListener(_gateChanged);
    unawaited(_pointer?.cancel());
    _pointer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _expiry?.cancel();
    _expiry = null;
    cast.remove(_actors.values.toList());
    _actors.clear();
  }

  void dispose() {
    stop();
    sprites.dispose();
  }
}

/// A note's picture: paper, Mochi's face, the words, the pin and the × (logical pixels from its top-left).
abstract final class NoteArt {
  static const Map<NoteKind, Color> paper = {
    NoteKind.testsPassed: Color(0xFFD9F7E4),
    NoteKind.finishedAway: Color(0xFFFFF1B8),
    NoteKind.needsYouAway: Color(0xFFFFDCC8),
    NoteKind.stretch: Color(0xFFDDEBFF),
    NoteKind.streak: Color(0xFFF1DEFF),
    NoteKind.hello: Color(0xFFFFF1B8),
  };

  static Rect get closeRect => Rect.fromLTWH(StickyNotes.size.width - 8 - StickyNotes.button, 6, StickyNotes.button, StickyNotes.button);
  static Rect get pinRect => closeRect.shift(const Offset(-StickyNotes.button - 4, 0));

  /// What's at [x], [y] on a note: 'close', 'pin', or null (the note itself).
  static String? hit(double x, double y) {
    final point = Offset(x, y);
    if (closeRect.inflate(3).contains(point)) return 'close';
    if (pinRect.inflate(3).contains(point)) return 'pin';
    return null;
  }

  static void paint(Canvas canvas, StickyNote note, {String? hover, PetColor color = PetColor.cream}) {
    const size = StickyNotes.size;
    final body = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    // A soft shadow, the paper, a hairline edge.
    canvas
      ..drawRRect(body.shift(const Offset(0, 3)), Paint()
        ..color = const Color(0x2E000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4))
      ..drawRRect(body, Paint()..color = paper[note.kind]!)
      ..drawRRect(body, Paint()
        ..color = const Color(0x1A000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    // A strip of tape at the top.
    canvas
      ..save()
      ..translate(size.width / 2, 0)
      ..rotate(-0.06)
      ..drawRect(const Rect.fromLTWH(-24, -5, 48, 12), Paint()..color = const Color(0x66FFFFFF))
      ..restore();
    // Mochi's face, peeking in at the left.
    final pose = PetPose()
      ..eyes = note.kind == NoteKind.stretch ? PetEyes.happy : PetEyes.open
      ..earPerk = 0.5;
    PetRenderer.draw(pose, GContext(canvas), const Offset(34, 72), 0.62, PetPalette(color));
    // The words.
    const left = 66.0;
    final width = size.width - left - 14;
    TextPainter text(String value, {required double size, required FontWeight weight, Color color = const Color(0xFF2D2A32), int lines = 2}) =>
        TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(fontFamily: mochiFontFamily, fontFamilyFallback: const ['Segoe UI', 'sans-serif'], fontSize: size, fontWeight: weight, color: color, height: 1.2),
          ),
          textDirection: TextDirection.ltr,
          maxLines: lines,
          ellipsis: '…',
        )..layout(maxWidth: width);
    final title = text(note.title, size: 14, weight: FontWeight.w800, lines: 2)..layout(maxWidth: width - 50);
    final detail = text(note.detail, size: 12.5, weight: FontWeight.w600, color: const Color(0xFF55505E));
    final signature = text('— Mochi', size: 11, weight: FontWeight.w700, color: const Color(0xFF8A8494), lines: 1);
    title.paint(canvas, const Offset(left, 12));
    detail.paint(canvas, Offset(left, 14 + title.height + 4));
    signature.paint(canvas, Offset(size.width - 14 - signature.width, size.height - 8 - signature.height));
    // The pin and the ×.
    _button(canvas, pinRect, hover == 'pin', note.pinned, (center, ink) {
      final head = Paint()..color = note.pinned ? const Color(0xFFE5484D) : ink;
      canvas
        ..drawCircle(center.translate(0, -2.5), 3.6, head)
        ..drawLine(center.translate(0, 0.5), center.translate(0, 6), Paint()
          ..color = ink
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round);
    });
    _button(canvas, closeRect, hover == 'close', false, (center, ink) {
      final pen = Paint()
        ..color = ink
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      const r = 4.0;
      canvas
        ..drawLine(center.translate(-r, -r), center.translate(r, r), pen)
        ..drawLine(center.translate(r, -r), center.translate(-r, r), pen);
    });
  }

  static void _button(Canvas canvas, Rect rect, bool hovered, bool on, void Function(Offset center, Color ink) glyph) {
    if (hovered || on) {
      canvas.drawCircle(rect.center, rect.width / 2, Paint()..color = Color(hovered ? 0x22000000 : 0x14000000));
    }
    glyph(rect.center, const Color(0xFF4A4552));
  }

  /// [note] drawn into an image (tests).
  static ui.Image image(StickyNote note, double ratio) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    paint(canvas, note);
    final picture = recorder.endRecording();
    final image = picture.toImageSync((StickyNotes.size.width * ratio).ceil(), (StickyNotes.size.height * ratio).ceil());
    picture.dispose();
    return image;
  }
}
