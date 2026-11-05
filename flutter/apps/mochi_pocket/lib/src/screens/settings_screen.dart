import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/app_settings.dart';
import '../model/pocket_model.dart';
import '../services/alert_notifier.dart';
import '../theme.dart';
import '../voice/mochi_voice.dart';
import '../voice/updates_reader.dart';
import '../widgets/clay.dart';
import 'home_screen.dart' show connectionPill;

/// The app's version, sent in the relay `hello` and shown here.
const String appVersion = '0.1.0';

/// Settings: Mochi Link (who this phone is paired with, the relay and the Mac's presence, Unpair), notifications,
/// appearance, and Mochi's voice (iOS/MochiPocket/PocketLink.swift `LinkCard`, PocketSettingsView).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.model, required this.notifier, required this.settings, required this.reader});

  final PocketModel model;
  final AlertNotifier notifier;
  final AppSettings settings;
  final UpdatesReader reader;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool? _notificationsOn;
  late Future<List<VoiceInfo>> _voices = widget.reader.voices();

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
            const SizedBox(height: Space.l),
            _appearance(),
            const SizedBox(height: Space.l),
            _voice(),
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

  /// Whether alerts reach this phone while Mochi is closed, and if not, why.
  Widget _pushStatus() {
    final p = context.palette;
    final (icon, tint, headline, detail) = switch (model.pushStatus) {
      PushStatus.registered => (
        Icons.notifications_active_rounded,
        p.success,
        'Notifications: on (Firebase)',
        "Claude's finished turns, approvals and news from your Mac reach this phone even when Mochi is closed. "
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
      PushStatus.off => (Icons.notifications_off_rounded, p.inkSecondary, 'Notifications: off', 'Pair with your Mac to get its alerts.'),
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
