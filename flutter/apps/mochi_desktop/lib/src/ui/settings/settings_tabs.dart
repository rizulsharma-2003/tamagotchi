// The Settings window's panes: the Mac's SettingsTab (Sources/App/Windows/SettingsView.swift), in the same order and
// groups, with each pane's colour, icon, header line and the words search finds it by.

import 'package:flutter/material.dart';

enum SettingsTab {
  general,
  characters,
  claude,
  assistant,
  phones,
  agent,
  notifications,
  desktop,
  fun,

  /// Windows only, beyond the Mac: the extras out on the desktop (docs/SPRINT_2.md, "crazier than the Mac").
  mischief,
  privacy,
  developer,
  about;

  /// The sidebar's groups, as on the Mac.
  static const List<({String name, List<SettingsTab> tabs})> groups = [
    (name: 'Your pet', tabs: [general, characters, desktop, fun, mischief]),
    (name: 'Claude', tabs: [claude, assistant, agent]),
    (name: 'Phones & alerts', tabs: [phones, notifications]),
    (name: 'App', tabs: [privacy, developer, about]),
  ];

  /// Every pane in the sidebar's order.
  static List<SettingsTab> get ordered => [for (final group in groups) ...group.tabs];

  String get title => switch (this) {
    general => 'General',
    characters => 'Characters',
    claude => 'Claude Code',
    assistant => 'Assistant',
    phones => 'Phones',
    agent => 'Agent',
    notifications => 'Notifications',
    desktop => 'Desktop Pet',
    fun => 'Fun',
    mischief => 'Mischief',
    privacy => 'Privacy',
    developer => 'Developer',
    about => 'About',
  };

  IconData get icon => switch (this) {
    general => Icons.settings_rounded,
    characters => Icons.pets_rounded,
    claude => Icons.code_rounded,
    assistant => Icons.auto_fix_high_rounded,
    phones => Icons.smartphone_rounded,
    agent => Icons.inbox_rounded,
    notifications => Icons.notifications_active_rounded,
    desktop => Icons.desktop_windows_rounded,
    fun => Icons.auto_awesome_rounded,
    mischief => Icons.bolt_rounded,
    privacy => Icons.back_hand_rounded,
    developer => Icons.construction_rounded,
    about => Icons.info_rounded,
  };

  /// The icon tile's colour: one hue per pane (the Mac's system colours), warm for your pet, cool for devices and
  /// privacy, Claude's terracotta for Claude Code.
  Color get tint => Color(switch (this) {
    general => 0xFF8E8E93,
    characters => 0xFFFF9500,
    desktop => 0xFF30B0C7,
    fun => 0xFFFF2D55,
    mischief => 0xFFBF5AF2,
    claude => 0xFFD97757,
    assistant => 0xFFAF52DE,
    agent => 0xFF34C759,
    phones => 0xFF5856D6,
    notifications => 0xFFFF3B30,
    privacy => 0xFF007AFF,
    developer => 0xFF636366,
    about => 0xFFFF9F6E,
  });

  /// The backdrop's two soft glows behind the cards: the pane's colour and a neighbour.
  (Color, Color) get glow => switch (this) {
    general => (const Color(0xFF7D8FB3), const Color(0xFFFFB38A)),
    characters => (const Color(0xFFFF9500), const Color(0xFFFF6482)),
    desktop => (const Color(0xFF30B0C7), const Color(0xFF5AC8FA)),
    fun => (const Color(0xFFFF2D55), const Color(0xFFBF5AF2)),
    mischief => (const Color(0xFFBF5AF2), const Color(0xFFFF9F0A)),
    claude => (const Color(0xFFD97757), const Color(0xFFF2C48D)),
    assistant => (const Color(0xFFAF52DE), const Color(0xFF5E5CE6)),
    agent => (const Color(0xFF34C759), const Color(0xFF30B0C7)),
    phones => (const Color(0xFF5856D6), const Color(0xFF0A84FF)),
    notifications => (const Color(0xFFFF3B30), const Color(0xFFFF9F0A)),
    privacy => (const Color(0xFF007AFF), const Color(0xFF64D2FF)),
    developer => (const Color(0xFF636366), const Color(0xFF30B0C7)),
    about => (const Color(0xFFFF9F6E), const Color(0xFFBF5AF2)),
  };

  /// The pane's header line. [phoneNames] names the paired phones ("Rizul's iPhone and Pixel 8"), or "your phones".
  String blurb({String pet = 'Mochi', String companion = 'Patch', String phoneNames = 'your phones'}) => switch (this) {
    general => 'Names, starting with Windows, the window’s theme, how $pet reacts and quiet hours.',
    characters => 'Looks for $pet and $companion: the coat, what they wear, the desk and the room, when $companion is around, and your friendship.',
    claude => 'Connect Claude Code so $pet follows your sessions and reacts to what they do.',
    assistant => 'Ask $pet questions and quick commands, here on this PC or from your phones.',
    phones => 'Mochi on $phoneNames: pairing, Claude’s summaries and talking to $pet from a phone.',
    agent => '$pet keeps an eye on Gmail, Google Calendar and Notion and tells you what matters.',
    notifications => 'Which of Claude’s moments $pet reacts to, which get a Windows notification, and how they sound.',
    desktop => 'Let $pet sit on your desktop or stroll along the taskbar, with $companion at his desk.',
    fun => 'Talking, growing up, holidays, games, adventures and little surprises.',
    mischief => 'Extras only Windows has: $pet out on your desktop, by your pointer, on every screen, with notes and confetti.',
    privacy => 'What leaves this PC, what Mochi keeps here, and where.',
    developer => 'Diagnostics: the hook bridge, the spool, logs and Mochi Link.',
    about => 'Version, links, licences and how to uninstall.',
  };

  /// More words search finds the pane by.
  String get keywords => switch (this) {
    general => 'name names pet companion startup start with windows sign in login boot theme light dark appearance '
        'reactions pause quiet mode quiet hours do not disturb reset',
    characters => 'pet companion colour color coat accessory accessories hat glasses wear desk theme office room look '
        'mochi patch costume show linger stays naps sleep rest idle away pc rhythm visibility always never sessions '
        'friendship hearts achievements progress level points unlock reset',
    claude => 'hooks connect sessions integration claude code helper bridge settings.json backup troubleshoot',
    assistant => 'ask mochi voice talk shortcut hotkey keyboard ctrl alt space quick commands model haiku sonnet brain '
        'approvals drop file link screen screenshot window show my screen',
    phones => 'phones phone iphone android mochi pocket pair pairing link relay unpair test devices summaries talking '
        'away only when live activity',
    agent => 'gmail calendar notion mail meetings tasks briefing vip done cloud watcher mochi cloud copy settings environment',
    notifications => 'alerts notifications toast toasts banner badge sounds sound volume keyboard taps quiet reactions '
        'celebrate finished needs you snag errors build test categories animate',
    desktop => 'desktop pet taskbar roam stroll walk window position show hide shortcut hotkey keyboard patch companion '
        'desk style spot tray icon classic size small medium large always on top click through clicks display monitor '
        'moments',
    fun => 'games adventure seasons seasonal holidays halloween diwali christmas new year valentine birthday treats '
        'focus recap room furniture talking speech bubbles chattiness chatty quiet fresh lines haiku growing grows up kitten '
        'touch purr hold pomodoro timer break catch treats rock paper scissors decorate '
        'young grown-up life stages',
    mischief => 'mischief extras crazy windows only cursor pointer mouse buddy chase follow pounce screens displays monitors '
        'multi monitor multiple roam roaming sticky notes note celebrations confetti fireworks full screen streak',
    privacy => 'privacy data history relay encryption summaries share keep folder clear',
    developer => 'debug diagnostics logs bridge port spool relay device id room simulator',
    about => 'version credits licence license licenses uninstall nunito open source links',
  };

  /// Whether the pane matches a search: every word of [query] is in its title, keywords or header line.
  bool matches(String query) {
    final words = query.trim().toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    if (words.isEmpty) return true;
    final haystack = '$title $keywords ${blurb()}'.toLowerCase();
    return words.every(haystack.contains);
  }
}

/// Which pane is open and what the sidebar's search says. Kept by the app, so Settings opens where you left it (or
/// where a link asked for: the pet card opens Characters, "More in Settings" Claude Code).
class SettingsNavigation extends ChangeNotifier {
  SettingsNavigation([SettingsTab tab = SettingsTab.general]) : _tab = tab;

  SettingsTab _tab;
  String _query = '';

  SettingsTab get tab => _tab;
  set tab(SettingsTab value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }

  String get query => _query;
  set query(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  /// The sidebar's groups with only the panes that match the search (empty groups left out).
  List<({String name, List<SettingsTab> tabs})> get visibleGroups => [
    for (final group in SettingsTab.groups)
      if (group.tabs.where((tab) => tab.matches(_query)).toList() case final tabs when tabs.isNotEmpty) (name: group.name, tabs: tabs),
  ];

  /// The panes the sidebar shows, in order.
  List<SettingsTab> get visibleTabs => [for (final group in visibleGroups) ...group.tabs];
}
