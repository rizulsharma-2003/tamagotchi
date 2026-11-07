import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart' show RenderDetail;
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/pet_cues.dart';
import '../../desktop.dart';
import '../shell.dart';
import 'mochi_view.dart';
import 'pet_director.dart';
import 'taskbar_stroll.dart';

/// The desktop pet: Mochi on a transparent, always-on-top window, with a speech bubble when Claude needs you or
/// finishes. On Windows it strolls inside the taskbar ([stroll]), at the taskbar's size. Click to pet, double-click (or
/// Enter) to open Mochi, drag to move (off the taskbar: it stays where it's dropped), right-click (or Shift+F10) for
/// the menu.
///
/// Mochi has a fixed box at the bottom of the window and the bubble goes above it, so the window can grow upwards for
/// the bubble (on the taskbar) without Mochi moving.
class PetSurface extends StatefulWidget {
  const PetSurface({
    super.key,
    required this.desktop,
    required this.stroll,
    required this.library,
    required this.lastActivity,
    required this.onAction,
    required this.onDragStart,
    required this.onHide,
    this.onNativeMenu,
  });

  final MochiDesktop desktop;
  final TaskbarStroll stroll;
  final PoseLibrary? library;
  final DateTime Function() lastActivity;
  final ValueChanged<ShellAction> onAction;

  /// A drag began (the app moves the window with the mouse until it's dropped).
  final VoidCallback onDragStart;
  final VoidCallback onHide;

  /// The tray's menu at the pointer: Mochi's window in the taskbar is too small for its own menu.
  final VoidCallback? onNativeMenu;

  @override
  State<PetSurface> createState() => _PetSurfaceState();
}

class _PetSurfaceState extends State<PetSurface> {
  StreamSubscription<PetCue>? _cues;
  PetMood _mood = PetMood.relaxed;
  String? _bubble;
  Timer? _bubbleTimer;
  bool _focused = false;
  bool _bubbleShown = false;

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
    final native = widget.onNativeMenu;
    if (widget.stroll.onTaskbar && native != null) return native();
    final action = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: ShellAction.showMain, child: Text('Show Mochi')),
        const PopupMenuItem(value: ShellAction.pair, child: Text('Pair a Phone…')),
        const PopupMenuItem(value: ShellAction.settings, child: Text('Settings')),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: ShellAction.toggleRoaming,
          checked: widget.desktop.settings.roamTaskbar,
          child: const Text('Roam along the taskbar'),
        ),
        const PopupMenuItem(value: 'hide', child: Text('Hide the desktop pet')),
        const PopupMenuItem(value: ShellAction.quit, child: Text('Quit Mochi')),
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
    if ((bubble != null) != _bubbleShown) {
      _bubbleShown = bubble != null;
      // The taskbar window makes room for it (after this frame: never during a build).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.stroll.bubble = _bubbleShown;
      });
    }
    final onTaskbar = widget.stroll.onTaskbar;
    final name = widget.desktop.settings.petName;
    // Mochi's box at the bottom of the window: taskbar-sized in the taskbar (the Mac's menu-bar Mochi), the bubble above.
    final stage = onTaskbar ? widget.stroll.box.height : SurfaceSizes.petStage;
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
          label: '$name. ${_mood.describe(name)}.${bubble != null && bubble != _mood.describe(name) ? ' $bubble.' : ''}',
          hint: 'Press Enter to open Mochi, Space to pet',
          excludeSemantics: true,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: stage,
                child: Tooltip(
                  // No room for a tooltip in the taskbar's little window (the spoken label says the same).
                  message: onTaskbar ? '' : _mood.describe(name),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.desktop.interact('pet'),
                    onDoubleTap: () => widget.onAction(ShellAction.showMain),
                    onSecondaryTapUp: (details) => _menu(details.globalPosition),
                    onPanStart: (_) => widget.onDragStart(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(onTaskbar ? 8 : 24),
                          border: _focused ? Border.all(color: p.focus, width: 2) : null,
                        ),
                        child: MochiView(
                          sessions: widget.desktop.sessions,
                          cues: widget.desktop.cues,
                          library: widget.library,
                          lastActivity: widget.lastActivity,
                          onMood: (mood) {
                            setState(() => _mood = mood);
                            widget.stroll.mood = mood;
                          },
                          fill: onTaskbar ? SurfaceSizes.taskbarFill : SurfaceSizes.standingFill,
                          // In the taskbar Mochi walks, turns and naps by the stroll, drawn as in the Mac's menu bar.
                          feet: onTaskbar ? SurfaceSizes.taskbarFeet : SurfaceSizes.standingFeet,
                          stroll: onTaskbar ? widget.stroll.sample : null,
                          detail: onTaskbar ? RenderDetail.tiny : RenderDetail.standard,
                          color: widget.desktop.settings.petColor,
                          accessory: widget.desktop.settings.wornByPet(widget.desktop.sessions.now),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (bubble != null)
                Positioned(
                  left: 4,
                  right: 4,
                  bottom: stage,
                  height: SurfaceSizes.bubble,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: _Bubble(text: bubble, urgent: needsYou),
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
