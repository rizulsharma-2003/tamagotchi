// What a feature (focus, games, the recap, holidays, growing up) asks the world to show at one of its moments: the
// Mac's controllers in Sources/App/Features call `world.say`, `world.showToast`, `playPet`, `playCompanion`,
// `FeatureSound.play` and `postBanner` directly; here the same choices come back as a value the host applies.

import '../model/animations.dart';
import '../world/policy.dart';
import '../world/reactions.dart';
import '../world/settings.dart';
import '../world/world.dart';

/// A note at the top of the scene (the world's toast).
class FeatureToast {
  const FeatureToast(this.title, this.detail, {this.seconds = 6});
  final String title;
  final String detail;
  final double seconds;

  @override
  bool operator ==(Object other) => other is FeatureToast && other.title == title && other.detail == detail && other.seconds == seconds;

  @override
  int get hashCode => Object.hash(title, detail, seconds);

  @override
  String toString() => 'FeatureToast($title, $detail, ${seconds}s)';
}

/// A speech bubble line.
class FeatureLine {
  const FeatureLine(this.text, {this.speaker = SpeechSpeaker.pet, this.duration = 4.5});
  final String text;
  final SpeechSpeaker speaker;
  final double duration;

  @override
  bool operator ==(Object other) => other is FeatureLine && other.text == text && other.speaker == speaker && other.duration == duration;

  @override
  int get hashCode => Object.hash(text, speaker, duration);

  @override
  String toString() => 'FeatureLine(${speaker.name}: $text)';
}

/// What to show for one moment. Every part is optional; [applyTo] performs it the way the Mac's controllers do.
class FeatureMoment {
  const FeatureMoment({this.toast, this.line, this.pet, this.companion, this.sound, this.banner});

  final FeatureToast? toast;
  final FeatureLine? line;
  final PetAnimation? pet;
  final CompanionAnimation? companion;

  /// Played like the Mac's `FeatureSound`: only with sounds on and outside quiet mode or quiet hours.
  final SoundCue? sound;

  /// Only set when the user asked for this feature's banners; [applyTo] still holds it back while reactions are paused
  /// or in quiet mode or hours, as the Mac does. Sent as a milestone.
  final BannerContent? banner;

  bool get isEmpty => toast == null && line == null && pet == null && companion == null && sound == null && banner == null;

  /// Shows the moment in [world] (in the Mac's order: toast, speech, Mochi, Patch, sound, banner). Sounds and banners
  /// go through the world's `effects`.
  void applyTo(MochiWorld world) {
    if (toast case final t?) world.showToast(title: t.title, detail: t.detail, seconds: t.seconds);
    if (line case final l?) world.say(l.text, speaker: l.speaker, duration: l.duration);
    if (pet case final p?) world.playPet(p);
    if (companion case final c?) world.playCompanion(c);
    final settings = world.settings;
    final quiet = NotificationPolicy.isQuiet(settings, world.date, calendar: world.calendar);
    if (sound case final s? when settings.soundEnabled && !quiet) world.effects?.play(s);
    if (banner case final b? when !settings.pauseReactions && !quiet) {
      world.effects?.postBanner(b, NotificationCategory.milestone, null);
    }
  }

  @override
  String toString() {
    final parts = [
      ?toast,
      ?line,
      if (pet case final p?) 'pet: ${p.name}',
      if (companion case final c?) 'companion: ${c.name}',
      if (sound case final s?) 'sound: ${s.name}',
      if (banner case final b?) 'banner: ${b.title}',
    ];
    return 'FeatureMoment(${parts.join(', ')})';
  }
}
