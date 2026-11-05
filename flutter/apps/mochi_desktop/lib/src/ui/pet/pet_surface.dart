import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/pet_cues.dart';
import '../../desktop.dart';
import '../shell.dart';
import 'mochi_view.dart';
import 'pet_director.dart';

/// The desktop pet: Mochi on a transparent, always-on-top window, with a speech bubble when Claude needs you or
/// finishes. Click to pet, double-click (or Enter) to open Mochi, drag to move, right-click (or Shift+F10) for the
/// menu.
class PetSurface extends StatefulWidget {
  const PetSurface({
    super.key,
    required this.desktop,
    required this.library,
    required this.lastActivity,
    required this.onAction,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onHide,
  });

  final MochiDesktop desktop;
  final PoseLibrary? library;
  final DateTime Function() lastActivity;
  final ValueChanged<ShellAction> onAction;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final VoidCallback onHide;

  @override
  State<PetSurface> createState() => _PetSurfaceState();
}

class _PetSurfaceState extends State<PetSurface> {
  StreamSubscription<PetCue>? _cues;
  PetMood _mood = PetMood.relaxed;
  String? _bubble;
  Timer? _bubbleTimer;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _cues = widget.desktop.cues.listen(_cue);
  }

  void _cue(PetCue cue) {
    final project = widget.desktop.sessions.primary?.project;
    switch (cue) {
      case PetCue.finished:
        _say(project == null ? 'Claude finished!' : 'Claude finished in $project!', const Duration(seconds: 8));
      case PetCue.snag:
        _say('Claude hit a snag', const Duration(seconds: 8));
      default:
        break;
    }
  }

  void _say(String text, Duration duration) {
    _bubbleTimer?.cancel();
    setState(() => _bubble = text);
    SemanticsService.announce(text, TextDirection.ltr);
    _bubbleTimer = Timer(duration, () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  @override
  void dispose() {
    unawaited(_cues?.cancel());
    _bubbleTimer?.cancel();
    super.dispose();
  }

  Future<void> _menu(Offset position) async {
    final action = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: ShellAction.showMain, child: Text('Show Mochi')),
        PopupMenuItem(value: ShellAction.pair, child: Text('Pair a Phone…')),
        PopupMenuItem(value: ShellAction.settings, child: Text('Settings')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'hide', child: Text('Hide the desktop pet')),
        PopupMenuItem(value: ShellAction.quit, child: Text('Quit Mochi')),
      ],
    );
    if (action is ShellAction) widget.onAction(action);
    if (action == 'hide') widget.onHide();
  }

  @override
  Widget build(BuildContext context) {
    final needsYou = _mood == PetMood.needsYou;
    final project = widget.desktop.sessions.primary?.project;
    final bubble = needsYou ? (project == null ? 'Claude needs you' : 'Claude needs you in $project') : _bubble;
    final p = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: FocusableActionDetector(
        // Not autofocused: the pet shows without taking the focus; Tab reaches it once its window is active.
        autofocus: false,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): _PetIntent(),
          SingleActivator(LogicalKeyboardKey.f10, shift: true): _MenuIntent(),
          SingleActivator(LogicalKeyboardKey.contextMenu): _MenuIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onAction(ShellAction.showMain)),
          _PetIntent: CallbackAction<_PetIntent>(onInvoke: (_) => widget.desktop.interact('pet')),
          _MenuIntent: CallbackAction<_MenuIntent>(onInvoke: (_) => _menu(const Offset(40, 60))),
        },
        child: Semantics(
          container: true,
          button: true,
          label: 'Mochi. ${_mood.description}.${bubble != null && bubble != _mood.description ? ' $bubble.' : ''}',
          hint: 'Press Enter to open Mochi, Space to pet',
          excludeSemantics: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                height: 56,
                child: bubble == null
                    ? null
                    : Align(
                        alignment: Alignment.bottomCenter,
                        child: _Bubble(text: bubble, urgent: needsYou),
                      ),
              ),
              Expanded(
                child: Tooltip(
                  message: _mood.description,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.desktop.interact('pet'),
                    onDoubleTap: () => widget.onAction(ShellAction.showMain),
                    onSecondaryTapUp: (details) => _menu(details.globalPosition),
                    onPanStart: (_) => widget.onDragStart(),
                    onPanEnd: (_) => widget.onDragEnd(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          border: _focused ? Border.all(color: p.focus, width: 2) : null,
                        ),
                        child: MochiView(
                          sessions: widget.desktop.sessions,
                          cues: widget.desktop.cues,
                          library: widget.library,
                          lastActivity: widget.lastActivity,
                          onMood: (mood) => setState(() => _mood = mood),
                          fill: 0.78,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetIntent extends Intent {
  const _PetIntent();
}

class _MenuIntent extends Intent {
  const _MenuIntent();
}

/// A small clay speech bubble with a tail.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.urgent});

  final String text;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(maxWidth: 168),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: claySurface(p, radius: 14, outline: urgent ? p.warning : null),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: context.type.caption.copyWith(color: p.ink, fontWeight: FontWeight.w700),
      ),
    );
  }
}
