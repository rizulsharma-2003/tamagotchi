import 'package:flutter/material.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_wire/mochi_wire.dart';

import '../../desktop.dart';

/// Settings: Claude Code, phones, appearance, the desktop pet, Ask Mochi, about.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.desktop, required this.onPair});

  final MochiDesktop desktop;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.settings, desktop.hooks, desktop.link, desktop.motion]),
    builder: (context, _) {
      final p = context.palette;
      final settings = desktop.settings;
      final hooks = desktop.hooks;
      final inspection = hooks.inspection;
      return Scrollbar(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.l, Space.xl),
          children: [
            const SectionTitle(title: 'Claude Code'),
            const SizedBox(height: Space.s),
            ClayCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconTile(
                        icon: hooks.connected ? Icons.check_circle_rounded : Icons.link_rounded,
                        tint: hooks.connected ? p.success : p.tint,
                      ),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Text(switch (inspection?.status) {
                          HookStatus.installed => 'Connected: Mochi hears from every Claude Code session',
                          HookStatus.needsUpdate => 'Connected, but out of date',
                          HookStatus.unreadable => "Claude Code's settings can't be read",
                          _ => 'Not connected',
                        }, style: context.type.headline),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.s),
                  Text(
                    'Connect adds Mochi’s hooks to ${inspection?.settingsFile ?? 'Claude Code’s settings.json'} and keeps everything '
                    'else in it as it is (a backup is made first). Remove takes out only Mochi’s hooks.',
                    style: context.type.footnote,
                  ),
                  if (inspection?.hooksDisabled ?? false) ...[
                    const SizedBox(height: Space.s),
                    NoteLabel(
                      text: 'Claude Code’s “disableAllHooks” is on, so no hooks run.',
                      icon: Icons.warning_amber_rounded,
                      tint: p.warning,
                    ),
                  ],
                  if (inspection?.managedHooksOnly ?? false) ...[
                    const SizedBox(height: Space.s),
                    NoteLabel(text: 'Your organisation allows only managed hooks.', icon: Icons.warning_amber_rounded, tint: p.warning),
                  ],
                  if (hooks.problem != null) ...[
                    const SizedBox(height: Space.s),
                    NoteLabel(text: hooks.problem!, icon: Icons.error_outline_rounded, tint: p.danger, textColor: p.danger),
                  ],
                  if (hooks.lastBackup != null) ...[
                    const SizedBox(height: Space.s),
                    NoteLabel(text: 'Backup: ${hooks.lastBackup}', icon: Icons.history_rounded),
                  ],
                  const SizedBox(height: Space.m),
                  Wrap(
                    spacing: Space.s,
                    runSpacing: Space.s,
                    children: [
                      FilledButton(
                        onPressed: hooks.busy || hooks.connected ? null : hooks.connect,
                        child: Text(hooks.needsUpdate ? 'Update' : 'Connect Claude Code'),
                      ),
                      OutlinedButton(
                        onPressed: hooks.busy || inspection?.status == HookStatus.notInstalled ? null : hooks.disconnect,
                        child: const Text('Remove Mochi’s hooks'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.m),
            const SectionTitle(title: 'Phones'),
            const SizedBox(height: Space.s),
            ClayCard(
              padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Send Claude’s summaries to my phones'),
                    subtitle: Text(
                      'When Claude finishes a turn, a short summary (written by Claude Haiku) goes to your paired phones, '
                      'end-to-end encrypted.',
                      style: context.type.footnote,
                    ),
                    value: settings.shareSummaries,
                    onChanged: (value) => settings.shareSummaries = value,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Answer requests from my phones'),
                    subtitle: Text('What you tell Mochi on a phone runs here, like Ask Mochi.', style: context.type.footnote),
                    value: settings.acceptCommands,
                    onChanged: (value) => settings.acceptCommands = value,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.qr_code_2_rounded),
                    title: Text(desktop.link.paired ? 'Paired devices' : 'Pair a phone'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: onPair,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.m),
            const SectionTitle(title: 'Appearance'),
            const SizedBox(height: Space.s),
            ClayCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Choices<ThemeMode>(
                    label: 'Theme',
                    selected: settings.themeMode,
                    onSelected: (mode) => settings.themeMode = mode,
                    choices: const [
                      (ThemeMode.system, 'System', Icons.brightness_auto_rounded),
                      (ThemeMode.light, 'Light', Icons.light_mode_rounded),
                      (ThemeMode.dark, 'Dark', Icons.dark_mode_rounded),
                    ],
                  ),
                  const SizedBox(height: Space.m),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Mochi on the desktop'),
                    subtitle: Text('Mochi sits on your desktop while this window is closed.', style: context.type.footnote),
                    value: settings.showPet,
                    onChanged: (value) => settings.showPet = value,
                  ),
                  NoteLabel(
                    icon: Icons.motion_photos_paused_outlined,
                    text: desktop.motion.reduced
                        ? 'Animation effects are off on this computer, so Mochi moves more calmly.'
                        : 'Mochi moves more calmly when you turn animation effects off in your system settings.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.m),
            const SectionTitle(title: 'Ask Mochi'),
            const SizedBox(height: Space.s),
            ClayCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Choices<String>(
                    label: 'Model',
                    selected: settings.model,
                    onSelected: (model) => settings.model = model,
                    choices: const [('haiku', 'Fast (Haiku)', Icons.bolt_rounded), ('sonnet', 'Smart (Sonnet)', Icons.psychology_rounded)],
                  ),
                  const SizedBox(height: Space.s),
                  NoteLabel(
                    icon: Icons.shield_outlined,
                    text:
                        'Ask Mochi runs claude -p with web search only: on Windows it can’t change this PC or message '
                        'your Claude sessions yet.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.m),
            const SectionTitle(title: 'About'),
            const SizedBox(height: Space.s),
            ClayCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mochi $appVersion · hook helper ${HelperInfo.version}', style: context.type.body),
                  const SizedBox(height: Space.xs),
                  SelectableText('Mochi’s folder: ${desktop.paths.home}', style: context.type.footnote),
                  if (desktop.sessions.lateEvents > 0 || desktop.sessions.droppedEvents > 0)
                    Text(
                      '${desktop.sessions.lateEvents} events arrived while Mochi was closed'
                      '${desktop.sessions.droppedEvents > 0 ? ' (${desktop.sessions.droppedEvents} more were dropped)' : ''}.',
                      style: context.type.footnote,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// One of a few choices, as chips that wrap onto more lines at large text sizes (a segmented control can't).
class _Choices<T> extends StatelessWidget {
  const _Choices({required this.label, required this.selected, required this.onSelected, required this.choices});

  final String label;
  final T selected;
  final ValueChanged<T> onSelected;
  final List<(T, String, IconData)> choices;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.type.footnote.copyWith(fontWeight: FontWeight.w700, color: p.ink),
        ),
        const SizedBox(height: Space.s),
        Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            for (final (value, text, icon) in choices)
              ChoiceChip(
                label: Text(text),
                avatar: Icon(icon, size: 16, color: value == selected ? p.onTint : p.tint),
                showCheckmark: false,
                selected: value == selected,
                selectedColor: p.tint,
                labelStyle: context.type.label.copyWith(color: value == selected ? p.onTint : p.ink),
                backgroundColor: p.sunken,
                side: BorderSide(color: p.stroke),
                onSelected: (_) => onSelected(value),
              ),
          ],
        ),
      ],
    );
  }
}
