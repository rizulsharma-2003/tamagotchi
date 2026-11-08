// Windows notifications (toasts) for Claude's moments: the Mac's NotificationCoordinator. What a toast says and where a
// click on it goes; the Windows side is platform/win32_toasts.dart.

/// Where clicking a toast takes you.
class ToastTarget {
  const ToastTarget._(this.kind, [this.sessionId]);

  /// One Claude session's card in Mochi's window.
  const ToastTarget.session(String id) : this._(ToastTargetKind.session, id);

  /// Mochi's window.
  static const ToastTarget main = ToastTarget._(ToastTargetKind.main);

  /// The Agent's card (Settings › Agent, until the agent runs on Windows).
  static const ToastTarget agent = ToastTarget._(ToastTargetKind.agent);

  /// Today's recap card (W16).
  static const ToastTarget recap = ToastTarget._(ToastTargetKind.recap);

  final ToastTargetKind kind;
  final String? sessionId;

  /// What the toast carries (its `launch` argument): "mochi:session=<id>", "mochi:main", "mochi:agent", "mochi:recap".
  String encode() => switch (kind) {
    ToastTargetKind.session => 'mochi:session=${Uri.encodeComponent(sessionId!)}',
    ToastTargetKind.main => 'mochi:main',
    ToastTargetKind.agent => 'mochi:agent',
    ToastTargetKind.recap => 'mochi:recap',
  };

  /// Back from a toast's argument (anything unknown: Mochi's window).
  static ToastTarget parse(String? argument) {
    if (argument == null || !argument.startsWith('mochi:')) return main;
    final rest = argument.substring(6);
    if (rest.startsWith('session=')) {
      final id = Uri.decodeComponent(rest.substring(8));
      return id.isEmpty ? main : ToastTarget.session(id);
    }
    return switch (rest) {
      'agent' => agent,
      'recap' => recap,
      _ => main,
    };
  }

  @override
  bool operator ==(Object other) => other is ToastTarget && other.kind == kind && other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(kind, sessionId);

  @override
  String toString() => encode();
}

enum ToastTargetKind { session, main, agent, recap }

/// One toast: its words, where a click goes, and its group (a newer toast of the same group replaces the older one in
/// the notification centre, so a batch of the same moment shows once).
class Toast {
  const Toast({required this.title, required this.body, required this.target, required this.group});

  final String title;
  final String body;
  final ToastTarget target;
  final String group;

  /// Windows' toast XML: the two lines, the click's argument, and no sound of its own (Mochi plays its own, as Settings
  /// says).
  String xml() {
    String escape(String text) =>
        text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
    return '<toast launch="${escape(target.encode())}" activationType="foreground">'
        '<visual><binding template="ToastGeneric">'
        '<text hint-maxLines="1">${escape(title)}</text>'
        '<text>${escape(body)}</text>'
        '</binding></visual>'
        '<audio silent="true"/>'
        '</toast>';
  }

  /// A stable number for [group] (Windows tags toasts with it).
  int get tag {
    var hash = 0x811C9DC5;
    for (final unit in group.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }
}

/// Whether Windows can show Mochi's notifications, and if not, why.
enum ToastAvailability {
  /// Mochi's notifications are on.
  ready,

  /// Mochi runs from where it was downloaded: Windows only shows notifications from an installed app (with its Start-menu
  /// entry).
  notInstalled,

  /// Notifications for Mochi are off in Windows Settings › System › Notifications.
  offForMochi,

  /// Every app's notifications are off in Windows Settings › System › Notifications.
  offForAll,

  /// Windows refused to set them up.
  failed,

  /// Not Windows (the macOS development build).
  unsupported;

  bool get works => this == ready;
}

/// Shows toasts and says when one is clicked.
abstract interface class ToastService {
  ToastAvailability get availability;

  /// Sets up Mochi's notifications; [onOpen] runs when one is clicked (while Mochi runs, or Mochi was started for it).
  Future<void> start(void Function(ToastTarget target) onOpen);

  /// Reads Windows' notification settings again (Settings › Notifications shows them).
  Future<void> refresh();

  /// False when it couldn't be shown.
  Future<bool> show(Toast toast);

  /// Opens Windows Settings › System › Notifications.
  Future<void> openSystemSettings();

  void dispose();
}

class UnsupportedToasts implements ToastService {
  const UnsupportedToasts();

  @override
  ToastAvailability get availability => ToastAvailability.unsupported;

  @override
  Future<void> start(void Function(ToastTarget target) onOpen) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> show(Toast toast) async => false;

  @override
  Future<void> openSystemSettings() async {}

  @override
  void dispose() {}
}
