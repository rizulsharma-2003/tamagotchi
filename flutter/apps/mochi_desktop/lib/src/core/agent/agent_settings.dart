// Mochi's agent, the settings: the Mac's AgentSettings (Sources/TamagotchiCore/Agent/MochiAgent.swift) with its defaults
// (off; every source watched; every 15 minutes; quiet 23:00-08:00; briefing at 09:00) and its tolerant decoding. A
// source also has to be connected in the user's Claude account.

import 'package:mochi_link/mochi_link.dart' show AgentSource;

import '../notifications.dart' show QuietHours;

/// What each source is called, and the only tools the agent may call on it (the Mac's AgentSource): reading, never
/// sending, editing or deleting.
extension AgentSourceInfo on AgentSource {
  String get title => switch (this) {
    AgentSource.gmail => 'Gmail',
    AgentSource.calendar => 'Google Calendar',
    AgentSource.notion => 'Notion',
  };

  /// The connector's name in Claude Code.
  String get connectorName => 'claude.ai $title';

  /// What the agent reads from it, in the words Settings shows.
  String get whatMochiSees => switch (this) {
    AgentSource.gmail => 'Sender, subject and first lines of new mail in your inbox',
    AgentSource.calendar => 'Title, time and place of your coming events',
    AgentSource.notion => 'Titles and due dates of open tasks assigned to you',
  };

  List<String> get readTools {
    final prefix = 'mcp__claude_ai_${title.replaceAll(' ', '_')}__';
    final names = switch (this) {
      AgentSource.gmail => const ['search_threads', 'get_thread', 'get_message', 'list_labels'],
      AgentSource.calendar => const ['list_events', 'get_event', 'search_events', 'list_calendars'],
      AgentSource.notion => const ['notion-search', 'notion-fetch', 'notion-get-self', 'notion-query-data-sources'],
    };
    return [for (final name in names) '$prefix$name'];
  }
}

class AgentSettings {
  const AgentSettings({
    this.enabled = false,
    this.watched = AgentSource.values,
    this.intervalMinutes = 15,
    this.quietHours = defaultQuietHours,
    this.briefingEnabled = true,
    this.briefingMinute = 9 * 60,
    this.tellInBubble = true,
    this.tellWithBadge = true,
    this.tellPhone = true,
    this.phoneSkipsLowPriority = true,
    this.cloudFireURL = '',
    this.vips = const [],
    this.markReadWhenDone = true,
  });

  /// Off until the user turns it on: nothing runs and no timer exists before that.
  final bool enabled;

  /// What Mochi watches; a source also has to be connected in the user's Claude account.
  final List<AgentSource> watched;
  final int intervalMinutes;

  /// No checks in this window (overnight by default).
  final QuietHours quietHours;
  final bool briefingEnabled;

  /// Minutes after midnight.
  final int briefingMinute;
  final bool tellInBubble;

  /// The dot on Mochi (the tray and the pet), as the Mac's badge on the menu bar.
  final bool tellWithBadge;
  final bool tellPhone;

  /// Newsletters and automated mail stay off the phones.
  final bool phoneSkipsLowPriority;

  /// Mochi Cloud's API trigger (W23b: kept in the model, not shown or used yet).
  final String cloudFireURL;

  /// People whose mail always rings through (names, addresses or "@domain"); with none, any mail that matters does.
  /// Everyone else waits for the morning and night summaries.
  final List<String> vips;

  /// Marking an email done also marks it read in Gmail (W23b: kept in the model, not shown or used yet).
  final bool markReadWhenDone;

  static const List<int> intervals = [5, 10, 15, 30, 60];
  static const QuietHours defaultQuietHours = QuietHours(enabled: true, startMinute: 23 * 60, endMinute: 8 * 60);

  bool watches(AgentSource source) => watched.contains(source);

  /// [source] watched or not, keeping the usual order (Gmail, Calendar, Notion).
  AgentSettings watching(AgentSource source, bool on) => copyWith(
    watched: [
      for (final each in AgentSource.values)
        if (each == source ? on : watched.contains(each)) each,
    ],
  );

  AgentSettings copyWith({
    bool? enabled,
    List<AgentSource>? watched,
    int? intervalMinutes,
    QuietHours? quietHours,
    bool? briefingEnabled,
    int? briefingMinute,
    bool? tellInBubble,
    bool? tellWithBadge,
    bool? tellPhone,
    bool? phoneSkipsLowPriority,
    String? cloudFireURL,
    List<String>? vips,
    bool? markReadWhenDone,
  }) => AgentSettings(
    enabled: enabled ?? this.enabled,
    watched: watched ?? this.watched,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    quietHours: quietHours ?? this.quietHours,
    briefingEnabled: briefingEnabled ?? this.briefingEnabled,
    briefingMinute: briefingMinute ?? this.briefingMinute,
    tellInBubble: tellInBubble ?? this.tellInBubble,
    tellWithBadge: tellWithBadge ?? this.tellWithBadge,
    tellPhone: tellPhone ?? this.tellPhone,
    phoneSkipsLowPriority: phoneSkipsLowPriority ?? this.phoneSkipsLowPriority,
    cloudFireURL: cloudFireURL ?? this.cloudFireURL,
    vips: vips ?? this.vips,
    markReadWhenDone: markReadWhenDone ?? this.markReadWhenDone,
  );

  /// Tolerant, like the Mac's decoder: a missing or wrong-typed value keeps its default; the interval is at least 5
  /// minutes and the briefing time wraps into the day; unknown sources and empty VIPs are dropped.
  factory AgentSettings.fromJson(Object? json) {
    const defaults = AgentSettings();
    if (json is! Map) return defaults;
    bool flag(String key, bool fallback) => json[key] is bool ? json[key] as bool : fallback;
    var watched = defaults.watched;
    final names = json['watched'];
    if (names is List && names.every((name) => name is String)) {
      watched = [
        for (final name in names)
          if (AgentSource.tryParse(name) case final source?) source,
      ];
    }
    final interval = json['intervalMinutes'];
    final briefing = json['briefingMinute'];
    final vips = json['vips'];
    return AgentSettings(
      enabled: flag('enabled', defaults.enabled),
      watched: watched,
      intervalMinutes: interval is int ? (interval < 5 ? 5 : interval) : defaults.intervalMinutes,
      quietHours: _quietHours(json['quietHours']),
      briefingEnabled: flag('briefingEnabled', defaults.briefingEnabled),
      briefingMinute: briefing is int ? ((briefing % 1440) + 1440) % 1440 : defaults.briefingMinute,
      tellInBubble: flag('tellInBubble', defaults.tellInBubble),
      tellWithBadge: flag('tellWithBadge', defaults.tellWithBadge),
      tellPhone: flag('tellPhone', defaults.tellPhone),
      phoneSkipsLowPriority: flag('phoneSkipsLowPriority', defaults.phoneSkipsLowPriority),
      cloudFireURL: json['cloudFireURL'] is String ? json['cloudFireURL'] as String : defaults.cloudFireURL,
      vips: vips is List && vips.every((vip) => vip is String)
          ? [
              for (final vip in vips)
                if ((vip as String).trim().isNotEmpty) vip.trim(),
            ]
          : defaults.vips,
      markReadWhenDone: flag('markReadWhenDone', defaults.markReadWhenDone),
    );
  }

  /// The Mac's decoder takes the quiet hours whole or not at all.
  static QuietHours _quietHours(Object? json) {
    if (json is Map && json['enabled'] is bool && json['startMinute'] is int && json['endMinute'] is int) return QuietHours.fromJson(json);
    return defaultQuietHours;
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'watched': [for (final source in watched) source.name],
    'intervalMinutes': intervalMinutes,
    'quietHours': quietHours.toJson(),
    'briefingEnabled': briefingEnabled,
    'briefingMinute': briefingMinute,
    'tellInBubble': tellInBubble,
    'tellWithBadge': tellWithBadge,
    'tellPhone': tellPhone,
    'phoneSkipsLowPriority': phoneSkipsLowPriority,
    'cloudFireURL': cloudFireURL,
    'vips': vips,
    'markReadWhenDone': markReadWhenDone,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentSettings &&
      other.enabled == enabled &&
      _same(other.watched, watched) &&
      other.intervalMinutes == intervalMinutes &&
      other.quietHours == quietHours &&
      other.briefingEnabled == briefingEnabled &&
      other.briefingMinute == briefingMinute &&
      other.tellInBubble == tellInBubble &&
      other.tellWithBadge == tellWithBadge &&
      other.tellPhone == tellPhone &&
      other.phoneSkipsLowPriority == phoneSkipsLowPriority &&
      other.cloudFireURL == cloudFireURL &&
      _same(other.vips, vips) &&
      other.markReadWhenDone == markReadWhenDone;

  @override
  int get hashCode => Object.hash(
    enabled,
    Object.hashAll(watched),
    intervalMinutes,
    quietHours,
    briefingEnabled,
    briefingMinute,
    tellInBubble,
    tellWithBadge,
    tellPhone,
    phoneSkipsLowPriority,
    cloudFireURL,
    Object.hashAll(vips),
    markReadWhenDone,
  );

  static bool _same<T>(List<T> a, List<T> b) => a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}
