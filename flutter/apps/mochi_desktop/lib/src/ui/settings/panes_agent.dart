// Settings › Agent (the Mac's AgentSettingsView): Mochi keeps an eye on Gmail, Google Calendar and Notion through the
// connectors in your own Claude account, and tells you what matters. The main switch, the connections, how often, quiet
// hours and the morning briefing, who and how it tells you, VIPs, what it can see, Mochi Cloud's settings (W5), and what it
// told you with Done on each note. Every control is a real widget: Tab reaches it, Space or Enter works it, and each row
// reads as one thing to a screen reader.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/agent/agent_command.dart';
import '../../core/agent/agent_controller.dart';
import '../../core/agent/agent_settings.dart';
import '../../core/hotkeys.dart';
import '../../core/notifications.dart' show QuietHours;
import '../../platform/time_zone.dart';
import 'panes_claude.dart' show ago;
import 'panes_phones.dart' show phoneNames;
import 'settings_kit.dart';

typedef _Source = AgentSource;

class AgentPane extends StatefulWidget {
  const AgentPane({super.key, required this.host, this.timeZone});

  final SettingsHost host;

  /// This PC's time zone for Mochi Cloud (tests); TimeZoneName.current otherwise.
  final String Function()? timeZone;

  @override
  State<AgentPane> createState() => _AgentPaneState();
}

class _AgentPaneState extends State<AgentPane> {
  bool _copying = false;

  /// What the last Copy Cloud Settings said, and whether it worked.
  ({bool ok, String text})? _said;

  final TextEditingController _vip = TextEditingController();

  AgentController get _agent => widget.host.desktop.agent;
  AgentSettings get _settings => widget.host.desktop.settings.agent;

  @override
  void initState() {
    super.initState();
    // Each look is a short Haiku run, so only while the agent is on and nothing is known yet: nothing runs while it's off.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _settings.enabled && _agent.connections.isEmpty && !_agent.busy) unawaited(_agent.refreshConnections());
    });
  }

  @override
  void dispose() {
    _vip.dispose();
    super.dispose();
  }

  void _change(AgentSettings Function(AgentSettings settings) change) => widget.host.desktop.settings.agent = change(_settings);

  void _addVip() {
    final vip = _vip.text.trim();
    _vip.clear();
    if (vip.isEmpty || _settings.vips.any((each) => each.toLowerCase() == vip.toLowerCase())) return;
    _change((settings) => settings.copyWith(vips: [...settings.vips, vip]));
  }

  /// Copy Cloud Settings (the Mac's AgentController.copyCloudLinkSettings): Mochi Cloud joins this PC's room (in place
  /// of the one it had: that one is removed, after you say so), and its environment's settings go on the clipboard.
  Future<void> _copy() async {
    final link = widget.host.desktop.link;
    final pet = widget.host.pet;
    if (link.clouds.isNotEmpty) {
      final confirmed = await confirmAction(
        context,
        title: 'Replace Mochi Cloud’s settings?',
        message:
            'Mochi Cloud gets new settings for this PC’s link, and the ones it has now stop working: until you paste the '
            'new ones into its environment at claude.ai/code, it can’t reach your phones.',
        confirm: 'Replace',
      );
      if (!confirmed || !mounted) return;
    }
    setState(() {
      _copying = true;
      _said = null;
    });
    ({bool ok, String text}) said;
    try {
      final joined = await link.joinCloud();
      final zone = (widget.timeZone ?? TimeZoneName.current)();
      await Clipboard.setData(ClipboardData(text: joined.environment(timeZone: zone)));
      said = (
        ok: true,
        text:
            'Copied. On claude.ai/code, open your Mochi Cloud environment › Environment variables and paste it in'
            '${joined.replaced.isEmpty ? '' : ', in place of the MOCHI_LINK_ lines it had (the old ones no longer work)'}. '
            'It holds a key to your link, so don’t share it.',
      );
    } on LinkPairingException catch (error) {
      said = (ok: false, text: error.message);
    } on Object catch (error) {
      said = (ok: false, text: '$pet couldn’t reach Mochi Link (${error.runtimeType}). Check this PC’s connection and try again.');
    }
    if (!mounted) return;
    setState(() {
      _copying = false;
      _said = said;
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final desktop = host.desktop;
    return ListenableBuilder(
      listenable: Listenable.merge([desktop.link, desktop.settings, desktop.agent]),
      builder: (context, _) {
        final settings = desktop.settings.agent;
        final agent = desktop.agent;
        final pet = host.pet;
        final phones = phoneNames(desktop.link);
        final pair = phones == LinkPeerNames.yourPhones;
        // "My phones" until one is paired; then the phones by name, never "iPhone" for an Android.
        final theirs = pair ? 'my phones' : phones;
        final ask = desktop.settings.shortcut(MochiShortcut.ask);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              children: [
                ToggleRow(
                  title: 'Let $pet keep an eye on my mail, calendar and tasks',
                  subtitle:
                      'Every few minutes $pet asks Claude Haiku what’s new in Gmail, Google Calendar and Notion, using the '
                      'connectors in your own Claude account, and tells you what matters. Its checks only read: nothing is ever '
                      'sent, changed or deleted. It runs on your Claude subscription, with no API key.',
                  value: settings.enabled,
                  onChanged: (value) => _change((settings) => settings.copyWith(enabled: value)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Connections',
              footer: settings.enabled
                  ? 'Connect… opens your Claude account’s connectors in the browser, where you choose which account to connect. '
                        '$pet notices when you’re back. Checking is a short Haiku run that only looks for the connectors.'
                  : 'Connect… opens your Claude account’s connectors in the browser, where you choose which account to connect. '
                        'Come back and press Check Connections: nothing runs by itself while the agent is off. Checking is a short '
                        'Haiku run that only looks for the connectors.',
              children: [
                for (final source in _Source.values)
                  _SourceRow(
                    source: source,
                    state: agent.connections[source],
                    checking: agent.checkingConnections,
                    watched: settings.watches(source),
                    onWatch: (on) => _change((settings) => settings.watching(source, on)),
                    onConnect: () => unawaited(agent.connect()),
                  ),
                ActionsRow(
                  children: [
                    OutlinedButton(
                      onPressed: agent.busy ? null : () => unawaited(agent.refreshConnections(forgetNotes: true)),
                      child: const Text('Check Connections'),
                    ),
                    if (agent.checkingConnections) const _Spinner(label: 'Checking the connections'),
                  ],
                ),
              ],
            ),
            SettingsGroup(
              title: 'How often',
              footer:
                  'Each check is one short Haiku run, about half a minute. You can also ask $pet “what’s pending?” in Ask $pet'
                  '${ask == null ? '' : ' (${ask.label})'}.',
              children: [
                MenuRow<int>(
                  label: 'Check every',
                  value: settings.intervalMinutes,
                  items: [for (final minutes in _with(AgentSettings.intervals, settings.intervalMinutes)) (minutes, '$minutes minutes')],
                  onChanged: (value) => _change((settings) => settings.copyWith(intervalMinutes: value)),
                ),
                ToggleRow(
                  title: 'Quiet hours',
                  subtitle: settings.quietHours.enabled
                      ? 'No checks from ${QuietHours.format(settings.quietHours.startMinute)} to ${QuietHours.format(settings.quietHours.endMinute)}.'
                      : 'Check around the clock.',
                  value: settings.quietHours.enabled,
                  onChanged: (value) => _change((settings) => settings.copyWith(quietHours: settings.quietHours.copyWith(enabled: value))),
                ),
                MenuRow<int>(
                  label: 'Quiet from',
                  value: settings.quietHours.startMinute,
                  items: _times(settings.quietHours.startMinute),
                  onChanged: settings.quietHours.enabled
                      ? (value) => _change((settings) => settings.copyWith(quietHours: settings.quietHours.copyWith(startMinute: value)))
                      : null,
                ),
                MenuRow<int>(
                  label: 'Quiet until',
                  value: settings.quietHours.endMinute,
                  items: _times(settings.quietHours.endMinute),
                  onChanged: settings.quietHours.enabled
                      ? (value) => _change((settings) => settings.copyWith(quietHours: settings.quietHours.copyWith(endMinute: value)))
                      : null,
                ),
                ToggleRow(
                  title: 'Morning briefing',
                  subtitle: 'A short round-up of your day, once a morning.',
                  value: settings.briefingEnabled,
                  onChanged: (value) => _change((settings) => settings.copyWith(briefingEnabled: value)),
                ),
                MenuRow<int>(
                  label: 'Briefing at',
                  value: settings.briefingMinute,
                  items: _times(settings.briefingMinute, step: 15),
                  onChanged: settings.briefingEnabled ? (value) => _change((settings) => settings.copyWith(briefingMinute: value)) : null,
                ),
              ],
            ),
            SettingsGroup(
              title: 'Tell me',
              children: [
                ToggleRow(
                  title: 'In $pet’s speech bubble',
                  value: settings.tellInBubble,
                  onChanged: (value) => _change((settings) => settings.copyWith(tellInBubble: value)),
                ),
                ToggleRow(
                  title: 'With a dot on $pet and the tray icon',
                  value: settings.tellWithBadge,
                  onChanged: (value) => _change((settings) => settings.copyWith(tellWithBadge: value)),
                ),
                ToggleRow(
                  title: 'On $theirs: notifications and a “Waiting for you” card in Mochi',
                  value: settings.tellPhone,
                  onChanged: (value) => _change((settings) => settings.copyWith(tellPhone: value)),
                ),
                ToggleRow(
                  title: 'Keep newsletters and automated mail off $theirs',
                  value: settings.phoneSkipsLowPriority,
                  onChanged: settings.tellPhone ? (value) => _change((settings) => settings.copyWith(phoneSkipsLowPriority: value)) : null,
                ),
                if (settings.tellPhone && pair)
                  const NoteRow(icon: Icons.phone_iphone_rounded, text: 'Pair a phone in Settings › Phones › Mochi Link to get these on your phones.'),
              ],
            ),
            SettingsGroup(
              title: 'VIPs',
              footer: settings.vips.isEmpty
                  ? 'Add the people whose mail matters most. Once you have VIPs, only their mail (and meetings) gets the dot '
                        'and rings $theirs; other mail waits quietly on the card and in the briefings.'
                  : 'Only mail from these people (and meetings) rings; other mail waits quietly on the card and in the briefings.',
              children: [
                for (final vip in settings.vips)
                  Padding(
                    padding: rowPadding,
                    child: Row(
                      children: [
                        // The name reads on its own; the remove button is its own stop for the keyboard and a screen reader.
                        Expanded(
                          child: MergeSemantics(
                            child: Row(
                              children: [
                                ExcludeSemantics(child: Icon(Icons.star_rounded, size: 18, color: context.palette.warning)),
                                const SizedBox(width: Space.s + 2),
                                Expanded(child: Text(vip, style: context.type.subheadline)),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove $vip',
                          icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
                          onPressed: () => _change((settings) => settings.copyWith(vips: [for (final each in settings.vips) if (each != vip) each])),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: rowPadding,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _vip,
                          onSubmitted: (_) => _addVip(),
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(labelText: 'Name, email address or @company.com', isDense: true),
                        ),
                      ),
                      const SizedBox(width: Space.s),
                      ListenableBuilder(
                        listenable: _vip,
                        builder: (context, _) => OutlinedButton(onPressed: _vip.text.trim().isEmpty ? null : _addVip, child: const Text('Add')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: 'What $pet can see',
              footer:
                  'Claude reads these through your connectors and hands $pet a short summary. This PC keeps only what $pet told '
                  'you (below) for two weeks; your mail and pages stay where they are.',
              children: [
                for (final source in _Source.values)
                  MergeSemantics(
                    child: Padding(
                      padding: rowPadding,
                      child: Row(
                        children: [
                          ExcludeSemantics(
                            child: Icon(_icon(source), size: 18, color: settings.watches(source) ? context.palette.ink : context.palette.inkSecondary),
                          ),
                          const SizedBox(width: Space.s + 2),
                          Expanded(
                            child: Text(
                              source.whatMochiSees,
                              style: context.type.subheadline.copyWith(color: settings.watches(source) ? null : context.palette.inkSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            _cloudGroup(context),
            SettingsGroup(
              title: 'From the Mac',
              children: const [
                SoonRow(
                  title: 'Mark the email read in Gmail',
                  detail: 'When you mark something done, also remove Gmail’s unread mark from that email.',
                ),
                SoonRow(
                  title: 'Mochi Cloud’s Check now and Mochi Watcher',
                  detail: 'A Fire URL and token so a phone’s “Check now” can ask the cloud, and a small script that wakes it for real news.',
                ),
              ],
            ),
            _recentGroup(context, settings, agent),
          ],
        );
      },
    );
  }

  /// Check Now, Briefing Now, Forget, and what Mochi told you with Done on each.
  Widget _recentGroup(BuildContext context, AgentSettings settings, AgentController agent) {
    final pet = widget.host.pet;
    final p = context.palette;
    final now = widget.host.now;
    final idle = settings.enabled && !agent.busy;
    final result = agent.lastResult, error = agent.lastError, looked = agent.lastRunAt;
    return SettingsGroup(
      title: 'Recent',
      children: [
        ActionsRow(
          children: [
            FilledButton(onPressed: idle ? () => unawaited(agent.checkNow()) : null, child: const Text('Check Now')),
            OutlinedButton(onPressed: idle ? () => unawaited(agent.briefNow()) : null, child: const Text('Briefing Now')),
            Tooltip(
              message: 'Forget what $pet has told you, so the next check reports everything again',
              child: TextButton(onPressed: idle ? agent.forgetNews : null, child: const Text('Forget')),
            ),
            if (agent.running) const _Spinner(label: 'Looking'),
          ],
        ),
        if (!settings.enabled) NoteRow(icon: Icons.power_settings_new_rounded, text: 'Turn on $pet’s agent above to check.'),
        if (result != null)
          Semantics(liveRegion: true, child: NoteRow(icon: Icons.chat_bubble_outline_rounded, text: result)),
        if (error != null)
          Semantics(
            liveRegion: true,
            child: NoteRow(icon: Icons.warning_amber_rounded, text: error, tint: p.warning),
          ),
        if (looked != null) TextRow('Last looked ${ago(looked, now)}', secondary: true),
        for (final note in agent.notes.take(12)) _NoteTile(note: note, done: agent.isDone(note.id), onDone: () => agent.markDone(note)),
        if (agent.notes.isEmpty) const TextRow('Nothing yet.', secondary: true),
      ],
    );
  }

  /// Mochi Cloud's settings (W5): unchanged.
  Widget _cloudGroup(BuildContext context) {
    final host = widget.host;
    final p = context.palette;
    final link = host.desktop.link;
    final opener = host.desktop.opener;
    final now = host.now;
    final said = _said;
    final clouds = link.devices.where((peer) => peer.role == 'cloud' || peer.linkPlatform == LinkPlatform.cloud).toList();
    final names = phoneNames(link);
    return SettingsGroup(
      title: 'Mochi Cloud',
      footer:
          'Mochi Cloud is an hourly Claude task in Anthropic’s cloud (claude.ai/code, with the mochi-cloud repository) '
          'that checks your mail, calendar and pages while your computers are off, and pushes the news to '
          '${names == LinkPeerNames.yourPhones ? 'the phones paired with this PC' : names} through Mochi Link. It joins this PC’s '
          'link as a device of its own; copying its settings again replaces it.',
      children: [
        if (clouds.isEmpty)
          StatusRow(title: 'Mochi Cloud', ok: false, detail: link.paired ? 'Not in this PC’s link' : 'Pair a phone first')
        else
          for (final cloud in clouds)
            StatusRow(
              title: cloud.name ?? 'Mochi Cloud',
              ok: cloud.lastSeenTime != null,
              icon: Icons.cloud_outlined,
              detail: cloud.lastSeenTime == null ? 'Hasn’t checked in yet' : 'Last check ${ago(cloud.lastSeenTime!, now)}',
            ),
        ActionsRow(
          children: [
            FilledButton.icon(
              onPressed: link.paired && !_copying ? () => unawaited(_copy()) : null,
              icon: _copying
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy Cloud Settings'),
            ),
            OutlinedButton.icon(
              onPressed: opener == null ? null : () => opener.open(Uri.parse('https://claude.ai/code')),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Open claude.ai/code'),
            ),
          ],
        ),
        if (!link.paired)
          const NoteRow(icon: Icons.link_rounded, text: 'Pair a phone in Settings › Phones first: Mochi Cloud joins the same link.'),
        if (said != null)
          Semantics(
            liveRegion: true,
            child: NoteRow(
              icon: said.ok ? Icons.content_paste_rounded : Icons.warning_amber_rounded,
              text: said.text,
              tint: said.ok ? p.success : p.warning,
            ),
          ),
      ],
    );
  }

  static IconData _icon(_Source source) => switch (source) {
    _Source.gmail => Icons.mail_outline_rounded,
    _Source.calendar => Icons.calendar_today_rounded,
    _Source.notion => Icons.checklist_rounded,
  };

  /// [choices] and, if it's not one of them (an older file), [current].
  static List<int> _with(List<int> choices, int current) => ({...choices, current}.toList()..sort());

  /// Every [step] minutes of the day (and [current], whatever an older file has).
  static List<(int, String)> _times(int current, {int step = 30}) => [
    for (final minute in ({for (var minute = 0; minute < 24 * 60; minute += step) minute, current}.toList()..sort())) (minute, QuietHours.format(minute)),
  ];
}

/// One source: its icon, name and state, Connect… when it isn't connected, and whether Mochi watches it.
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.state,
    required this.checking,
    required this.watched,
    required this.onWatch,
    required this.onConnect,
  });

  final _Source source;
  final AgentConnection? state;
  final bool checking;
  final bool watched;
  final ValueChanged<bool> onWatch;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final connected = state == AgentConnection.connected;
    final status = state?.title ?? (checking ? 'Checking…' : 'Unknown');
    final color = state == null ? p.inkSecondary : (connected ? p.success : p.warning);
    return Padding(
      padding: rowPadding,
      child: Wrap(
        spacing: Space.s,
        runSpacing: Space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          MergeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(child: Icon(_AgentPaneState._icon(source), size: 18, color: p.ink)),
                const SizedBox(width: Space.s + 2),
                Flexible(child: Text(source.title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600))),
                const SizedBox(width: Space.s),
                Icon(connected ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 16, color: color),
                const SizedBox(width: Space.xs),
                Flexible(child: Text(status, style: context.type.footnote.copyWith(color: color))),
              ],
            ),
          ),
          if (!connected) TextButton(onPressed: onConnect, child: Text('Connect ${source.title}…')),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(value: watched, semanticLabel: 'Watch ${source.title}', onChanged: (on) => onWatch(on ?? false)),
              ExcludeSemantics(child: Text('Watch', style: context.type.footnote)),
            ],
          ),
        ],
      ),
    );
  }
}

/// One thing Mochi told you: who or what, the subject and the gist, when, and Done.
class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, required this.done, required this.onDone});

  final AgentNote note;
  final bool done;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final time = DateTime.fromMillisecondsSinceEpoch((note.at * 1000).round());
    final clock = '${time.hour % 12 == 0 ? 12 : time.hour % 12}:${time.minute.toString().padLeft(2, '0')} ${time.hour < 12 ? 'AM' : 'PM'}';
    final dim = done ? 0.55 : 1.0;
    return Padding(
      padding: rowPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MergeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    done ? Icons.check_circle_rounded : _AgentPaneState._icon(note.source),
                    size: 18,
                    color: done ? p.success : (note.important ? p.warning : p.inkSecondary),
                  ),
                ),
                const SizedBox(width: Space.s + 2),
              ],
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: dim,
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${note.vip == true ? '★ ' : ''}${note.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600, decoration: done ? TextDecoration.lineThrough : null),
                    ),
                    if (note.subject != null) Text(note.subject!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.subheadline),
                    Text(note.detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.caption),
                    Text(done ? '$clock · done' : clock, style: context.type.caption),
                  ],
                ),
              ),
            ),
          ),
          if (!done)
            Semantics(
              button: true,
              label: 'Mark ${note.title} done',
              excludeSemantics: true,
              child: Tooltip(
                message: 'Take it off “Waiting for you” here and on your phones',
                child: TextButton(onPressed: onDone, child: const Text('Done')),
              ),
            ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
  );
}
