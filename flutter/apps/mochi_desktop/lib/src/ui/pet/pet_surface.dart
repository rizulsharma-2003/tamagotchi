import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart' show RenderDetail;
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/desktop_settings.dart' show DesktopStyle;
import '../../core/desktop_world.dart' show DesktopWorld;
import '../../core/hotkeys.dart' show MochiShortcut;
import '../../core/notifications.dart' show NotificationCategory;
import '../../core/pet_cues.dart';
import '../../core/sessions.dart' show Attention;
import '../../desktop.dart';
import '../../platform/taskbar.dart' show HomeStage;
import '../../update/updater.dart';
import '../shell.dart';
import 'companion_director.dart';
import 'mochi_view.dart';
import 'pet_director.dart';
import 'purr_hold.dart';
import 'speech_bubble.dart';
import 'taskbar_stroll.dart';

/// The desktop pet: Mochi on a transparent, always-on-top window, with a speech bubble when Claude needs you or
/// finishes, and for what Mochi and Patch say now and then (W11) and the world's notes (an achievement, growing up). On Windows it strolls inside the taskbar ([stroll]), at the taskbar's size. Click to pet, double-click (or
/// Enter) to open Mochi, drag to move (off the taskbar: it stays where it's dropped), right-click (or Shift+F10) for
/// the menu.
///
/// Mochi has a fixed box at the bottom of the window and the bubble goes above it, so the window can grow upwards for
/// the bubble (on the taskbar) without Mochi moving.
///
/// With Patch on the taskbar ([TaskbarStroll.duo]) the box is his and Mochi's stage: his desk on the right, Mochi
/// beside it. Clicking Patch gets a wave back; the bubble rises over Mochi's place beside him, and when Claude is
/// asking for your permission it's Patch asking (by the name you gave him), as on the Mac.
class PetSurface extends StatefulWidget {
  const PetSurface({
    super.key,
    required this.desktop,
    required this.stroll,
    required this.lastActivity,
    required this.onAction,
    required this.onDragStart,
    required this.onHide,
    this.onNativeMenu,
    this.onOpenPopover,
    this.companion,
  });

  final MochiDesktop desktop;
  final TaskbarStroll stroll;
  final DateTime Function() lastActivity;
  final ValueChanged<ShellAction> onAction;

  /// A drag began (the app moves the window with the mouse until it's dropped).
  final VoidCallback onDragStart;
  final VoidCallback onHide;

  /// The tray's menu at the pointer: Mochi's window in the taskbar is too small for its own menu.
  final VoidCallback? onNativeMenu;

  /// Patch (drawn beside Mochi while he's on the taskbar).
  final CompanionDirector? companion;

  /// Clicking Mochi (or Patch) on the taskbar opens the popover, as clicking Mochi in the Mac's menu bar does.
  final VoidCallback? onOpenPopover;

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

  StreamSubscription<Object?>? _celebrations;

  @override
  void initState() {
    super.initState();
    _cues = widget.desktop.cues.listen(_cue);
    widget.desktop.world.speechNow.addListener(_worldSays);
    widget.desktop.world.toastNow.addListener(_worldSays);
    // Celebrations from Claude's real moments (G2), said for the screen reader as they play.
    _celebrations = widget.desktop.world.celebrated.listen((celebration) {
      final settings = widget.desktop.settings;
      SemanticsService.announce(
        DesktopWorld.describeCelebration(celebration, pet: settings.petName, patch: settings.companionName),
        TextDirection.ltr,
      );
    });
    widget.desktop.hotkeys.addListener(_shortcutsChanged);
    _shortcutsChanged();
  }

  /// The problems Mochi already mentioned.
  final Set<String> _saidProblems = {};

  /// A shortcut another app already has: Mochi says so, once (the Mac's "My shortcut … is taken").
  void _shortcutsChanged() {
    final hotkeys = widget.desktop.hotkeys;
    for (final shortcut in MochiShortcut.values) {
      final problem = hotkeys.problem(shortcut);
      final hotkey = widget.desktop.settings.shortcut(shortcut);
      if (problem == null || hotkey == null || !_saidProblems.add('${shortcut.name}:${hotkey.label}')) continue;
      final pane = shortcut == MochiShortcut.ask ? 'Assistant' : 'Desktop Pet';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _say('My shortcut ${hotkey.label} is taken: pick another in Settings › $pane', const Duration(seconds: 8));
      });
    }
  }

  void _cue(PetCue cue) {
    final project = widget.desktop.sessions.primary?.project;
    switch (cue) {
      case PetCue.finished:
        _say(project == null ? 'Claude finished!' : 'Claude finished in $project!', const Duration(seconds: 8));
      case PetCue.snag:
        _say('Claude hit a snag', const Duration(seconds: 8));
      case PetCue.updateReady:
        _say('A new Mochi is ready: restart to update', const Duration(seconds: 12));
      case PetCue.updated:
        final version = widget.desktop.updater.updatedTo;
        _say(version == null ? 'Mochi is up to date!' : 'Mochi updated to $version!', const Duration(seconds: 8));
      case PetCue.greet || PetCue.goodbye || PetCue.cheer || PetCue.worry || PetCue.celebrate || PetCue.puzzled:
        // The Mac's caption for the moment ("session started", "web · a test command failed").
        final caption = widget.desktop.reactions.caption;
        if (caption != null && caption.isNotEmpty) _say(sentence(caption), const Duration(seconds: 6));
      default:
        break;
    }
  }

  /// Mochi or Patch started or stopped talking, or a note came or went.
  void _worldSays() {
    if (mounted) setState(() {});
  }

  /// The world's note (its title), or what Mochi or Patch is saying (by Patch's name when he isn't beside Mochi), and
  /// who's speaking.
  ({String text, bool patch})? _worldLine({required bool patchShown}) {
    final world = widget.desktop.world;
    final note = world.toastNow.value;
    if (note != null) return (text: note.title, patch: false);
    final speech = world.speechNow.value;
    if (speech == null) return null;
    final patch = speech.speaker.name == 'companion';
    if (patch && !patchShown) return (text: '${widget.desktop.settings.companionName}: ${speech.text}', patch: false);
    return (text: speech.text, patch: patch);
  }

  /// "session started" → "Session started" (a caption led by a project's name keeps it as it is).
  static String sentence(String caption) => caption.contains(' · ') ? caption : '${caption[0].toUpperCase()}${caption.substring(1)}';

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
    unawaited(_celebrations?.cancel());
    widget.desktop.world.speechNow.removeListener(_worldSays);
    widget.desktop.world.toastNow.removeListener(_worldSays);
    widget.desktop.hotkeys.removeListener(_shortcutsChanged);
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
        if (widget.desktop.updater.phase == UpdatePhase.ready) ...[
          const PopupMenuItem(value: ShellAction.restartToUpdate, child: Text('Restart to Update')),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(value: ShellAction.showMain, child: Text('Show Mochi')),
        const PopupMenuItem(value: ShellAction.pair, child: Text('Pair a Phone…')),
        const PopupMenuItem(value: ShellAction.settings, child: Text('Settings')),
        const PopupMenuDivider(),
        PopupMenuItem(value: ShellAction.focus, child: Text(widget.desktop.focus.menuTitle)),
        const PopupMenuItem(value: ShellAction.games, child: Text('Games…')),
        const PopupMenuItem(value: ShellAction.recap, child: Text('Today’s Recap…')),
        const PopupMenuDivider(),
        // Where Mochi lives (the tray menu has the same), and the desktop pet's own (the Mac's "Always on Top").
        for (final (action, style) in const [
          (ShellAction.roamTaskbar, DesktopStyle.roam),
          (ShellAction.playInSpot, DesktopStyle.spot),
          (ShellAction.trayIcon, DesktopStyle.icon),
        ])
          CheckedPopupMenuItem(value: action, checked: widget.desktop.settings.petStyle == style, child: Text(style.title)),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'top', checked: widget.desktop.settings.petOnTop, child: const Text('Always on top')),
        const PopupMenuItem(value: 'hide', child: Text('Hide the desktop pet')),
        const PopupMenuItem(value: ShellAction.quit, child: Text('Quit Mochi')),
      ],
    );
    if (action is ShellAction) widget.onAction(action);
    if (action == 'hide') widget.onHide();
    if (action == 'top') widget.desktop.settings.petOnTop = !widget.desktop.settings.petOnTop;
  }

  /// What the bubble says while Claude needs you: Claude's question, or Patch asking for your OK when it's a
  /// permission and he's on the taskbar with Mochi (on the Mac, permission prompts are his line).
  String _needsYou({required bool patch}) {
    final primary = widget.desktop.sessions.primary;
    final project = primary?.project;
    final where = project == null ? '' : ' in $project';
    if (patch && primary?.waitingFor == Attention.permission) return '${widget.desktop.settings.companionName} needs your OK$where';
    return 'Claude needs you$where';
  }

  /// A click on Mochi (or Patch) in the taskbar opens the popover, as on the Mac; off the taskbar a click pets Mochi.
  void _tap() {
    widget.stroll.log?.call('pet: tap');
    final popover = widget.onOpenPopover;
    if (widget.stroll.onTaskbar && popover != null) return popover();
    widget.desktop.interact('pet');
  }

  /// Enter: the popover from the taskbar, Mochi's window from the desktop.
  void _activate() {
    widget.stroll.log?.call('pet: activate (keyboard)');
    final popover = widget.onOpenPopover;
    if (widget.stroll.onTaskbar && popover != null) return popover();
    widget.onAction(ShellAction.showMain);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.desktop.settings;
    // The bubble that stays up while Claude needs you is that moment's animation (Settings › Notifications).
    final needsYou =
        _mood == PetMood.needsYou && !settings.pauseReactions && settings.delivery(NotificationCategory.needsAttention).animate;
    final duo = widget.stroll.onTaskbar ? widget.stroll.duo : null;
    final companion = widget.companion;
    final world = needsYou || _bubble != null ? null : _worldLine(patchShown: duo != null && (companion?.visible ?? false));
    final bubble = needsYou ? _needsYou(patch: duo != null) : _bubble ?? world?.text;
    // Patch's own lines rise over his desk.
    final overPatch = world?.patch ?? false;
    if ((bubble != null) != _bubbleShown) {
      _bubbleShown = bubble != null;
      // The taskbar window makes room for it (after this frame: never during a build).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.stroll.bubble = _bubbleShown;
      });
    }
    final onTaskbar = widget.stroll.onTaskbar;
    final name = settings.petName;
    final now = widget.desktop.sessions.now;
    // With Patch beside Mochi, the spoken label says what he's up to too.
    final patchText = duo != null && companion != null ? ' ${companion.describe(settings.companionName)}.' : '';
    // Mochi's box at the bottom of the window: taskbar-sized in the taskbar (the Mac's menu-bar Mochi), the bubble above.
    final stage = onTaskbar ? widget.stroll.box.height : settings.petSize.stage;
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
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate()),
          _PetIntent: CallbackAction<_PetIntent>(onInvoke: (_) => widget.desktop.interact('pet')),
          _MenuIntent: CallbackAction<_MenuIntent>(onInvoke: (_) => _menu(const Offset(40, 60))),
        },
        child: Semantics(
          container: true,
          button: true,
          label: '$name. ${_mood.describe(name)}.$patchText${bubble != null && bubble != _mood.describe(name) ? ' $bubble.' : ''}',
          hint: onTaskbar && widget.onOpenPopover != null
              ? 'Press Enter for the popover, Space to pet'
              : 'Press Enter to open Mochi, Space to pet',
          customSemanticsActions: {CustomSemanticsAction(label: 'Purr'): widget.desktop.purr.pulse},
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
                  child: PurrHold(
                    purr: widget.desktop.purr,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _tap,
                      // On the taskbar a click opens the popover at once (no wait for a second click); standing on the
                      // desktop, a double-click opens Mochi's window.
                      onDoubleTap: onTaskbar ? null : () => widget.onAction(ShellAction.showMain),
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
                            world: widget.desktop.world,
                            sessions: widget.desktop.sessions,
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
                            color: settings.petColor,
                            accessory: settings.wornByPet(now),
                            companion: companion,
                            duo: duo == null ? null : () => widget.stroll.duo,
                            theme: settings.officeTheme,
                            companionAccessory: settings.wornByCompanion(now),
                            deskAccessory: settings.deskAccessory,
                            burst: onTaskbar,
                            rhythm: widget.desktop.rhythm,
                            badge: widget.desktop.reactions.badge?.level,
                            purr: widget.desktop.purr,
                          ),
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Over Mochi's place beside Patch (kept inside the window), or centred over Mochi alone.
                      final width = constraints.maxWidth;
                      final span = math.min(MochiBubble.maxWidth, width);
                      final anchor = duo == null
                          ? width / 2
                          : overPatch
                          ? duo.local(duo.home.deskX + HomeStage.bodyX * duo.home.unit) - 4
                          : duo.local(duo.home.petHome) - 4;
                      final centre = duo == null ? anchor : anchor.clamp(span / 2, math.max(span / 2, width - span / 2));
                      return Stack(
                        children: [
                          Positioned(
                            left: centre - span / 2,
                            width: span,
                            top: 0,
                            bottom: 0,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: MochiBubble(text: bubble, urgent: needsYou),
                            ),
                          ),
                        ],
                      );
                    },
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
