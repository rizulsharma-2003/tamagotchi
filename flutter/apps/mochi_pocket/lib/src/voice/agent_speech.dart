import 'package:mochi_link/mochi_link.dart';

/// What Mochi says when it reads "Waiting for you" out loud: TamagotchiCore `AgentSpeech.script`, word for word, so the
/// iPhone and Android say the same thing for the same items.
abstract final class AgentSpeech {
  /// [time] writes a meeting's start the way the phone shows times ("4:00 PM" or "16:00"), as the iPhone's short
  /// time style does.
  static String script(List<AgentNote> items, {String Function(DateTime time)? time}) {
    if (items.isEmpty) return 'Nothing is waiting for you right now. Enjoy!';
    final at = time ?? shortTime;
    final sentences = [items.length == 1 ? 'One thing is waiting for you.' : '${items.length} things are waiting for you.'];
    final events = items.where((item) => item.source == AgentSource.calendar).toList()
      ..sort((a, b) => (a.due ?? double.infinity).compareTo(b.due ?? double.infinity));
    final mail = items.where((item) => item.source == AgentSource.gmail).toList();
    final important = mail.where((item) => item.important).toList();
    final rest = mail.where((item) => !item.important).toList();
    final tasks = items.where((item) => item.source == AgentSource.notion).toList();
    for (final event in events.take(3)) {
      final due = event.due;
      sentences.add(due == null ? '${event.title}.' : '${event.title}, at ${at(_date(due))}.');
    }
    if (events.length > 3) sentences.add('And ${events.length - 3} more meetings.');
    for (final email in important.take(4)) {
      sentences.add('${email.title} needs you: ${spoken(email.subject ?? email.detail)}.');
    }
    if (important.length > 4) sentences.add('And ${important.length - 4} more emails that need you.');
    switch (rest.length) {
      case 0:
        break;
      case 1 || 2:
        for (final email in rest) {
          sentences.add('From ${email.title}: ${spoken(email.detail)}.');
        }
      default:
        final names = ({for (final email in rest) email.title}.toList()..sort()).take(2).join(' and ');
        sentences.add('And ${rest.length} more emails, nothing urgent, from $names and others.');
    }
    for (final task in tasks.take(3)) {
      sentences.add('Due in Notion: ${spoken(task.title)}.');
    }
    if (tasks.length > 3) sentences.add('And ${tasks.length - 3} more tasks.');
    sentences.add("That's everything.");
    return sentences.join(' ');
  }

  /// Without trailing punctuation or symbols a voice would read out ("·", "…").
  static String spoken(String text) {
    var line = text.replaceAll(' · ', ', ').replaceAll('…', '');
    while (line.isNotEmpty && '.!?,;: '.contains(line[line.length - 1])) {
      line = line.substring(0, line.length - 1);
    }
    return line;
  }

  /// "4:00 PM": the iPhone's short time style in English, for when no locale-aware formatter is given.
  static String shortTime(DateTime time) {
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    return '$hour:${time.minute.toString().padLeft(2, '0')} ${time.hour < 12 ? 'AM' : 'PM'}';
  }

  /// The sentences of a script, so it can be spoken one at a time with a short breath between them.
  /// A sentence ends at ., ! or ? followed by a space (so "v2.1" and "4:00 PM" stay whole).
  static List<String> sentences(String text) {
    final list = text.split(RegExp(r'(?<=[.!?])\s+')).map((sentence) => sentence.trim()).where((s) => s.isNotEmpty).toList();
    return list.isEmpty ? [text] : list;
  }

  static DateTime _date(double seconds) => DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
}
