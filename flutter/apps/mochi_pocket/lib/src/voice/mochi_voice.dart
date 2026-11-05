import 'dart:math' as math;

/// Mochi's character on top of the phone's voice (iOS/MochiPocket/MochiVoice.swift `Character`): the same presets,
/// pitch in cents and pace.
enum VoiceCharacter {
  mochi('Mochi', "Bright and a little higher: Mochi's own voice.", 350, 1.04),
  tiny('Tiny', 'Small and squeaky, like a pet that fits in your pocket.', 700, 1.08),
  calm('Calm', 'A little lower and unhurried.', -150, 0.92),
  plain('Plain', "The phone's voice just as it is.", 0, 1);

  const VoiceCharacter(this.title, this.blurb, this.cents, this.pace);

  final String title;
  final String blurb;

  /// Pitch change in cents (100 is a semitone).
  final double cents;

  /// Speaking pace, relative to the voice's usual pace.
  final double pace;

  /// Android's pitch is a multiplier (1 is the voice's own): 2^(cents/1200). Mochi's +350 cents is about 1.22.
  double get pitch => math.pow(2, cents / 1200).toDouble();

  static VoiceCharacter parse(Object? name) => values.where((value) => value.name == name).firstOrNull ?? mochi;
}

/// One of the phone's text-to-speech voices (Android `Voice`, as flutter_tts reports it).
class VoiceInfo {
  const VoiceInfo({required this.name, required this.locale, this.quality = 300, this.network = false, this.installed = true});

  /// From flutter_tts's voice map: `name`, `locale` (a language tag), `quality` ("very high" … "very low"),
  /// `network_required` ("1"/"0") and `features` (tab-separated; Google's "notInstalled" means not downloaded yet).
  static VoiceInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'], locale = raw['locale'];
    if (name is! String || locale is! String) return null;
    final features = '${raw['features'] ?? ''}'.split('\t');
    return VoiceInfo(
      name: name,
      locale: locale,
      quality: switch ('${raw['quality'] ?? ''}') {
        'very high' => 500,
        'high' => 400,
        'normal' => 300,
        'low' => 200,
        'very low' => 100,
        _ => 300,
      },
      network: '${raw['network_required']}' == '1',
      installed: !features.contains('notInstalled'),
    );
  }

  final String name;

  /// A language tag: en-US, en-IN, …
  final String locale;

  /// 100 (very low) to 500 (very high).
  final int quality;

  /// Spoken on the engine's servers: what's read goes over the internet.
  final bool network;

  /// Downloaded and ready (Google's voices can be listed before they're downloaded).
  final bool installed;

  bool get english => locale.toLowerCase().startsWith('en');

  /// "English (India) · ENA · Very high quality · needs the internet".
  String get label {
    final parts = [_language(locale)];
    final short = _shortName(name);
    if (short != null) parts.add(short);
    if (quality >= 500) {
      parts.add('Very high quality');
    } else if (quality >= 400) {
      parts.add('High quality');
    }
    parts.add(network ? 'needs the internet' : 'on this phone');
    return parts.join(' · ');
  }

  Map<String, String> toMap() => {'name': name, 'locale': locale};

  @override
  bool operator ==(Object other) => other is VoiceInfo && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);

  static String _language(String tag) {
    final parts = tag.split(RegExp('[-_]'));
    const places = {
      'US': 'US',
      'GB': 'UK',
      'IN': 'India',
      'AU': 'Australia',
      'CA': 'Canada',
      'IE': 'Ireland',
      'NZ': 'New Zealand',
      'ZA': 'South Africa',
      'NG': 'Nigeria',
      'SG': 'Singapore',
    };
    final region = parts.length > 1 ? parts[1].toUpperCase() : null;
    return region == null ? 'English' : 'English (${places[region] ?? region})';
  }

  /// Google's voice names look like "en-in-x-ena-local": the "ena" part tells them apart.
  static String? _shortName(String name) {
    final match = RegExp(r'-x-([a-z]+)-(?:local|network)$').firstMatch(name);
    return match == null ? null : match[1]!.toUpperCase();
  }
}

/// Choosing among the phone's voices (MochiVoice.swift `automatic` and `choices`).
abstract final class VoiceChoice {
  /// English voices that are ready, best first: on this phone before needing the internet, higher quality first, the
  /// phone's own accent ([language], e.g. en-IN) before other English, then US English, then by name.
  static List<VoiceInfo> choices(List<VoiceInfo> voices, {required String language}) {
    int rank(VoiceInfo voice) {
      var score = voice.network ? 0 : 1000;
      score += voice.quality;
      if (_same(voice.locale, language)) {
        score += 20;
      } else if (_same(voice.locale, 'en-US')) {
        score += 10;
      }
      return score;
    }

    final list = voices.where((voice) => voice.english && voice.installed).toList()
      ..sort((a, b) => rank(a) != rank(b) ? rank(b).compareTo(rank(a)) : a.name.compareTo(b.name));
    return list;
  }

  /// The voice to read with: the chosen one while it's still there, else the best one.
  static VoiceInfo? pick(List<VoiceInfo> voices, {String? chosen, required String language}) {
    final list = choices(voices, language: language);
    return list.where((voice) => voice.name == chosen).firstOrNull ?? list.firstOrNull;
  }

  static bool _same(String a, String b) => a.toLowerCase().replaceAll('_', '-') == b.toLowerCase().replaceAll('_', '-');
}
