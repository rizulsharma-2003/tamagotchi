// Today's Recap (Sprint 2 W16), the Mac's recap window in Mochi's window: the card for a day (today first; back a day at
// a time through the week kept), Copy Image and Save Image… (Ctrl+S). The picture is drawn by the app, never a screen
// capture; it's saved to Downloads. Only the characters on the card move, 30 frames a second (8 with animations off),
// and nothing moves while the screen can't be seen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/desktop_settings.dart' show CompanionVisibility;
import '../../desktop.dart';
import '../../platform/image_export.dart';
import 'recap_card.dart';

class RecapScreen extends StatefulWidget {
  const RecapScreen({super.key, required this.desktop, required this.images});

  final MochiDesktop desktop;

  /// Where the picture goes (the clipboard, Downloads).
  final ImageExport images;

  @override
  State<RecapScreen> createState() => RecapScreenState();
}

class RecapScreenState extends State<RecapScreen> {
  late DateTime _day = _today();
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final FocusNode _focus = FocusNode(debugLabel: 'Recap');
  Timer? _frames;
  bool _calm = false;
  bool _copied = false;
  Timer? _copiedTimer;
  bool _working = false;

  /// What happened to the last save or copy (for the line under the buttons).
  String? _note;
  String? _saved;

  MochiDesktop get desktop => widget.desktop;

  /// The day showing (tests).
  DateTime get day => _day;

  DateTime _today() {
    final now = desktop.world.world.date;
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    desktop.rhythm.addListener(_animate);
    _animate();
  }

  /// The characters' clock: 30 frames a second (8 with animations off), none while the screen can't be seen.
  void _animate() {
    if (!mounted) return;
    final unseen = desktop.rhythm.unseen;
    _frames?.cancel();
    _frames = null;
    _clock.value = desktop.world.now();
    if (unseen) return;
    final fps = _calm ? 8 : 30;
    _frames = Timer.periodic(Duration(microseconds: (1e6 / fps).round()), (_) => _clock.value = desktop.world.now());
  }

  /// Frames a second now (tests).
  double get fps => _frames == null ? 0 : (_calm ? 8 : 30);

  @override
  void dispose() {
    desktop.rhythm.removeListener(_animate);
    _frames?.cancel();
    _copiedTimer?.cancel();
    _clock.dispose();
    _focus.dispose();
    super.dispose();
  }

  RecapLook _look(BuildContext context) {
    final settings = desktop.settings;
    final localizations = MaterialLocalizations.of(context);
    final twentyFour = MediaQuery.alwaysUse24HourFormatOf(context);
    return RecapLook(
      petName: settings.petName,
      companionName: settings.companionName,
      petColor: settings.petColor,
      petAccessory: settings.petAccessory,
      companionAccessory: settings.companionAccessory,
      showCompanion: settings.companionVisibility != CompanionVisibility.never,
      reducedMotion: _calm || desktop.world.world.reducedMotion,
      seed: desktop.world.world.seed,
      formatTime: (time) => localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time.toLocal()), alwaysUse24HourFormat: twentyFour),
    );
  }

  void _step(int days) => setState(() {
    _day = DateTime(_day.year, _day.month, _day.day + days);
    _note = null;
    _saved = null;
  });

  Future<ExportedImage> _picture(w.DailyRecap recap, RecapLook look) => RecapImage.render(recap, look, desktop.world.world.date);

  /// The keys come back here once a button that was disabled while the picture was drawn lets go of them.
  void _keepKeys() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_focus.hasFocus) _focus.requestFocus();
  });

  Future<void> copy(w.DailyRecap recap, RecapLook look) async {
    if (_working) return;
    setState(() => _working = true);
    var ok = false;
    try {
      ok = await widget.images.copy(await _picture(recap, look));
    } on Object {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _copied = ok;
      _saved = null;
      _note = ok ? null : 'The picture couldn’t be copied.';
    });
    SemanticsService.announce(ok ? 'Copied the recap as a picture' : 'The picture couldn’t be copied', TextDirection.ltr);
    _keepKeys();
    _copiedTimer?.cancel();
    if (ok) {
      _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  Future<void> save(w.DailyRecap recap, RecapLook look) async {
    if (_working) return;
    setState(() => _working = true);
    String? path;
    try {
      final picture = await _picture(recap, look);
      path = await widget.images.save(picture.png, 'Recap ${w.DailyRecap.dayKey(recap.day)}.png');
    } on Object {
      path = null;
    }
    if (!mounted) return;
    final name = path?.split(RegExp(r'[\\/]')).last;
    setState(() {
      _working = false;
      _saved = path;
      _note = path == null ? 'The picture couldn’t be saved.' : 'Saved to Downloads as $name.';
    });
    SemanticsService.announce(_note!, TextDirection.ltr);
    _keepKeys();
  }

  @override
  Widget build(BuildContext context) {
    final calm = MediaQuery.disableAnimationsOf(context);
    if (calm != _calm) {
      _calm = calm;
      WidgetsBinding.instance.addPostFrameCallback((_) => _animate());
    }
    final p = context.palette;
    return ListenableBuilder(
      listenable: Listenable.merge([desktop.recap, desktop.focus, desktop.settings]),
      builder: (context, _) {
        final recap = desktop.recap.recap(_day);
        final look = _look(context);
        final now = desktop.world.world.date;
        final today = _today();
        final isToday = !_day.isBefore(today);
        final earliest = desktop.recap.earliestDay;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => unawaited(save(recap, look)),
            const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => unawaited(save(recap, look)),
          },
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.l),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: RecapCardPainter.size.width),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(
                          container: true,
                          label: RecapText.spoken(recap, look, now),
                          image: true,
                          child: AspectRatio(
                            aspectRatio: RecapCardPainter.size.width / RecapCardPainter.size.height,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(RecapCardPainter.radius),
                                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.14), blurRadius: 16, offset: const Offset(0, 6))],
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RepaintBoundary(child: CustomPaint(painter: RecapCardPainter(recap: recap, look: look, now: now))),
                                  RepaintBoundary(child: CustomPaint(painter: RecapStagePainter(recap: recap, look: look, clock: _clock))),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: Space.m),
                        Wrap(
                          spacing: Space.s,
                          runSpacing: Space.s,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Previous day',
                                  onPressed: _day.isAfter(earliest) ? () => _step(-1) : null,
                                  icon: const Icon(Icons.chevron_left_rounded),
                                ),
                                IconButton(
                                  tooltip: 'Next day',
                                  onPressed: isToday ? null : () => _step(1),
                                  icon: const Icon(Icons.chevron_right_rounded),
                                ),
                              ],
                            ),
                            Wrap(
                              spacing: Space.s,
                              runSpacing: Space.s,
                              children: [
                                if (widget.images.canCopy)
                                  OutlinedButton.icon(
                                    onPressed: _working ? null : () => unawaited(copy(recap, look)),
                                    icon: Icon(_copied ? Icons.check_rounded : Icons.content_copy_rounded, size: 18),
                                    label: Text(_copied ? 'Copied' : 'Copy Image'),
                                  ),
                                Tooltip(
                                  message: 'Ctrl+S',
                                  child: FilledButton.icon(
                                    onPressed: _working ? null : () => unawaited(save(recap, look)),
                                    icon: const Icon(Icons.download_rounded, size: 18),
                                    label: const Text('Save Image…'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (_note != null) ...[
                          const SizedBox(height: Space.s),
                          Wrap(
                            spacing: Space.s,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(_note!, style: context.type.footnote.copyWith(color: _saved == null ? p.danger : p.inkSecondary)),
                              if (_saved != null)
                                TextButton(onPressed: () => unawaited(widget.images.reveal(_saved!)), child: const Text('Show in Folder')),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
