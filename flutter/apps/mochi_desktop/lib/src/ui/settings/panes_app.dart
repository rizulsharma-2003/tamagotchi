// Settings › App: Privacy (what leaves this PC, after docs/PRIVACY.md), Developer (diagnostics, never secrets) and
// About (version, links, licences, uninstalling).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_wire/mochi_wire.dart';

import '../../desktop.dart';
import '../../update/updater.dart';
import 'previews.dart';
import 'settings_kit.dart';
import 'settings_tabs.dart';

// MARK: - Privacy

class PrivacyPane extends StatelessWidget {
  const PrivacyPane({super.key, required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final desktop = host.desktop;
    final settings = desktop.settings;
    final link = desktop.link;
    final pet = host.pet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'What leaves this PC',
          footer: 'There’s no account, analytics or server of Mochi’s own. Nothing else leaves this PC.',
          children: [
            _Point(
              icon: Icons.code_rounded,
              title: 'Claude Code',
              text:
                  'Ask $pet and Claude’s summaries run claude -p with your own Claude Code login: what you ask (and, with '
                  'summaries on, Claude’s closing message) goes to Anthropic like any prompt.',
            ),
            _Point(
              icon: Icons.hub_outlined,
              title: 'Your Mochi Link relay${link.paired || desktop.installer.installed ? '' : ' (not in use: no phone is paired)'}',
              text:
                  'Phones: only once you pair one. Everything between this PC and your phones goes through it, sealed with '
                  'AES-256-GCM under a key only your devices have. The relay sees device ids, platforms, key names, sizes '
                  'and times; never what you said, Claude’s summaries, project or file names, or $pet’s look.',
            ),
            if (desktop.installer.installed)
              const _Point(
                icon: Icons.system_update_alt_rounded,
                title: 'Updates',
                text:
                    'At launch and every 6 hours this PC asks your relay whether there’s a newer Mochi. The relay sees this '
                    'PC’s device id and when it asked. Updates are signed: Mochi installs only what Mochi’s release key '
                    'signed, after checking the download’s checksum.',
              ),
          ],
        ),
        SettingsGroup(
          title: 'Sharing Claude’s summaries',
          children: [
            StatusRow(title: 'Claude’s summaries', ok: settings.shareSummaries, detail: settings.shareSummaries ? 'Shared with your phones' : 'Off'),
            TextRow(
              'With summaries on, the hook helper also passes Claude’s last message of each turn and the names of the files '
              'it changed. This PC summarizes them with Claude Haiku and sends the summary, project and file names to your '
              'phones, sealed. The message itself stays in memory and is gone when Mochi quits.',
              secondary: true,
            ),
            ActionsRow(children: [PaneLink(host: host, tab: SettingsTab.phones)]),
          ],
        ),
        SettingsGroup(
          title: 'What Mochi hears from Claude Code',
          children: [
            TextRow(
              'For each hook event the helper passes only the event’s name, the session id, the project folder’s name '
              '(and a one-way hash of its path), the tool’s name and kind, an exit code, whether a command looked like a '
              'build or test, and Claude Code’s short notification text. It reaches Mochi over 127.0.0.1 on this PC only, '
              'with a secret token that changes every launch.',
              secondary: true,
            ),
            TextRow(
              'Never: your prompts, tool inputs, file contents, command output, error text or transcripts.',
              secondary: true,
            ),
          ],
        ),
        SettingsGroup(
          title: 'What Mochi keeps on this PC',
          children: [
            InfoRow(label: 'Settings', value: desktop.paths.settingsFile, selectable: true),
            InfoRow(label: 'Events while Mochi was closed', value: desktop.paths.spoolFile, selectable: true),
            InfoRow(label: 'The link to your phones', value: link.vaultDescription),
            InfoRow(label: 'Claude Code backups', value: desktop.paths.backupsDirectory, selectable: true),
            const NoteRow(text: 'No history of your sessions is kept: they live in memory while Mochi runs.'),
            ActionsRow(
              children: [
                OutlinedButton(
                  onPressed: desktop.folders == null ? null : () => desktop.folders!.open(desktop.paths.home),
                  child: const Text('Show Mochi’s Folder'),
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'Never',
          children: const [
            _Never('Watches your keystrokes, reads the clipboard, records audio or captures the screen'),
            _Never('Reads your documents or source code'),
            _Never('Listens to the network: the event bridge answers this PC only'),
            _Never('Changes Claude Code’s settings without your Connect or Remove (each with a backup)'),
          ],
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Padding(
      padding: rowPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 18, color: context.palette.tint)),
          const SizedBox(width: Space.s + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(text, style: context.type.footnote),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Never extends StatelessWidget {
  const _Never(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => NoteRow(text: text, icon: Icons.block_rounded);
}

// MARK: - Developer

class DeveloperPane extends StatefulWidget {
  const DeveloperPane({super.key, required this.host});

  final SettingsHost host;

  @override
  State<DeveloperPane> createState() => _DeveloperPaneState();
}

class _DeveloperPaneState extends State<DeveloperPane> {
  MochiDesktop get desktop => widget.host.desktop;

  String get _strollFlag => '${desktop.paths.home}${Platform.pathSeparator}stroll-debug';

  ({int bytes, int lines}) _spool() {
    try {
      final file = File(desktop.paths.spoolFile);
      if (!file.existsSync()) return (bytes: 0, lines: 0);
      final text = file.readAsStringSync();
      return (bytes: text.length, lines: '\n'.allMatches(text).length);
    } on Object {
      return (bytes: 0, lines: 0);
    }
  }

  void _setStrollLog(bool on) {
    try {
      final flag = File(_strollFlag);
      if (on) {
        flag.parent.createSync(recursive: true);
        flag.writeAsStringSync('');
      } else if (flag.existsSync()) {
        flag.deleteSync();
      }
    } on FileSystemException {
      // Shown as it is below.
    }
    setState(() {});
  }

  String _diagnostics() {
    final bridge = desktop.bridge;
    final credentials = desktop.link.credentials;
    final spool = _spool();
    return [
      'Mochi for Windows $appVersion · hook helper ${HelperInfo.version}',
      'Bridge: ${bridge.listening ? '127.0.0.1:${bridge.endpoint?.port}' : 'not listening'} · accepted ${bridge.accepted} · rejected ${bridge.rejected}',
      'Spool: ${spool.lines} waiting (${spool.bytes} bytes) · late ${desktop.sessions.lateEvents} · dropped ${desktop.sessions.droppedEvents}',
      'Link: ${credentials == null ? 'not paired' : '${credentials.relay} · room ${credentials.room} · device ${credentials.device} (${credentials.role})'} · ${desktop.link.status.name}',
      for (final peer in desktop.link.devices) '  ${peer.device} · ${peer.role} · ${peer.platform ?? '?'} · ${peer.online ? 'online' : 'away'}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.link, desktop.bridgeProblem]),
    builder: (context, _) {
      final p = context.palette;
      final bridge = desktop.bridge;
      final spool = _spool();
      final credentials = desktop.link.credentials;
      final strollLog = File(_strollFlag).existsSync();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsGroup(
            title: 'Hook bridge',
            children: [
              StatusRow(
                title: 'Listening',
                ok: bridge.listening,
                detail: bridge.listening ? '127.0.0.1, port ${bridge.endpoint?.port}' : desktop.bridgeProblem.value ?? 'Not yet',
              ),
              InfoRow(label: 'Endpoint file', value: desktop.paths.bridgeFile, selectable: true),
              InfoRow(label: 'Accepted · rejected', value: '${bridge.accepted} · ${bridge.rejected}'),
              if (bridge.lastRejection != null) InfoRow(label: 'Last rejection', value: bridge.lastRejection!),
            ],
          ),
          SettingsGroup(
            title: 'Spool',
            footer: 'What the helper keeps while Mochi isn’t running; Mochi reads it at launch.',
            children: [
              InfoRow(label: 'Waiting', value: '${spool.lines} event${spool.lines == 1 ? '' : 's'} (${spool.bytes} bytes)'),
              InfoRow(label: 'Arrived late · dropped', value: '${desktop.sessions.lateEvents} · ${desktop.sessions.droppedEvents}'),
              InfoRow(label: 'File', value: desktop.paths.spoolFile, selectable: true),
            ],
          ),
          SettingsGroup(
            title: 'Mochi Link',
            footer: 'Ids only: the link’s key and this PC’s secret never show here.',
            children: [
              if (credentials == null)
                const StatusRow(title: 'Not paired', ok: false, detail: 'No link yet')
              else ...[
                InfoRow(label: 'Relay', value: credentials.relay, selectable: true),
                InfoRow(label: 'Link (room)', value: credentials.room, selectable: true, mono: true),
                InfoRow(label: 'This PC', value: '${credentials.device} · ${credentials.role}', selectable: true, mono: true),
                InfoRow(label: 'Status', value: desktop.link.status.name),
                for (final peer in desktop.link.devices)
                  InfoRow(label: LinkPeerNames.row(peer), value: '${peer.device} · ${peer.role}${peer.app == null ? '' : ' · app ${peer.app}'}', selectable: true, mono: true),
              ],
            ],
          ),
          SettingsGroup(
            title: 'Logs',
            children: [
              ToggleRow(
                title: 'Write the taskbar stroll’s log',
                subtitle: 'stroll.log in Mochi’s folder: where the taskbar is and what Mochi does there. Starts with Mochi’s next launch.',
                value: strollLog,
                onChanged: _setStrollLog,
              ),
              ActionsRow(
                children: [
                  OutlinedButton(
                    onPressed: desktop.folders == null ? null : () => desktop.folders!.open(desktop.paths.home),
                    child: const Text('Show Logs Folder'),
                  ),
                  OutlinedButton(onPressed: () => copyText(context, _diagnostics(), said: 'Diagnostics copied'), child: const Text('Copy Diagnostics')),
                  TextButton(onPressed: () => setState(() {}), child: const Text('Refresh')),
                ],
              ),
            ],
          ),
          SettingsGroup(
            title: 'From the Mac',
            children: [
              const SoonRow(title: 'Event simulator', detail: 'Pretend Claude sessions to try Mochi’s reactions without Claude Code.'),
              const SoonRow(title: 'Animation preview', detail: 'Play any of Mochi’s animations on demand.'),
              if (!Platform.isWindows)
                NoteRow(text: 'This is the macOS development build of Mochi for Windows.', icon: Icons.developer_mode_rounded, tint: p.indigo),
            ],
          ),
        ],
      );
    },
  );
}

// MARK: - About

class AboutPane extends StatelessWidget {
  const AboutPane({super.key, required this.host});

  final SettingsHost host;

  static const String claudeCode = 'https://claude.com/claude-code';
  static const String hooksDocs = 'https://docs.claude.com/en/docs/claude-code/hooks';
  static const String source = 'https://github.com/rizulsharma-2003/tamagotchi';

  static const List<(String, String)> licences = [
    ('Nunito (the typeface)', 'SIL Open Font License 1.1'),
    ('Flutter', 'BSD 3-Clause'),
    ('window_manager, tray_manager', 'MIT'),
    ('win32, ffi, http, qr', 'BSD 3-Clause'),
    ('cryptography', 'Apache 2.0'),
  ];

  @override
  Widget build(BuildContext context) {
    final desktop = host.desktop;
    final opener = desktop.opener;
    final pet = host.pet;
    Widget link(String label, String url) =>
        OutlinedButton.icon(onPressed: opener == null ? null : () => opener.open(Uri.parse(url)), icon: const Icon(Icons.open_in_new_rounded, size: 16), label: Text(label));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.l, horizontal: Space.m),
              child: Column(
                children: [
                  SizedBox(width: 120, height: 96, child: PetPreview(settings: desktop.settings, now: host.now, library: host.library)),
                  const SizedBox(height: Space.s),
                  Text('Mochi for Windows', style: context.type.largeTitle, textAlign: TextAlign.center),
                  const SizedBox(height: Space.xs),
                  Text('Version $appVersion · hook helper ${HelperInfo.version}', style: context.type.footnote, textAlign: TextAlign.center),
                  const SizedBox(height: Space.xs),
                  Text(
                    'A tiny digital friendship between you, $pet and your AI coding companion.',
                    style: context.type.footnote,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
        UpdatesGroup(host: host),
        SettingsGroup(
          title: 'Links',
          children: [
            ActionsRow(children: [link('Claude Code', claudeCode), link('Claude Code hooks', hooksDocs), link('Mochi’s source', source)]),
          ],
        ),
        SettingsGroup(
          title: 'Licences',
          children: [
            for (final (name, licence) in licences) InfoRow(label: name, value: licence),
            ActionsRow(
              children: [
                OutlinedButton(
                  onPressed: () => showLicensePage(context: context, applicationName: 'Mochi for Windows', applicationVersion: appVersion),
                  child: const Text('All Licences…'),
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'Uninstall',
          children: [
            SelectableText.rich(
              TextSpan(
                text: uninstallSteps(desktop),
                style: context.type.footnote.copyWith(color: context.palette.ink, height: 1.6),
              ),
            ).withPadding(rowPadding),
          ],
        ),
        SettingsGroup(
          title: 'Characters',
          children: [
            TextRow(
              'Mochi and Patch are original characters drawn with vector shapes. Patch is inspired by AI coding '
              'assistants in spirit only and uses no third-party logos or artwork.',
              secondary: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// Settings › About › Uninstall, for how this copy runs: installed (Windows Settings › Apps does the rest), or from a
/// folder of its own.
String uninstallSteps(MochiDesktop desktop) {
  const hooks = '1. Settings › Claude Code › Remove Mochi’s Hooks (takes out only Mochi’s entries, after a backup).\n';
  const unpair = '2. Settings › Phones › Unpair This PC, if you paired a phone.\n';
  if (desktop.installer.installed) {
    return '$hooks$unpair'
        '3. Uninstall Mochi in Windows Settings › Apps › Installed apps. It quits Mochi and removes its folder, its '
        'Start-menu shortcut and its startup entry.\n'
        '4. If you like, delete ${desktop.paths.home} (your settings and this PC’s link).';
  }
  return '$hooks$unpair'
      '3. Settings › General: switch off Start Mochi with Windows.\n'
      '4. Quit Mochi from the tray, then delete its folder${desktop.installer.supported ? ' (${desktop.installer.runningFrom})' : ''}.\n'
      '5. If you like, delete ${desktop.paths.home} (your settings and this PC’s link).';
}

/// Settings › About › Updates: this version, where updates stand, automatic downloads, what's new, and installing
/// Mochi when it runs from somewhere else.
class UpdatesGroup extends StatelessWidget {
  const UpdatesGroup({super.key, required this.host});

  final SettingsHost host;

  /// The status line: a title, whether all is well, and a word on it.
  static (String, bool, String) status(Updater updater, {required String runningFrom, required String Function(DateTime) time}) {
    final version = updater.newVersion;
    final problem = updater.problem;
    final checked = updater.checkedAt;
    return switch (updater.phase) {
      UpdatePhase.unsupported => (
        'Updates',
        false,
        Platform.isWindows ? 'This build can’t verify updates, so it never installs one' : 'Mochi for Windows updates itself',
      ),
      UpdatePhase.notInstalled => ('Updates are off', false, 'Mochi isn’t installed'),
      UpdatePhase.idle => ('Not checked yet', true, 'Soon after launch'),
      UpdatePhase.checking => ('Checking for updates…', true, ''),
      UpdatePhase.upToDate => ('Mochi is up to date', true, checked == null ? '' : 'Checked ${time(checked)}'),
      UpdatePhase.available => ('Mochi $version is available', true, 'Not downloaded yet'),
      UpdatePhase.downloading => ('Downloading Mochi $version…', true, '${((updater.progress ?? 0) * 100).floor()}%'),
      UpdatePhase.verifying => ('Checking Mochi $version…', true, 'Signature and checksum'),
      UpdatePhase.ready => ('Mochi $version is ready: restart to update', true, 'Or at Mochi’s next launch'),
      UpdatePhase.couldNotVerify => ('Couldn’t verify the update', false, problem ?? 'It was thrown away'),
      UpdatePhase.offline => ('Couldn’t check for updates: offline', false, problem ?? 'Mochi tries again later'),
      UpdatePhase.failed => ('Couldn’t update', false, problem ?? 'Mochi tries again later'),
      UpdatePhase.applying => ('Restarting to update…', true, ''),
    };
  }

  @override
  Widget build(BuildContext context) {
    final desktop = host.desktop;
    final updater = desktop.updater;
    final installer = desktop.installer;
    return ListenableBuilder(
      listenable: Listenable.merge([updater, installer, desktop.settings]),
      builder: (context, _) {
        final p = context.palette;
        final settings = desktop.settings;
        final phase = updater.phase;
        String time(DateTime at) => MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal()));
        final (title, ok, detail) = status(updater, runningFrom: installer.runningFrom, time: time);
        final busy = phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.verifying;
        final notes = updater.notes;
        return SettingsGroup(
          title: 'Updates',
          footer: installer.installed
              ? 'Mochi checks your own Mochi Link relay at launch and every 6 hours. Updates are signed with Mochi’s release '
                    'key and checked before they’re installed, and they never interrupt you: a new version goes in when '
                    'you restart Mochi, or at its next launch.'
              : null,
          children: [
            InfoRow(label: 'Version', value: '$appVersion (build $appBuild)'),
            StatusRow(
              title: title,
              ok: ok,
              detail: detail,
              icon: switch (phase) {
                UpdatePhase.couldNotVerify => Icons.gpp_bad_outlined,
                UpdatePhase.offline => Icons.cloud_off_rounded,
                UpdatePhase.ready => Icons.system_update_alt_rounded,
                _ => null,
              },
              tint: switch (phase) {
                UpdatePhase.couldNotVerify || UpdatePhase.failed => p.danger,
                UpdatePhase.offline => p.warning,
                _ => null,
              },
            ),
            if (phase == UpdatePhase.downloading)
              Padding(
                padding: rowPadding,
                child: LinearProgressIndicator(value: updater.progress, semanticsLabel: 'Downloading the update'),
              ),
            if (notes.isNotEmpty && (phase == UpdatePhase.available || busy || phase == UpdatePhase.ready))
              TextRow('What’s new in Mochi ${updater.newVersion}:\n$notes', secondary: true),
            if (phase == UpdatePhase.notInstalled) ...[
              NoteRow(
                text:
                    'Mochi is running from ${installer.runningFrom}, so it can’t update itself. Install it for this user '
                    '(no admin rights needed): it moves to ${installer.layout.installDirectory}, gets a Start-menu entry, '
                    'and keeps itself up to date. Your settings stay as they are.',
                icon: Icons.download_for_offline_outlined,
              ),
              if (installer.problem != null)
                NoteRow(text: installer.problem!, icon: Icons.error_outline_rounded, tint: p.danger, textColor: p.danger),
              ActionsRow(
                children: [
                  FilledButton(onPressed: installer.busy || host.onInstall == null ? null : host.onInstall, child: Text(installer.busy ? 'Installing…' : 'Install Mochi')),
                ],
              ),
            ],
            if (installer.installed) ...[
              ToggleRow(
                title: 'Download updates automatically',
                subtitle: 'In the background, checked before they’re kept. Off: Mochi tells you about a new version and waits.',
                value: settings.autoUpdate,
                onChanged: (value) => settings.autoUpdate = value,
              ),
              if (updater.canCheck)
                ActionsRow(
                  children: [
                    if (phase == UpdatePhase.ready)
                      FilledButton(onPressed: host.onRestartToUpdate, child: const Text('Restart to Update')),
                    if (phase == UpdatePhase.available)
                      FilledButton(onPressed: updater.download, child: const Text('Download Update')),
                    OutlinedButton(onPressed: busy || phase == UpdatePhase.applying ? null : updater.check, child: const Text('Check for Updates')),
                  ],
                ),
              InfoRow(label: 'Installed in', value: installer.layout.installDirectory, selectable: true),
            ],
          ],
        );
      },
    );
  }
}

extension on Widget {
  Widget withPadding(EdgeInsets padding) => Padding(padding: padding, child: this);
}
