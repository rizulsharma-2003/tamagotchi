import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import '../services/alert_notifier.dart';
import '../theme.dart';
import '../widgets/clay.dart';
import 'home_screen.dart' show connectionPill;

/// The app's version, sent in the relay `hello` and shown here.
const String appVersion = '0.1.0';

/// Settings: Mochi Link (who this phone is paired with, the relay and the Mac's presence, Unpair) and notifications
/// (iOS/MochiPocket/PocketLink.swift `LinkCard`, PocketSettingsView).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.model, required this.notifier});

  final PocketModel model;
  final AlertNotifier notifier;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool? _notificationsOn;

  PocketModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotifications();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Android's settings: notifications may have been turned on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkNotifications();
  }

  Future<void> _checkNotifications() async {
    final on = await widget.notifier.enabled();
    if (mounted) setState(() => _notificationsOn = on);
  }

  Future<void> _allowNotifications() async {
    final on = await widget.notifier.requestPermission();
    if (mounted) setState(() => _notificationsOn = on);
  }

  Future<void> _confirmUnpair() async {
    final navigator = Navigator.of(context);
    final unpair = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Unpair from ${model.macName}?'),
        content: const Text("Mochi forgets this pairing and leaves your Mac's room. To use it again, pair with a new code from your Mac."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (unpair != true) return;
    await model.unpair();
    navigator.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: PocketBackground(
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.xl + MediaQuery.paddingOf(context).bottom),
          children: [
            _link(),
            const SizedBox(height: Space.l),
            _notifications(),
            const SizedBox(height: Space.l),
            Text(
              'Mochi for Android $appVersion · Mochi Link protocol $linkClientVersion',
              textAlign: TextAlign.center,
              style: context.type.footnote,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _link() {
    final credentials = model.credentials;
    final lastSeen = model.mac?.lastSeen;
    final explanation = switch (model.connection) {
      MacConnection.macOnline =>
        'Connected to the relay, and your Mac is online. Messages reach it in under a second, end-to-end encrypted.',
      MacConnection.macAway =>
        "Connected to the relay, but your Mac isn't (it's asleep or off${lastSeen == null ? '' : ', since ${clockTime(context, lastSeen)}'}). "
            'What you send waits for it for 10 minutes.',
      MacConnection.connecting => 'Connecting to the relay…',
      MacConnection.noConnection =>
        "Can't reach the relay right now (no internet?). What you send waits here and goes when the phone is back online.",
      MacConnection.removed =>
        "This phone isn't in your Mac's room any more: it was removed, or the room was deleted. Unpair, then pair again.",
    };
    return ClayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The status pill sits beside the title, or under it when the text is large: never cut short.
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.start,
            spacing: Space.s,
            overflowSpacing: Space.s,
            children: [
              Semantics(header: true, child: Text('Mochi Link', style: context.type.headline)),
              connectionPill(context, model),
            ],
          ),
          const SizedBox(height: Space.m),
          NoteLabel(
            text: 'Paired with ${model.macName}',
            icon: Icons.link_rounded,
            tint: context.palette.tint,
            textColor: context.palette.ink,
          ),
          const SizedBox(height: Space.s),
          Text(explanation, style: context.type.footnote),
          const SizedBox(height: Space.m),
          _detail('This phone', model.deviceName),
          if (credentials != null) _detail('Relay', credentials.relay),
          _detail('Relay connection', switch (model.status) {
            LinkStatus.online => 'Connected',
            LinkStatus.connecting => 'Connecting…',
            LinkStatus.offline => 'Not connected',
            LinkStatus.removed => 'Ended',
          }),
          const SizedBox(height: Space.m),
          OutlinedButton.icon(
            onPressed: _confirmUnpair,
            style: OutlinedButton.styleFrom(foregroundColor: context.palette.danger),
            icon: const Icon(Icons.link_off_rounded, size: 18),
            label: const Text('Unpair'),
          ),
        ],
      ),
    );
  }

  /// A label and its value side by side, or the value under its label when the text is large.
  Widget _detail(String label, String value) {
    final labelText = Text(label, style: context.type.footnote);
    final valueText = Text(value, style: context.type.footnote.copyWith(color: context.palette.ink));
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: stacked
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [labelText, valueText])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 132, child: labelText),
                  const SizedBox(width: Space.s),
                  Expanded(child: valueText),
                ],
              ),
      ),
    );
  }

  Widget _notifications() => ClayCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text('Notifications', style: context.type.headline)),
        const SizedBox(height: Space.m),
        NoteLabel(
          text:
              "Claude's finished turns, approvals and news from your Mac show up as notifications only while Mochi is open "
              'or still running in the background. Push notifications, which reach you when the app is closed, come in a '
              'later version.',
          icon: Icons.notifications_active_rounded,
          tint: context.palette.tint,
          textColor: context.palette.ink,
        ),
        if (_notificationsOn == false) ...[
          const SizedBox(height: Space.m),
          NoteLabel(text: 'Notifications are turned off for Mochi.', icon: Icons.notifications_off_rounded, tint: context.palette.warning),
          const SizedBox(height: Space.s),
          FilledButton(onPressed: _allowNotifications, child: const Text('Allow Notifications')),
        ],
      ],
    ),
  );
}
