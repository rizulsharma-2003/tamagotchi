// Settings › Claude: Claude Code (the hooks, consent first, with backups), Assistant (Ask Mochi) and Agent (the Mac's
// Gmail, Calendar and Notion watcher, which isn't on Windows yet). The Mac's ClaudeSettings, AssistantSettingsView and
// AgentSettingsView.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_wire/mochi_wire.dart';

import '../../core/hotkeys.dart';
import '../../desktop.dart';
import '../../platform/time_zone.dart';
import 'panes_phones.dart' show phoneNames;
import 'settings_kit.dart';
import 'settings_tabs.dart';
import 'shortcut_row.dart';

/// "5 min ago" for a moment.
String ago(DateTime then, DateTime now) => relativeTime(then.millisecondsSinceEpoch / 1000, now: now);

// MARK: - Claude Code

class ClaudeCodePane extends StatefulWidget {
  const ClaudeCodePane({super.key, required this.host});

  final SettingsHost host;

  @override
  State<ClaudeCodePane> createState() => _ClaudeCodePaneState();
}

class _ClaudeCodePaneState extends State<ClaudeCodePane> {
  late String? _claude = widget.host.desktop.locateClaude();
  String? _preview;
  bool _showPreview = false;

  MochiDesktop get desktop => widget.host.desktop;

  void _recheck() {
    desktop.hooks.refresh();
    setState(() => _claude = desktop.locateClaude());
  }

  Future<void> _connect() async {
    final hooks = desktop.hooks;
    final file = hooks.inspection?.settingsFile ?? hooks.settingsFile;
    final confirmed = await confirmAction(
      context,
      title: hooks.needsUpdate ? 'Update the Claude Code connection?' : 'Connect Claude Code?',
      message:
          'Mochi backs up $file, then adds its hooks. Your other settings and hooks stay exactly as they are. '
          'Sessions that are already open pick the hooks up when they restart.',
      confirm: 'Back Up and Connect',
    );
    if (confirmed) await hooks.connect();
  }

  Future<void> _disconnect() async {
    final confirmed = await confirmAction(
      context,
      title: 'Remove Mochi’s hooks?',
      message: 'Only Mochi’s own hook entries are taken out, after a backup. Everything else in your Claude Code settings stays.',
      confirm: 'Back Up and Remove',
      destructive: true,
    );
    if (confirmed) await desktop.hooks.disconnect();
  }

  String _diagnostics() {
    final hooks = desktop.hooks;
    final bridge = desktop.bridge;
    final sessions = desktop.sessions;
    return [
      'Mochi for Windows diagnostics',
      'Mochi $appVersion · hook helper ${HelperInfo.version} · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Claude Code: ${_claude == null ? 'not found' : 'found'}',
      'Hooks: ${hooks.inspection?.status.name ?? 'unknown'}${hooks.inspection?.hooksDisabled ?? false ? ' (disableAllHooks)' : ''}'
          '${hooks.inspection?.managedHooksOnly ?? false ? ' (managed hooks only)' : ''}',
      'Missing events: ${hooks.inspection?.missing.join(', ') ?? '-'}',
      'Helper: ${hooks.helperInstalled ? 'installed' : 'missing'}${hooks.bundledHelper == null ? ', not bundled' : ''}',
      'Bridge: ${bridge.listening ? 'listening on 127.0.0.1:${bridge.endpoint?.port}' : desktop.bridgeProblem.value ?? 'not listening'}',
      'Accepted ${bridge.accepted}, rejected ${bridge.rejected}, last rejection: ${bridge.lastRejection ?? 'none'}',
      'Late events ${sessions.lateEvents}, dropped ${sessions.droppedEvents}, sessions ${sessions.all.length}',
      'Last event: ${sessions.lastEventAt?.toIso8601String() ?? 'none since launch'}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.hooks, desktop.bridgeProblem]),
    builder: (context, _) {
      final p = context.palette;
      final host = widget.host;
      final hooks = desktop.hooks;
      final inspection = hooks.inspection;
      final bridge = desktop.bridge;
      final last = desktop.sessions.lastEventAt;
      final (connection, ok) = switch (inspection?.status) {
        HookStatus.installed => ('Connected', true),
        HookStatus.needsUpdate => ('Connected, but out of date', false),
        HookStatus.unreadable => ('Claude Code’s settings can’t be read', false),
        _ => ('Not connected', false),
      };
      final settingsFile = inspection?.settingsFile ?? hooks.settingsFile;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsGroup(
            title: 'Status',
            children: [
              StatusRow(title: 'Claude Code', ok: _claude != null, detail: _claude == null ? 'Not found: Mochi works without it' : 'Installed'),
              if (_claude != null) InfoRow(label: 'Found at', value: _claude!, selectable: true),
              StatusRow(title: 'Connection', ok: ok, detail: connection),
              StatusRow(
                title: 'Event bridge',
                ok: bridge.listening,
                detail: bridge.listening
                    ? 'Listening on this PC only (port ${bridge.endpoint?.port})'
                    : desktop.bridgeProblem.value ?? 'Starting…',
              ),
              StatusRow(
                title: 'Last event',
                ok: last != null,
                detail: last == null ? 'None since Mochi started' : ago(last, desktop.sessions.now),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Connection',
            children: [
              TextRow(
                'Mochi uses Claude Code’s documented hooks. Each hook runs a tiny helper that passes a sanitized summary of '
                'the event to Mochi on this PC, then exits within milliseconds. It never blocks Claude, never prints into '
                'your session and never changes what Claude does.',
              ),
              InfoRow(label: 'Settings file', value: settingsFile, selectable: true),
              if ((inspection?.otherHookCount ?? 0) > 0)
                NoteRow(
                  icon: Icons.verified_user_outlined,
                  text:
                      '${inspection!.otherHookCount} hook${inspection.otherHookCount == 1 ? '' : 's'} from you or other tools '
                      '${inspection.otherHookCount == 1 ? 'is' : 'are'} kept as ${inspection.otherHookCount == 1 ? 'it is' : 'they are'}.',
                ),
              if (inspection?.hooksDisabled ?? false)
                NoteRow(
                  text: 'Your settings have "disableAllHooks": true, so Claude Code runs no hooks until you change it.',
                  icon: Icons.warning_amber_rounded,
                  tint: p.warning,
                ),
              if (inspection?.managedHooksOnly ?? false)
                NoteRow(
                  text: 'Your organisation’s managed settings allow only its own hooks; ask your administrator.',
                  icon: Icons.warning_amber_rounded,
                  tint: p.warning,
                ),
              if (hooks.problem != null)
                NoteRow(text: hooks.problem!, icon: Icons.error_outline_rounded, tint: p.danger, textColor: p.danger),
              if (hooks.lastBackup != null) NoteRow(text: 'Backup: ${hooks.lastBackup}', icon: Icons.history_rounded),
              ActionsRow(
                children: [
                  if (!hooks.connected)
                    FilledButton(
                      onPressed: hooks.busy ? null : _connect,
                      child: Text(hooks.needsUpdate ? 'Update Connection…' : 'Connect Claude Code…'),
                    ),
                  if (inspection != null && inspection.status != HookStatus.notInstalled)
                    OutlinedButton(
                      onPressed: hooks.busy ? null : _disconnect,
                      style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                      child: const Text('Remove Mochi’s Hooks…'),
                    ),
                  TextButton(
                    onPressed: () => setState(() {
                      _showPreview = !_showPreview;
                      if (_showPreview) _preview = hooks.preview();
                    }),
                    child: Text(_showPreview ? 'Hide Changes' : 'Preview Changes'),
                  ),
                ],
              ),
              if (_showPreview)
                Padding(
                  padding: rowPadding,
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    width: double.infinity,
                    padding: const EdgeInsets.all(Space.s),
                    decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.tile)),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _preview ?? 'The change can’t be worked out (see above).',
                        style: context.type.caption.copyWith(fontFamily: 'monospace', color: p.ink),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SettingsGroup(
            title: 'Hook helper',
            footer: 'The helper always exits successfully and prints nothing, even if Mochi was removed.',
            children: [
              StatusRow(
                title: 'Helper ${HelperInfo.version}',
                ok: hooks.helperInstalled,
                detail: hooks.helperInstalled ? 'In Mochi’s folder' : 'Copied in when you connect',
              ),
              InfoRow(label: 'Path', value: desktop.paths.installedHelper, selectable: true),
              if (hooks.bundledHelper == null)
                NoteRow(
                  text: 'This copy of Mochi has no helper beside it. Reinstalling Mochi fixes it.',
                  icon: Icons.warning_amber_rounded,
                  tint: p.warning,
                ),
            ],
          ),
          SettingsGroup(
            title: 'Troubleshooting',
            children: [
              TextRow(
                '• Hooks are read when a Claude Code session starts: restart sessions that were open before you connected.\n'
                '• Type /hooks in Claude Code to see the entries (they run ${HelperInfo.executableName}).\n'
                '• While Mochi isn’t running, events wait in a small spool and arrive as “late” next time.\n'
                '• Events reach Mochi over 127.0.0.1 only, with a secret token that changes every launch.',
                secondary: true,
              ),
              InfoRow(
                label: 'Bridge statistics',
                value: 'accepted ${bridge.accepted} · rejected ${bridge.rejected}${bridge.lastRejection == null ? '' : ' · last: ${bridge.lastRejection}'}',
              ),
              ActionsRow(
                children: [
                  OutlinedButton(
                    onPressed: desktop.folders == null ? null : () => desktop.folders!.open(File(settingsFile).parent.path),
                    child: const Text('Show Settings File'),
                  ),
                  OutlinedButton(
                    onPressed: desktop.folders == null
                        ? null
                        : () {
                            BridgePaths.ensurePrivateDirectory(desktop.paths.backupsDirectory);
                            desktop.folders!.open(desktop.paths.backupsDirectory);
                          },
                    child: const Text('Show Backups'),
                  ),
                  OutlinedButton(onPressed: () => copyText(context, _diagnostics(), said: 'Diagnostics copied'), child: const Text('Copy Diagnostics')),
                  TextButton(onPressed: _recheck, child: const Text('Re-check')),
                ],
              ),
            ],
          ),
          SettingsGroup(
            title: 'Build and test results',
            children: [
              TextRow(
                'A finished turn says nothing about builds or tests. Report real results from your own scripts and they '
                'show on the session’s card in Mochi’s window:',
                secondary: true,
              ),
              _CommandSnippet(text: '"${desktop.paths.installedHelper}" report test passed'),
              _CommandSnippet(text: '"${desktop.paths.installedHelper}" report build failed --label "CI"'),
              SoonRow(
                title: 'A celebration when they pass',
                detail: 'On a Mac, ${host.pet} cheers for a passing build or test. Here the result shows on the card.',
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _CommandSnippet extends StatelessWidget {
  const _CommandSnippet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: rowPadding,
      child: Container(
        padding: const EdgeInsets.only(left: Space.s),
        decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.tile)),
        child: Row(
          children: [
            Expanded(child: SelectableText(text, style: context.type.caption.copyWith(fontFamily: 'monospace', color: p.ink))),
            IconButton(
              tooltip: 'Copy command',
              onPressed: () => copyText(context, text, said: 'Command copied'),
              icon: const Icon(Icons.copy_rounded, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

// MARK: - Assistant

class AssistantPane extends StatefulWidget {
  const AssistantPane({super.key, required this.host});

  final SettingsHost host;

  @override
  State<AssistantPane> createState() => _AssistantPaneState();
}

class _AssistantPaneState extends State<AssistantPane> {
  late final String? _claude = widget.host.desktop.locateClaude();

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final settings = host.desktop.settings;
    final pet = host.pet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Ask $pet',
          children: [
            TextRow(
              'Type to $pet in Mochi’s window${settings.shortcut(MochiShortcut.ask) == null ? '' : ', or press ${settings.shortcut(MochiShortcut.ask)!.label} anywhere'}. '
              'Quick commands like “status”, “open youtube” or “focus for 25 minutes” are answered on the spot; anything '
              'else goes to Claude, which can search the web, open links and, with your OK, message your Claude sessions.',
            ),
            ShortcutRow(
              desktop: host.desktop,
              shortcut: MochiShortcut.ask,
              title: 'Shortcut',
              subtitle:
                  'Opens Mochi’s window with the question box ready, from any app; press it again to close it. The Mac '
                  'uses ⌥Space, which Windows keeps for its window menu.',
            ),
            ActionsRow(children: [FilledButton(onPressed: host.onHome, child: Text('Open Ask $pet'))]),
          ],
        ),
        SettingsGroup(
          title: 'Claude',
          children: [
            ChoiceRow<String>(
              label: 'Helper model',
              selected: settings.model,
              onSelected: (model) => settings.model = model,
              choices: const [('haiku', 'Fast (Haiku)', Icons.bolt_rounded), ('sonnet', 'Smart (Sonnet)', Icons.psychology_rounded)],
            ),
            NoteRow(
              icon: _claude == null ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
              text: _claude == null
                  ? 'Claude Code wasn’t found on this PC. Install it from claude.com/claude-code to ask $pet anything beyond quick commands.'
                  : 'Uses your Claude Code login, no API key. Each request uses a little of your plan, like a short prompt.',
            ),
          ],
        ),
        SettingsGroup(
          title: 'Claude sessions',
          children: [
            ToggleRow(
              title: 'Let $pet message my Claude sessions',
              subtitle:
                  'Ask $pet to tell a session what to do next. Every message shows on a card with the session and the whole '
                  'text, and only goes after you press Send; anything else (Don’t send, Escape, no answer in two minutes) '
                  'means it isn’t sent. It reaches the session through Claude Code’s own session messaging, never by typing '
                  'into a window.',
              value: settings.messageSessions,
              onChanged: (value) => settings.messageSessions = value,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Files, links and your screen',
          children: [
            TextRow(
              'Drop a file, some text or a link on $pet (on the taskbar, or on the question box in Mochi’s window) and ask '
              'about it. What you drop shows in the question box first, and nothing leaves this PC until you press Send. '
              'A file goes to Claude Code, which reads only the files you dropped for that one question.',
            ),
            ToggleRow(
              title: 'Let me show $pet my screen',
              subtitle:
                  'Adds a “What’s on my screen?” button to the question box. It takes one picture of the window you were '
                  'using before Mochi came up (never the whole screen, never by itself), shows it to you, and only goes '
                  'after you press Send. The picture is deleted when the question is done. Off at first.',
              value: settings.showScreen,
              onChanged: (value) => settings.showScreen = value,
            ),
            ToggleRow(
              title: 'Let Mochi use my PC',
              subtitle: 'Open apps and links, bring windows forward, music and volume',
              value: settings.pcControl,
              onChanged: (value) => settings.pcControl = value,
            ),
          ],
        ),
        SettingsGroup(
          title: 'From your phones',
          children: [
            StatusRow(
              title: 'Requests from your phones',
              ok: settings.acceptCommands,
              detail: settings.acceptCommands ? 'Run here, like Ask $pet' : 'Turned off',
            ),
            ActionsRow(
              children: [PaneLink(host: host, tab: SettingsTab.phones)],
            ),
          ],
        ),
        SettingsGroup(
          title: 'From the Mac',
          children: [
            SoonRow(title: 'Talking and spoken answers', detail: 'Hold the shortcut to talk; $pet reads answers aloud.'),
            SoonRow(title: 'Controlling this PC', detail: 'Opening apps, pressing music keys and bringing a window forward.'),
          ],
        ),
        SettingsGroup(
          title: 'Privacy',
          children: [
            TextRow(
              'What you ask goes to Claude (Anthropic) like any prompt, with the names and states of your Claude sessions. '
              '$pet keeps the conversation in memory only (nothing is saved) and stops its helper Claude after 10 quiet '
              'minutes. The helper can search the web, open https links, run $pet’s tricks and, only after your Send, message a '
              'Claude session. It can read only the files you drop on $pet (or the one window you show it) for that one question, '
              'and can’t run commands or change anything else on this PC. Without a helper tool '
              'or a native Claude Code, $pet answers with a one-off web-search-only claude -p.',
              secondary: true,
            ),
          ],
        ),
      ],
    );
  }
}

// MARK: - Agent

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
    final p = context.palette;
    final pet = host.pet;
    final link = host.desktop.link;
    final opener = host.desktop.opener;
    final now = host.now;
    final said = _said;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final clouds = link.devices.where((peer) => peer.role == 'cloud' || peer.linkPlatform == LinkPlatform.cloud).toList();
        final names = phoneNames(link);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              children: [
                Padding(
                  padding: rowPadding,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SettingsIcon.of(SettingsTab.agent, size: 36),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: Space.s,
                              runSpacing: Space.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text('The agent is coming to Windows', style: context.type.headline),
                                Tag(text: SoonRow.tag, icon: Icons.schedule_rounded, tint: p.inkSecondary),
                              ],
                            ),
                            const SizedBox(height: Space.xs),
                            Text(
                              'On a Mac, every few minutes $pet asks Claude Haiku what’s new in Gmail, Google Calendar and '
                              'Notion, using the connectors in your own Claude account, and tells you what matters: in a speech '
                              'bubble, on the menu bar and on your phones. Its checks only read; nothing is sent or deleted. '
                              'It runs on your Claude subscription, with no API key. This PC doesn’t run those checks yet, '
                              'but Mochi Cloud can (below).',
                              style: context.type.footnote,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SettingsGroup(
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
            ),
            SettingsGroup(
              title: 'From the Mac',
              children: [
                SoonRow(title: 'Checks and connections', detail: 'Gmail, Google Calendar and Notion, every 5 to 60 minutes, with quiet hours.'),
                SoonRow(title: 'Morning briefing', detail: 'A short round-up of your day at the time you choose.'),
                SoonRow(title: 'VIPs', detail: 'Only mail from the people who matter most rings your phones.'),
                SoonRow(title: 'Marking things done', detail: 'Tick something off on a phone and it leaves every device; optionally marks the email read.'),
              ],
            ),
          ],
        );
      },
    );
  }
}
