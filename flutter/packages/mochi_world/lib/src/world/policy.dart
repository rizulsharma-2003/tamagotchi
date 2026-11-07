// Port of Sources/TamagotchiCore/Notifications/NotificationPolicy.swift: how one reaction may reach the user, and the
// banner coalescer.

import 'settings.dart';

/// The resolved way a single reaction may reach the user.
class DeliveryDecision {
  const DeliveryDecision({required this.animate, required this.badge, required this.banner, required this.sound, required this.quiet});

  final bool animate;
  final bool badge;
  final bool banner;
  final bool sound;

  /// Quiet hours or quiet mode are softening this delivery.
  final bool quiet;

  static const none = DeliveryDecision(animate: false, badge: false, banner: false, sound: false, quiet: false);

  Map<String, Object?> toJson() => {'animate': animate, 'badge': badge, 'banner': banner, 'sound': sound, 'quiet': quiet};
}

class NotificationContext {
  const NotificationContext({
    required this.now,
    this.popoverVisible = false,
    this.reducedMotion = false,
    this.isSimulated = false,
    this.isLate = false,
    this.focusing = false,
  });

  final DateTime now;

  /// The user is looking at Mochi's window (the Mac's popover).
  final bool popoverVisible;
  final bool reducedMotion;
  final bool isSimulated;
  final bool isLate;

  /// A focus block is running: only sounds for things that need the user still play.
  final bool focusing;
}

abstract final class NotificationPolicy {
  static bool isQuiet(WorldSettings settings, DateTime at, {WorldCalendar calendar = const WorldCalendar.local()}) =>
      settings.quietMode || settings.quietHours.isActive(at, calendar: calendar);

  static DeliveryDecision decide(
    NotificationCategory category, {
    required WorldSettings settings,
    required NotificationContext context,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final preference = settings.delivery(category);
    final quiet = isQuiet(settings, context.now, calendar: calendar);

    // Late (spooled) events are history, not news: no reactions or alerts.
    if (context.isLate) return DeliveryDecision.none;

    var animate = preference.animate;
    var badge = preference.badge;
    var banner = preference.banner;
    var sound = preference.sound && settings.soundEnabled;
    if (category == NotificationCategory.toolActivity) {
      sound = preference.sound && settings.soundEnabled && settings.workSounds;
    }
    if (settings.pauseReactions) {
      animate = false;
      sound = false;
      banner = false;
    }
    if (quiet) {
      sound = false;
      banner = false;
    }
    if (context.focusing && category != NotificationCategory.needsAttention) sound = false;
    // The user is already looking at Mochi.
    if (context.popoverVisible) {
      banner = false;
      badge = false;
    }
    // Simulated activity never reaches the notification centre.
    if (context.isSimulated) banner = false;
    return DeliveryDecision(animate: animate, badge: badge, banner: banner, sound: sound, quiet: quiet);
  }
}

/// Batches repetitive banners: within the window only the first banner per key is shown and later ones are counted,
/// then summarized in the next banner.
class BannerCoalescer {
  BannerCoalescer({this.window = 45});

  final double window;
  final Map<String, DateTime> _lastShown = {};
  final Map<String, int> _suppressed = {};

  /// The number of similar banners suppressed since the last one shown, or null to suppress this one.
  int? register(String key, DateTime now) {
    final last = _lastShown[key];
    if (last != null && now.difference(last).inMicroseconds / 1e6 < window) {
      _suppressed[key] = (_suppressed[key] ?? 0) + 1;
      return null;
    }
    _lastShown[key] = now;
    final count = _suppressed[key] ?? 0;
    _suppressed[key] = 0;
    return count;
  }
}
