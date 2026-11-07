// How Mochi answers each of Claude's moments on this PC: the Mac's CompanionWorld.perform and updateAttention. Each live
// event gets its reaction (ReactionMapper); Settings › Notifications decides, per category, whether Mochi animates,
// puts a badge on itself, shows a Windows notification (batched) and plays a sound, with pausing, quiet mode and quiet
// hours applied (NotificationPolicy). Late events from the spool only update the badge; the session registry never
// passes on simulated ones.

import 'package:flutter/foundation.dart';

import 'desktop_settings.dart';
import 'notifications.dart';
import 'pet_cues.dart';
import 'session_store.dart';
import 'sessions.dart';
import 'sounds.dart';
import 'toasts.dart';

class Reactions extends ChangeNotifier {
  Reactions({
    required this.settings,
    required this.sessions,
    required void Function(PetCue cue) cue,
    required this.toasts,
    required this.sounds,
    DateTime Function()? clock,
  }) : _cue = cue,
       _clock = clock ?? DateTime.now;

  final DesktopSettings settings;
  final SessionStore sessions;
  final ToastService toasts;
  final MochiSounds sounds;
  final void Function(PetCue cue) _cue;
  final DateTime Function() _clock;
  final BannerCoalescer _coalescer = BannerCoalescer();

  /// Mochi's window or popover is open: no badge or banner (you're looking already). Set by the app.
  bool Function() lookingAtMochi = () => false;

  AttentionBadge? _badge;

  /// The dot on Mochi while something waits for you.
  AttentionBadge? get badge => _badge;

  /// What Mochi says about the latest moment it animated ("web · turn complete"), for its bubble.
  String? caption;

  /// Windows notifications shown, and the last one (Settings › Developer, tests).
  int bannersPosted = 0;
  Toast? lastToast;

  /// Every applied event (live or late), with the primary session before it, from MochiDesktop.
  void handle(SessionTransition transition, {String? previousPrimary}) {
    _afterEvent(transition);
    if (transition.delivery != Delivery.live) return;
    final primary = sessions.primary?.id;
    final isPrimary = primary == null || transition.session.id == primary || previousPrimary == null;
    final reaction = ReactionMapper.reaction(transition, isPrimary: isPrimary, multipleLiveSessions: sessions.live.length > 1);
    if (reaction != null) perform(reaction, transition);
  }

  /// The Mac's `perform`: the reaction as far as Settings allows.
  @visibleForTesting
  void perform(Reaction reaction, SessionTransition transition) {
    final now = _clock();
    final decision = NotificationPolicy.decide(
      reaction.category,
      settings,
      NotificationContext(now: now, lookingAtMochi: lookingAtMochi(), isLate: transition.delivery != Delivery.live),
    );
    if (decision.animate && reaction.cue != null) {
      caption = reaction.caption;
      _cue(reaction.cue!);
    }
    if (decision.sound && reaction.sound != null) sounds.play(reaction.sound!);
    final level = reaction.attention;
    if (decision.badge && level != null) {
      final kind = ReactionMapper.badgeKind(transition);
      final current = _badge;
      if (current == null || level >= current.level || current.kind == kind) {
        _setBadge(
          AttentionBadge(
            kind: kind,
            level: level,
            sessionId: transition.session.id,
            summary: transition.event == null ? '' : RecentEvent.describe(transition.event!, transition.kind),
            at: now,
          ),
        );
      }
    }
    final banner = reaction.banner;
    if (decision.banner && banner != null) {
      final key = '${reaction.category.name}-${transition.session.id}';
      final held = _coalescer.register(key, now);
      if (held != null) {
        final toast = Toast(
          title: banner.title,
          body: held > 0 ? '${banner.body} (+$held similar)' : banner.body,
          target: ToastTarget.session(transition.session.id),
          group: key,
        );
        bannersPosted++;
        lastToast = toast;
        toasts.show(toast).ignore();
      }
    }
  }

  void _afterEvent(SessionTransition transition) {
    final next = ReactionMapper.afterEvent(_badge, transition, exists: (id) => sessions.registry[id] != null);
    if (!identical(next, _badge)) _setBadge(next);
  }

  /// You opened Mochi's window or popover: everything but "Claude needs you" has been seen (the Mac's
  /// `acknowledgeAttention`).
  void acknowledge() {
    if (_badge != null && _badge!.kind != AttentionKind.needsYou) _setBadge(null);
  }

  /// Sessions were pruned: a badge for one that's gone goes with it.
  void pruned() {
    final id = _badge?.sessionId;
    if (id != null && sessions.registry[id] == null) _setBadge(null);
  }

  /// Settings › Notifications › Test: the success chime at the chosen volume.
  bool testSound() => sounds.play(SoundCue.success, force: true);

  void _setBadge(AttentionBadge? badge) {
    _badge = badge;
    notifyListeners();
  }
}
