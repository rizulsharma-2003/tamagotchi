import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mochi_home_widget/mochi_home_widget.dart';
import 'package:mochi_link/mochi_link.dart';

import '../live/live_notifier.dart';
import '../live/live_updates.dart';
import '../model/app_settings.dart';
import '../model/pocket_model.dart';
import '../services/alert_notifier.dart';
import '../theme.dart';
import '../voice/mochi_voice.dart';
import '../voice/updates_reader.dart';
import '../widget/home_widget.dart';
import '../widgets/clay.dart';
import 'home_screen.dart' show connectionPill;

/// The app's version, sent in the relay `hello` and shown here.
const String appVersion = '0.1.0';

/// Settings: Mochi Link (who this phone is paired with, the relay and the Mac's presence, Unpair), notifications, Mochi
/// on the lock screen, the home-screen widget, appearance, Mochi's voice and Mochi Cloud (iOS/MochiPocket/PocketLink.swift
/// `LinkCard`, PocketSettingsView).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.model,
    required this.notifier,
    required this.settings,
    required this.reader,
    this.live,
    this.homeWidget,
  });

  final PocketModel model;
  final AlertNotifier notifier;
  final AppSettings settings;
  final UpdatesReader reader;

  /// Mochi on the lock screen while Claude works: the sample, and taking it away when the switch goes off.
  final LiveUpdates? live;

  /// The home-screen widget: whether it's there, and Add to Home Screen.
  final HomeWidget? homeWidget;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool? _notificationsOn;
  late Future<List<VoiceInfo>> _voices = widget.reader.voices();
  LiveUpdateStatus? _liveStatus;
  HomeWidgetPlacement? _widgetPlacement;
  String _samplePhase = 'working';
  bool _sampleShown = false;

  PocketModel get model => widget.model;
  AppSettings get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotifications();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // A sample still playing stops with the screen, as on the iPhone.
    widget.reader.stop();
    super.dispose();
  }

  /// Back from Android's settings: notifications may have been turned on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _checkNotifications();
    // A voice may have been downloaded in Android's settings meanwhile.
    setState(() => _voices = widget.reader.refreshVoices());
  }

  Future<void> _checkNotifications() async {
    final on = await widget.notifier.enabled();
    final live = await widget.live?.notifier.status();
    final placement = await widget.homeWidget?.surface.status();
    if (mounted) {
      setState(() {
        _notificationsOn = on;
        _liveStatus = live;
        _widgetPlacement = placement;
      });
    }
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
        title: Text('Unpair from ${model.host.name ?? model.host.yours}?'),
        content: Text(
          "Mochi forgets this pairing and leaves ${model.host.yours}'s room. To use it again, pair with a new code from your Mac or PC.",
        ),
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
  Widget build(BuildContext context) => PopScope(
    // Leaving stops a sample at once (the iPhone's onDisappear).
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) widget.reader.stop();
    },
    child: _screen(context),
  );

  Widget _screen(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: PocketBackground(
      child: ListenableBuilder(
        listenable: Listenable.merge([model, settings, widget.reader]),
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.xl + MediaQuery.paddingOf(context).bottom),
          children: [
            _link(),
            const SizedBox(height: Space.l),
            _notifications(),
            if (widget.live != null) ...[const SizedBox(height: Space.l), _lockScreen()],
            if (widget.homeWidget != null) ...[const SizedBox(height: Space.l), _homeScreen()],
            const SizedBox(height: Space.l),
            _appearance(),
            const SizedBox(height: Space.l),
            _voice(),
            const SizedBox(height: Space.l),
            _cloud(),
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
    final host = model.host;
    final explanation = switch (model.connection) {
      MacConnection.macOnline =>
        'Connected to the relay, and ${host.yours} is online. Messages reach it in under a second, end-to-end encrypted.',
      MacConnection.macAway =>
        "Connected to the relay, but ${host.yours} isn't (it's asleep or off${lastSeen == null ? '' : ', since ${clockTime(context, lastSeen)}'}). "
            'What you send waits for it for 10 minutes.',
      MacConnection.connecting => 'Connecting to the relay…',
      MacConnection.noConnection =>
        "Can't reach the relay right now (no internet?). What you send waits here and goes when the phone is back online.",
      MacConnection.removed =>
        "This phone isn't in ${host.yours}'s room any more: it was removed, or the room was deleted. Unpair, then pair again.",
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
            text: 'Paired with ${model.hostList}',
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

  /// Whether alerts reach this phone while Mochi is closed, and if not, why.
  Widget _pushStatus() {
    final p = context.palette;
    final (icon, tint, headline, detail) = switch (model.pushStatus) {
      PushStatus.registered => (
        Icons.notifications_active_rounded,
        p.success,
        'Notifications: on (Firebase)',
        "Claude's finished turns, approvals and news from ${model.host.yours} reach this phone even when Mochi is closed. "
            'They are end-to-end encrypted: only this phone can read them.',
      ),
      PushStatus.starting => (
        Icons.notifications_rounded,
        p.inkSecondary,
        'Notifications: setting up…',
        'Getting a push address from Firebase.',
      ),
      PushStatus.unavailable => (
        Icons.notifications_paused_rounded,
        p.warning,
        'Notifications: only while Mochi is open',
        'Push is off because ${model.pushProblem ?? 'it could not be set up'}. Alerts still arrive while the app is open '
            'or running in the background.',
      ),
      PushStatus.off => (
        Icons.notifications_off_rounded,
        p.inkSecondary,
        'Notifications: off',
        'Pair with your Mac or PC to get its alerts.',
      ),
    };
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: ExcludeSemantics(child: Icon(icon, size: 18, color: tint)),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(detail, style: context.type.footnote),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notifications() => ClayCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text('Notifications', style: context.type.headline)),
        const SizedBox(height: Space.m),
        _pushStatus(),
        if (_notificationsOn == false) ...[
          const SizedBox(height: Space.m),
          NoteLabel(text: 'Notifications are turned off for Mochi.', icon: Icons.notifications_off_rounded, tint: context.palette.warning),
          const SizedBox(height: Space.s),
          FilledButton(onPressed: _allowNotifications, child: const Text('Allow Notifications')),
        ],
      ],
    ),
  );

  // MARK: Lock screen

  static const List<(String, String)> _phases = [
    ('working', 'Working'),
    ('waiting', 'Needs you'),
    ('done', 'Done'),
    ('error', 'Snag'),
    ('idle', 'Idle'),
    ('asleep', 'Napping'),
  ];

  /// Mochi on the lock screen while Claude works: the iPhone's Live Activity card ("Lock Screen & Dynamic Island"),
  /// with the switch and a sample.
  Widget _lockScreen() {
    final p = context.palette;
    final live = widget.live!;
    final on = settings.showOnLockScreen;
    final status = _liveStatus;
    return ClayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.start,
            spacing: Space.s,
            overflowSpacing: Space.s,
            children: [
              Semantics(header: true, child: Text('Lock screen', style: context.type.headline)),
              Tag(text: on ? 'On' : 'Off', icon: on ? Icons.check_rounded : Icons.close_rounded, tint: on ? p.success : p.inkSecondary),
            ],
          ),
          const SizedBox(height: Space.s),
          MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Show ${model.petName} on my lock screen while Claude works',
                    style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600, color: p.ink),
                  ),
                ),
                const SizedBox(width: Space.s),
                Switch(
                  value: on,
                  onChanged: (value) {
                    settings.showOnLockScreen = value;
                    if (!value) {
                      setState(() => _sampleShown = false);
                      unawaited(live.turnedOff());
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            'An ongoing notification on your lock screen and in the status bar while Claude works on ${model.host.yours}: '
            '${model.petName}, what Claude is doing and for how long. It lights up when Claude needs you and celebrates when '
            "Claude is done. ${model.host.yoursCapitalized} sends it; it's end-to-end encrypted like everything else.",
            style: context.type.footnote,
          ),
          if (on && status != null && !status.enabled) ...[
            const SizedBox(height: Space.m),
            NoteLabel(
              text: "Notifications are turned off for Mochi, so it can't show.",
              icon: Icons.notifications_off_rounded,
              tint: p.warning,
            ),
          ] else if (on && status?.promotable == false) ...[
            const SizedBox(height: Space.m),
            NoteLabel(
              text:
                  "Live updates are off for Mochi in Android's notification settings, so it's an ordinary notification, not a "
                  'chip in the status bar.',
              icon: Icons.info_outline_rounded,
              tint: p.inkSecondary,
            ),
          ],
          if (on) ...[
            const SizedBox(height: Space.m),
            Wrap(
              spacing: Space.s,
              runSpacing: Space.xs,
              children: [
                for (final (phase, title) in _phases)
                  _chip(title, selected: _samplePhase == phase, onSelected: () => setState(() => _samplePhase = phase)),
              ],
            ),
            const SizedBox(height: Space.s),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final posted = await live.sample(_samplePhase, host: model.host);
                      if (mounted) setState(() => _sampleShown = posted == LiveUpdatePosted.shown);
                      if (posted == LiveUpdatePosted.blocked) await _allowNotifications();
                    },
                    icon: const Icon(Icons.lock_rounded, size: 18),
                    label: const Text('Show on Lock Screen'),
                  ),
                ),
                if (_sampleShown) ...[
                  const SizedBox(width: Space.s),
                  IconButton.outlined(
                    onPressed: () async {
                      await live.removeSample();
                      if (mounted) setState(() => _sampleShown = false);
                    },
                    tooltip: 'Remove the sample',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ],
            ),
            const SizedBox(height: Space.s),
            Text(
              'The sample stays for two minutes. ${model.host.yoursCapitalized} shows ${model.petName} here automatically while '
              'Claude works.',
              style: context.type.footnote,
            ),
          ],
        ],
      ),
    );
  }

  // MARK: Home screen

  /// The "Mochi & Claude" widget (the iPhone's Lock Screen and Home Screen widget): what it shows, whether it's on the
  /// home screen, and Add to Home Screen when the launcher can be asked.
  Widget _homeScreen() {
    final p = context.palette;
    final placement = _widgetPlacement;
    final placed = (placement?.placed ?? 0) > 0;
    return ClayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.start,
            spacing: Space.s,
            overflowSpacing: Space.s,
            children: [
              Semantics(header: true, child: Text('Home screen', style: context.type.headline)),
              if (placement != null)
                Tag(
                  text: placed ? 'Widget added' : 'No widget yet',
                  icon: placed ? Icons.check_rounded : Icons.widgets_outlined,
                  tint: placed ? p.success : p.inkSecondary,
                ),
            ],
          ),
          const SizedBox(height: Space.s),
          Text(
            'The “Mochi & Claude” widget shows ${model.petName}, what Claude is doing on ${model.host.yours}, and what’s waiting '
            'for you. It keeps itself up to date, even while ${model.petName} is closed. Tap it to open ${model.petName}.',
            style: context.type.footnote,
          ),
          const SizedBox(height: Space.m),
          if (placement?.canPin ?? false)
            FilledButton.icon(
              onPressed: () async {
                final asked = await widget.homeWidget!.surface.pin();
                if (!asked && mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Long-press your home screen, tap Widgets, and find Mochi.')));
                }
              },
              icon: const Icon(Icons.add_to_home_screen_rounded, size: 18),
              label: Text(placed ? 'Add Another' : 'Add to Home Screen'),
            )
          else
            NoteLabel(
              text: 'To add it: long-press your home screen, tap Widgets, and find Mochi.',
              icon: Icons.widgets_outlined,
              tint: p.tint,
              textColor: p.ink,
            ),
        ],
      ),
    );
  }

  // MARK: Appearance

  Widget _appearance() {
    return ClayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text('Appearance', style: context.type.headline)),
          const SizedBox(height: Space.m),
          Wrap(
            spacing: Space.s,
            runSpacing: Space.xs,
            children: [
              for (final option in Appearance.values)
                _chip(option.title, selected: settings.appearance == option, onSelected: () => settings.appearance = option),
            ],
          ),
          const SizedBox(height: Space.s),
          Text(switch (settings.appearance) {
            Appearance.system => "Follows your phone's dark theme setting.",
            Appearance.light => 'Always light, whatever the phone is set to.',
            Appearance.dark => 'Always dark, whatever the phone is set to.',
          }, style: context.type.footnote),
        ],
      ),
    );
  }

  /// A choice: terracotta when chosen, a well otherwise, 48 dp to touch (the iPhone's `Chip`).
  Widget _chip(String title, {required bool selected, required VoidCallback onSelected}) {
    final p = context.palette;
    return ChoiceChip(
      label: Text(title),
      selected: selected,
      showCheckmark: false,
      selectedColor: p.tint,
      backgroundColor: p.sunken,
      side: BorderSide(color: p.stroke),
      labelStyle: context.type.label.copyWith(color: selected ? p.onTint : p.ink),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      onSelected: (_) => onSelected(),
    );
  }

  // MARK: Voice

  /// Plays a sample in the voice as set now; a second tap stops it (the iPhone's "Hear It").
  void _hear({bool restart = false}) {
    final reader = widget.reader;
    if (reader.speaking && !restart) {
      reader.stop();
      return;
    }
    reader.say(
      "Hi, I'm ${model.petName}! Two things are waiting for you. Your design review is at 4 pm, "
      "and Priya needs you: the invoice for October. That's everything.",
      talkBack: MediaQuery.accessibleNavigationOf(context),
    );
  }

  Widget _voice() {
    final p = context.palette;
    final speaking = widget.reader.speaking;
    return ClayCard(
      child: FutureBuilder<List<VoiceInfo>>(
        future: _voices,
        builder: (context, snapshot) {
          final voices = snapshot.data ?? const <VoiceInfo>[];
          final best = voices.firstOrNull;
          final chosen = voices.where((voice) => voice.name == settings.voiceName).firstOrNull;
          final reading = chosen ?? best;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.start,
                spacing: Space.s,
                overflowSpacing: Space.s,
                children: [
                  Semantics(header: true, child: Text("${model.petName}'s voice", style: context.type.headline)),
                  FilledButton.icon(
                    onPressed: snapshot.hasData && voices.isEmpty ? null : _hear,
                    icon: Icon(speaking ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18),
                    label: Text(speaking ? 'Stop' : 'Hear a sample'),
                  ),
                ],
              ),
              const SizedBox(height: Space.m),
              Wrap(
                spacing: Space.s,
                runSpacing: Space.xs,
                children: [
                  for (final option in VoiceCharacter.values)
                    _chip(
                      option.title,
                      selected: settings.character == option,
                      onSelected: () {
                        settings.character = option;
                        _hear(restart: true);
                      },
                    ),
                ],
              ),
              const SizedBox(height: Space.xs),
              Text(settings.character.blurb, style: context.type.footnote),
              const SizedBox(height: Space.m),
              Semantics(
                button: true,
                label: 'Voice: ${chosen == null ? 'best on this phone' : chosen.label}',
                excludeSemantics: true,
                child: InkWell(
                  onTap: snapshot.hasData ? () => _pickVoice(voices) : null,
                  borderRadius: BorderRadius.circular(Radii.inner),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: touchTarget),
                    padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
                    decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.inner)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Voice', style: context.type.footnote),
                              Text(
                                !snapshot.hasData
                                    ? 'Looking for voices…'
                                    : chosen == null
                                    ? 'Best on this phone${best == null ? '' : ' (${best.label})'}'
                                    : chosen.label,
                                style: context.type.subheadline,
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.unfold_more_rounded, color: p.inkSecondary),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Space.s),
              if (snapshot.hasData && voices.isEmpty)
                NoteLabel(
                  text:
                      'No English voice on this phone yet. In Android Settings, search "Text-to-speech" and install English '
                      'voice data, then come back.',
                  icon: Icons.warning_rounded,
                  tint: p.warning,
                )
              else if (reading?.network ?? false)
                NoteLabel(
                  text:
                      "This voice needs the internet: what ${model.petName} reads is sent to your speech engine's servers to be "
                      'spoken. Pick one marked "on this phone" to keep it all here.',
                  icon: Icons.cloud_rounded,
                  tint: p.warning,
                )
              else
                NoteLabel(text: 'Everything is spoken on this phone; nothing is sent anywhere.', icon: Icons.lock_rounded, tint: p.success),
            ],
          );
        },
      ),
    );
  }

  // MARK: Mochi Cloud

  /// Mochi Cloud (the iPhone's Settings › Mochi Cloud): whether its hourly news has reached this phone, whether Check now
  /// can use it while the computer is off, and where Check now goes.
  Widget _cloud() {
    final p = context.palette;
    final host = model.host;
    final seen = model.cloudSeenAt;
    final available = model.cloudAvailable;
    final always = settings.checkNowUsesCloud;
    return ClayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text('Mochi Cloud', style: context.type.headline)),
          const SizedBox(height: Space.m),
          _check(
            'Hourly checks',
            ok: seen != null,
            detail: seen == null ? 'No news from the cloud yet' : 'Last news ${relativeTime(seen)}',
          ),
          _check('Check now without ${host.yours}', ok: available, detail: available ? 'Ready' : 'Add the API trigger on ${host.yours}'),
          const SizedBox(height: Space.s),
          MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Check now always asks Mochi Cloud',
                    style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600, color: p.ink),
                  ),
                ),
                const SizedBox(width: Space.s),
                Switch(value: always, onChanged: (value) => settings.checkNowUsesCloud = value),
              ],
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            always
                ? 'Check now goes straight to the cloud, whether ${host.yours} is on or off. Answers take a minute or two and arrive '
                      'as a notification.'
                : "Check now asks ${host.yours} first (faster when it's on) and the cloud only when it doesn't answer.",
            style: context.type.footnote,
          ),
          const SizedBox(height: Space.s),
          Text(
            "While ${host.yours} is off, a Claude task in Anthropic's cloud checks your mail, calendar and Notion every hour from "
            '8 am to 11 pm and notifies you here. News ${host.yours} already gave you arrives quietly. Set it up in '
            "${host.yours}'s Settings › Agent › Mochi Cloud.",
            style: context.type.footnote,
          ),
        ],
      ),
    );
  }

  /// A status line: a tick or an empty circle, what it is, and how it stands (under it when the text is large).
  Widget _check(String title, {required bool ok, required String detail}) {
    final p = context.palette;
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final titleText = Text(title, style: context.type.subheadline.copyWith(color: p.ink));
    final detailText = Text(detail, style: context.type.footnote);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: ok ? p.success : p.inkSecondary,
                semanticLabel: ok ? 'Yes' : 'Not yet',
              ),
            ),
            const SizedBox(width: Space.s),
            Expanded(
              child: stacked
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [titleText, detailText])
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: titleText),
                        const SizedBox(width: Space.s),
                        Flexible(
                          child: Text(detail, textAlign: TextAlign.end, style: context.type.footnote),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The phone's English voices, best first; picking one plays the sample in it.
  Future<void> _pickVoice(List<VoiceInfo> voices) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.75),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.s),
                child: Text('Voice', style: sheet.type.title3),
              ),
              _voiceTile(sheet, null, voices.firstOrNull),
              for (final voice in voices) _voiceTile(sheet, voice, null),
              ListTile(leading: const Icon(Icons.close_rounded), title: const Text('Close'), onTap: () => Navigator.pop(sheet)),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    settings.voiceName = picked.isEmpty ? null : picked;
    _hear(restart: true);
  }

  /// One choice in the voice sheet: [voice], or "Best on this phone" (null) with [best] named.
  Widget _voiceTile(BuildContext sheet, VoiceInfo? voice, VoiceInfo? best) {
    final selected = voice == null ? settings.voiceName == null : settings.voiceName == voice.name;
    return ListTile(
      leading: Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
      title: Text(voice == null ? 'Best on this phone' : voice.label),
      subtitle: voice == null && best != null ? Text(best.label) : null,
      selected: selected,
      onTap: () => Navigator.pop(sheet, voice?.name ?? ''),
    );
  }
}
