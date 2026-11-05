// Short, unambiguous commands Mochi answers on the spot without asking Claude: the Dart port of TamagotchiCore's
// Assistant/QuickCommands.swift (the same phrases, so "status" or "pet" from a phone means the same on a Mac and on a
// Windows PC). Precision over recall: anything it's unsure about goes to Claude.

/// Something Mochi can do on the spot.
sealed class QuickCommand {
  const QuickCommand();
}

/// Play/pause, next, previous.
class MediaCommand extends QuickCommand {
  const MediaCommand(this.key);

  /// playPause · next · previous
  final String key;

  @override
  bool operator ==(Object other) => other is MediaCommand && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// up · down · mute · unmute, or a level.
class VolumeCommand extends QuickCommand {
  const VolumeCommand({this.change, this.level});

  final String? change;
  final int? level;

  @override
  bool operator ==(Object other) => other is VolumeCommand && other.change == change && other.level == level;

  @override
  int get hashCode => Object.hash(change, level);
}

/// A focus session; null minutes means the usual length.
class FocusCommand extends QuickCommand {
  const FocusCommand([this.minutes]);

  final int? minutes;

  @override
  bool operator ==(Object other) => other is FocusCommand && other.minutes == minutes;

  @override
  int get hashCode => minutes.hashCode;
}

/// pet · play · treat
class InteractCommand extends QuickCommand {
  const InteractCommand(this.kind);

  final String kind;

  @override
  bool operator ==(Object other) => other is InteractCommand && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

/// An app by name ("open Slack", "switch to VS Code").
class AppCommand extends QuickCommand {
  const AppCommand(this.name, {this.running = false});

  final String name;
  final bool running;

  @override
  bool operator ==(Object other) => other is AppCommand && other.name == name && other.running == running;

  @override
  int get hashCode => Object.hash(name, running);
}

/// A website ("open youtube").
class SiteCommand extends QuickCommand {
  const SiteCommand(this.url);

  final Uri url;

  @override
  bool operator ==(Object other) => other is SiteCommand && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// The rest have no arguments.
enum SimpleCommand implements QuickCommand { stopFocus, explore, comeHome, games, recap, decorate, sessionsStatus, agentNews }

abstract final class QuickCommands {
  static QuickCommand? parse(String text, {List<String> installedApps = const [], List<String> runningApps = const []}) {
    final s = normalize(text);
    if (s.isEmpty) return null;
    final fixed = _fixed[s];
    if (fixed != null) return fixed;

    RegExpMatch? whole(String pattern) => RegExp('^(?:$pattern)\$').firstMatch(s);

    var match = whole(r'(?:set |turn )?(?:the )?volume (?:to |at )?(\d{1,3})(?: ?%| percent)?');
    if (match != null) return VolumeCommand(level: (int.tryParse(match.group(1)!) ?? 50).clamp(0, 100));
    match = whole(
      r'(?:start |begin )?(?:a |an )?(\d{1,3})[ -]?(?:min|mins|minute|minutes)(?: of)?(?: focus| focus session| focus timer| focusing| pomodoro| timer)',
    );
    if (match != null) return FocusCommand(_minutes(match.group(1)!));
    match = whole(r'(?:start )?(?:a )?(?:focus|focusing|pomodoro)(?: session| timer)?(?: for)? (\d{1,3}) ?(?:min|mins|minute|minutes)');
    if (match != null) return FocusCommand(_minutes(match.group(1)!));
    if (whole(r"(?:what|how)(?:'s| is| are)? (?:my |the |all )?(?:claude|claudes|claude sessions?|sessions)(?: doing| up to| going)?") !=
        null) {
      return SimpleCommand.sessionsStatus;
    }
    match = whole(r'(?:open|launch|start|run) (.+)');
    if (match != null) {
      final target = match.group(1)!;
      final app = matchApp(target, installedApps);
      if (app != null) return AppCommand(app);
      final url = site(target);
      return url == null ? null : SiteCommand(url);
    }
    match = whole(r'(?:go to|switch to|bring up|show me|show|focus on|jump to) (.+)');
    if (match != null) {
      final target = match.group(1)!;
      final running = matchApp(target, runningApps);
      if (running != null) return AppCommand(running, running: true);
      final app = matchApp(target, installedApps);
      return app == null ? null : AppCommand(app);
    }
    return null;
  }

  /// Lowercased, punctuation, wake words ("hey Mochi,") and politeness ("please") removed.
  static String normalize(String text) {
    var s = text.toLowerCase().replaceAll('’', "'").replaceAll('‘', "'");
    s = s.split('').map((c) => RegExp(r"[\p{L}\p{N}'%\-.]", unicode: true).hasMatch(c) ? c : ' ').join();
    s = s.split(' ').where((word) => word.isNotEmpty).join(' ');
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    var changed = true;
    while (changed) {
      changed = false;
      for (final prefix in _prefixes) {
        if (s == prefix || s.startsWith('$prefix ')) {
          s = s.substring(prefix.length).trim();
          changed = true;
        }
      }
      for (final suffix in _suffixes) {
        if (s.endsWith(' $suffix')) {
          s = s.substring(0, s.length - suffix.length).trim();
          changed = true;
        }
      }
    }
    return s;
  }

  /// The installed or running app a spoken name refers to ("vs code" → "Visual Studio Code").
  static String? matchApp(String query, List<String> names) {
    var q = query;
    for (final prefix in const ['the ', 'my ']) {
      if (q.startsWith(prefix)) q = q.substring(prefix.length);
    }
    for (final suffix in const [' app', ' application', ' window', ' windows']) {
      if (q.endsWith(suffix)) q = q.substring(0, q.length - suffix.length);
    }
    final wanted = _key(_aliases[q] ?? q);
    if (wanted.isEmpty) return null;
    for (final name in names) {
      if (_key(name) == wanted) return name;
    }
    return null;
  }

  static Uri? site(String target) {
    var t = target;
    for (final prefix in const ['the ', 'my ']) {
      if (t.startsWith(prefix)) t = t.substring(prefix.length);
    }
    for (final suffix in const [' website', ' site', ' web site']) {
      if (t.endsWith(suffix)) t = t.substring(0, t.length - suffix.length);
    }
    final known = _sites[t];
    if (known != null) return Uri.parse(known);
    if (RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$').hasMatch(t) && t.split('.').last.length >= 2) return Uri.parse('https://$t');
    return null;
  }

  static String _key(String name) => name.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  static int _minutes(String text) => (int.tryParse(text) ?? 25).clamp(1, 180);

  static const List<String> _prefixes = [
    'hey mochi', 'hi mochi', 'ok mochi', 'okay mochi', 'yo mochi', 'hey motchi', 'mochi', 'motchi', 'mochie', //
    'please', 'can you please', 'could you please', 'can you', 'could you', 'would you', 'will you',
    'i want you to', 'go ahead and',
  ];
  static const List<String> _suffixes = ['please', 'for me', 'thanks', 'thank you', 'mochi', 'motchi', 'now'];

  static const Map<String, String> _aliases = {
    'vs code': 'Visual Studio Code', 'vscode': 'Visual Studio Code', 'code': 'Visual Studio Code', //
    'chrome': 'Google Chrome', 'iterm': 'iTerm', 'word': 'Microsoft Word', 'excel': 'Microsoft Excel',
    'powerpoint': 'Microsoft PowerPoint', 'teams': 'Microsoft Teams', 'outlook': 'Microsoft Outlook', 'edge': 'Microsoft Edge',
  };

  static const Map<String, String> _sites = {
    'youtube': 'https://www.youtube.com', 'gmail': 'https://mail.google.com', 'google': 'https://www.google.com', //
    'github': 'https://github.com', 'google maps': 'https://maps.google.com', 'google drive': 'https://drive.google.com',
    'google calendar': 'https://calendar.google.com', 'google docs': 'https://docs.google.com', 'twitter': 'https://x.com',
    'x': 'https://x.com', 'reddit': 'https://www.reddit.com', 'netflix': 'https://www.netflix.com',
    'linkedin': 'https://www.linkedin.com', 'instagram': 'https://www.instagram.com', 'wikipedia': 'https://www.wikipedia.org',
    'claude': 'https://claude.ai', 'chatgpt': 'https://chatgpt.com',
  };

  static final Map<String, QuickCommand> _fixed = () {
    final table = <String, QuickCommand>{};
    void add(QuickCommand command, List<String> phrases) {
      for (final phrase in phrases) {
        table[phrase] = command;
      }
    }

    add(const MediaCommand('playPause'), [
      'pause', 'pause it', 'pause music', 'pause the music', 'pause the song', 'pause the video', 'pause playback', //
      'stop the music', 'stop music', 'stop the song', 'stop the video', 'play', 'play music', 'play the music',
      'resume', 'resume music', 'resume the music', 'resume playing', 'continue playing', 'unpause', 'play pause',
    ]);
    add(const MediaCommand('next'), [
      'next', 'next song', 'next track', 'skip', 'skip song', 'skip this song', 'skip track', 'skip this', //
      'play the next song', 'next video',
    ]);
    add(const MediaCommand('previous'), [
      'previous',
      'previous song',
      'previous track',
      'last song',
      'go back a song',
      'play the previous song',
      'play the last song',
    ]);
    add(const VolumeCommand(change: 'up'), [
      'volume up', 'turn the volume up', 'turn volume up', 'turn up the volume', 'turn it up', 'louder', //
      'increase the volume', 'increase volume', 'raise the volume',
    ]);
    add(const VolumeCommand(change: 'down'), [
      'volume down', 'turn the volume down', 'turn volume down', 'turn down the volume', 'turn it down', 'quieter', //
      'softer', 'lower the volume', 'decrease the volume', 'decrease volume',
    ]);
    add(const VolumeCommand(change: 'mute'), ['mute', 'mute the sound', 'mute sound', 'mute the volume', 'mute volume', 'mute the mac']);
    add(const VolumeCommand(change: 'unmute'), ['unmute', 'unmute the sound', 'unmute sound', 'unmute the mac']);
    add(const FocusCommand(), [
      'focus', 'start focus', 'start focusing', 'start a focus session', 'start focus session', 'focus session', //
      'focus mode', 'start a pomodoro', 'pomodoro', 'start pomodoro', "let's focus", 'lets focus', 'help me focus',
    ]);
    add(SimpleCommand.stopFocus, [
      'stop focus', 'stop focusing', 'stop the focus session', 'stop focus session', 'end focus', 'end the focus session', //
      'cancel focus', 'stop the timer', 'stop timer', 'stop pomodoro', 'stop the pomodoro', 'end the pomodoro',
    ]);
    add(SimpleCommand.explore, [
      'explore', 'go explore', 'go exploring', 'explore the desktop', 'go for a walk', 'take a walk', 'go on an adventure', //
      'adventure', 'go play on the desktop',
    ]);
    add(SimpleCommand.comeHome, ['come home', 'come back', 'come back home', 'go home', 'come back to the menu bar', 'home']);
    add(const InteractCommand('pet'), [
      'pet', 'purr', 'good kitty', 'good cat', 'good girl', 'good boy', 'i love you', 'love you', "who's a good cat", //
      "who's a good kitty",
    ]);
    add(const InteractCommand('play'), ['play with me', "let's play", 'lets play', 'wanna play', 'want to play']);
    add(const InteractCommand('treat'), [
      'treat', 'have a treat', 'eat', 'eat something', 'feed', 'feed yourself', 'snack', 'have a snack', 'dinner time', //
      'food', 'are you hungry',
    ]);
    add(SimpleCommand.games, ['games', 'open games', 'play a game', "let's play a game", 'lets play a game', 'show games']);
    add(SimpleCommand.recap, [
      'recap', 'show recap', 'show me the recap', "today's recap", 'todays recap', "show today's recap", 'daily recap', //
      'what did i do today', 'how was my day',
    ]);
    add(SimpleCommand.decorate, ['decorate', 'decorate the room', 'room makeover', 'edit the room', 'redecorate']);
    add(SimpleCommand.sessionsStatus, [
      'status',
      'claude status',
      'sessions',
      'my sessions',
      'show my claude sessions',
      'show my sessions',
      'list my claude sessions',
    ]);
    add(SimpleCommand.agentNews, [
      "what's pending", 'whats pending', 'what is pending', 'anything pending', "what's new", 'whats new', 'anything new', //
      'check my email', 'check my mail', 'check my inbox', 'check email', 'any new email', 'any new emails', 'any new mail',
      'summarize my email', 'summarise my email', 'summarize my unread', 'summarise my unread', 'summarize my inbox',
      'summarise my inbox', "what's on my calendar", 'whats on my calendar', 'what do i have today', "what's on today",
      'whats on today', 'briefing', 'my briefing', 'morning briefing', 'give me my briefing', 'what needs me',
      'what needs my attention',
    ]);
    return table;
  }();
}
