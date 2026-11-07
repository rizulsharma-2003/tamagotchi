// Sprint 2 G2: which real Claude events earn a celebration, decided exactly as the Mac's CompanionWorld does
// (SessionRegistry + EventToAnimationMapper), for hosts that want the answer without running the whole world: a
// toast, a full-screen confetti burst, a sticky note, the taskbar pet.

import '../events/events.dart';
import '../events/sessions.dart';
import '../interactions/interaction_library.dart';
import 'reactions.dart';
import 'settings.dart';

/// Why an event celebrates.
enum CelebrationReason {
  /// Claude finished a turn: a high five.
  turnFinished,

  /// Claude finished a turn that took at least the long-turn threshold, with both its start and its end seen live:
  /// a victory dance.
  longTurn,

  /// A real build or test passed this turn (an explicit report, or a recognised build/test command with a trustworthy
  /// exit status): the tiny trophy.
  buildTestPassed,

  /// Several tool errors in a row (three): Patch puts on the detective hat.
  investigating,

  /// A turn finished after detective mode: case closed.
  caseClosed,

  /// The first milestone ever: graduation.
  firstMilestone,

  /// A later milestone: a victory dance, or now and then a synchronized dance.
  milestone,

  /// A commit was recorded: a high five.
  commit,
}

/// A celebration a real event earned.
class Celebration {
  const Celebration({required this.reason, required this.interaction, required this.reaction, this.sessionID, required this.event});

  final CelebrationReason reason;

  /// The scripted moment Mochi and Patch play for it.
  final InteractionID interaction;

  /// Everything the Mac would do about the event (pet and Patch animations, sound, caption, banner text).
  final Reaction reaction;
  final String? sessionID;
  final CompanionEvent event;
}

/// Classifies Claude's hook events into celebrations (G2). Feed it every event, in order (it keeps its own session
/// state, so it knows a turn's start, its tool errors and its build/test results); it answers only for live, real
/// events: never for simulated, late (spooled) or restored ones.
///
/// The world itself ([MochiWorld]) applies the same rules internally and, like the Mac, still animates simulated
/// activity (the simulator, a phone mirroring the computer); this classifier is the strict "really happened, just now"
/// view.
class Celebrations {
  Celebrations({this.settings = const WorldSettings(), this.milestoneReached = false});

  WorldSettings settings;

  /// A milestone was reached before (the first one graduates). Hosts set it from the saved progress
  /// (`progress.unlockedIDs.contains(AchievementID.firstMilestone)`); it turns on with the first real milestone.
  bool milestoneReached;

  final SessionRegistry registry = SessionRegistry();

  Celebration? observe(CompanionEvent event) {
    final previousPrimary = registry.primarySession(pinned: settings.pinnedSessionID, now: event.receivedAt)?.id;
    final transition = registry.apply(event);
    final session = transition == null ? null : registry[transition.sessionID];
    if (event.isSimulated || event.delivery != EventDelivery.live) return null;
    final firstMilestone = event.kind == EventKind.report && event.report?.kind == ReportKind.milestone && !milestoneReached;
    if (firstMilestone) milestoneReached = true;
    final primaryID = registry.primarySession(pinned: settings.pinnedSessionID, now: event.receivedAt)?.id;
    final reaction = EventToAnimationMapper.reaction(
      event,
      transition: transition,
      session: session,
      context: MapperContext(
        companionPresent: true,
        isPrimary: session == null || session.id == primaryID || previousPrimary == null,
        multipleLiveSessions: registry.sessions.values.where((s) => s.phase != SessionPhase.ended).length > 1,
        celebrateCommandResults: settings.celebrateCommandResults,
        longTurnThreshold: (settings.longTurnMinutes * 60).toDouble(),
        firstMilestone: firstMilestone,
      ),
    );
    final interaction = reaction?.interaction;
    if (reaction == null || interaction == null) return null;
    final reason = switch (interaction) {
      InteractionID.caseClosed => CelebrationReason.caseClosed,
      InteractionID.detectiveHat => CelebrationReason.investigating,
      InteractionID.graduation => CelebrationReason.firstMilestone,
      InteractionID.trophyCelebration => CelebrationReason.buildTestPassed,
      InteractionID.syncDance => CelebrationReason.milestone,
      InteractionID.victoryDance => event.kind == EventKind.report ? CelebrationReason.milestone : CelebrationReason.longTurn,
      InteractionID.highFive => event.kind == EventKind.report ? CelebrationReason.commit : CelebrationReason.turnFinished,
      _ => null,
    };
    if (reason == null) return null;
    return Celebration(reason: reason, interaction: interaction, reaction: reaction, sessionID: session?.id, event: event);
  }
}
