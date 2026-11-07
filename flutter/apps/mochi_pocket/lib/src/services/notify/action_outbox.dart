import 'package:mochi_link/mochi_link.dart';

import '../local_file.dart';

/// What notification buttons pressed while Mochi was closed leave for the app (`notification_actions.json`), which
/// takes it in when it next starts or comes back:
///
/// - [sent]: replies the relay took, so Recently shows them and the computer's answer finds them.
/// - [queued]: replies the relay couldn't take, sent by the app when it connects (within ten minutes).
/// - [doneChanged]: done marks were added to `done.json`, so the app reads them again.
/// - [shareDone]: this phone's done list couldn't reach the relay; the app shares it when it connects.
class NotificationOutbox {
  NotificationOutbox({List<LinkCommand>? sent, List<LinkCommand>? queued, this.doneChanged = false, this.shareDone = false})
    : sent = sent ?? [],
      queued = queued ?? [];

  final List<LinkCommand> sent;
  final List<LinkCommand> queued;
  bool doneChanged;
  bool shareDone;

  /// A reply older than this isn't sent any more: the relay keeps commands for ten minutes, and a request that
  /// arrives much later than it was written would surprise.
  static const double replyLifetime = 600;

  /// At most this many of each, newest kept.
  static const int maxReplies = 12;

  bool get isEmpty => sent.isEmpty && queued.isEmpty && !doneChanged && !shareDone;

  Map<String, Object?> toJson() => {
    'sent': [for (final command in sent) command.toJson()],
    'queued': [for (final command in queued) command.toJson()],
    'doneChanged': doneChanged,
    'shareDone': shareDone,
  };

  static NotificationOutbox fromJson(Map<String, Object?>? json) {
    List<LinkCommand> commands(Object? raw) => [if (raw is List) ...raw.map(LinkCommand.fromJson).whereType<LinkCommand>()];
    return NotificationOutbox(
      sent: commands(json?['sent']),
      queued: commands(json?['queued']),
      doneChanged: json?['doneChanged'] == true,
      shareDone: json?['shareDone'] == true,
    );
  }

  /// Reads [document], applies [change] and writes it back.
  static Future<void> update(LocalDocument document, void Function(NotificationOutbox outbox) change) async {
    final outbox = fromJson(await document.read());
    change(outbox);
    for (final list in [outbox.sent, outbox.queued]) {
      if (list.length > maxReplies) list.removeRange(0, list.length - maxReplies);
    }
    await document.write(outbox.toJson());
  }

  /// Reads and empties [document] (the app taking it in). Null when there's nothing.
  static Future<NotificationOutbox?> take(LocalDocument document) async {
    final json = await document.read();
    if (json == null) return null;
    await document.delete();
    final outbox = fromJson(json);
    return outbox.isEmpty ? null : outbox;
  }
}
