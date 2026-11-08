// Settings › Mischief (Windows only, beyond the Mac; docs/SPRINT_2.md, "Windows extras: crazier than the Mac"): the
// master switch (off at first), each extra's switch with a line on what it does, why one isn't running right now, and
// the rules every extra keeps.

import 'package:flutter/material.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/mischief.dart';
import '../stage/celebrations.dart' show CelebrationKind;
import 'mischief_weather_rows.dart';
import 'settings_kit.dart';

class MischiefPane extends StatelessWidget {
  const MischiefPane({super.key, required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final desktop = host.desktop;
    final gate = desktop.mischief;
    return ListenableBuilder(
      listenable: Listenable.merge([desktop.settings, gate]),
      builder: (context, _) {
        final settings = desktop.settings;
        final mischief = settings.mischief;
        final pet = host.pet;
        final supported = gate.supported;
        final all = gate.whyAll;
        final stage = host.mischief;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              footer:
                  '$pet never takes your keyboard or pointer, never closes or minimises anything and never types into '
                  'your apps. Anything it moves is put back. It keeps still while a full-screen app, a game or a '
                  'presentation has the screen, during quiet hours and while you focus.',
              children: [
                ToggleRow(
                  title: 'Let $pet make mischief',
                  subtitle: 'Off at first. $pet gets up to the extras you choose below, out on your desktop.',
                  value: mischief.enabled,
                  onChanged: supported ? (value) => settings.mischief = mischief.copyWith(enabled: value) : null,
                ),
                if (!supported)
                  NoteRow(text: MischiefPause.unsupported.note(pet), icon: Icons.desktop_windows_rounded)
                else if (mischief.enabled && all != null)
                  NoteRow(text: all.note(pet), icon: Icons.pause_circle_outline_rounded),
              ],
            ),
            SettingsGroup(
              title: 'Extras',
              children: [
                for (final extra in MischiefExtra.available) ...[
                  _ExtraRow(extra: extra, host: host, everything: all),
                  if (extra == MischiefExtra.moods) WeatherRows(host: host),
                ],
              ],
            ),
            if (stage != null && supported)
              SettingsGroup(
                title: 'Try it',
                footer: 'Plays once now, on the display you’re on, even during quiet hours (you asked). The note goes at the top right of your main display.',
                children: [
                  ActionsRow(
                    children: [
                      OutlinedButton(
                        onPressed: mischief.enabled ? () => stage.preview(CelebrationKind.confetti) : null,
                        child: const Text('Confetti'),
                      ),
                      OutlinedButton(
                        onPressed: mischief.enabled ? () => stage.preview(CelebrationKind.fireworks) : null,
                        child: const Text('Fireworks'),
                      ),
                      OutlinedButton(
                        onPressed: mischief.enabled ? stage.previewNote : null,
                        child: const Text('Leave a note'),
                      ),
                    ],
                  ),
                  NoteRow(
                    text:
                        'These show for 20 seconds, whatever today is. The lights and the snow go on the window you’re using, '
                        'the pumpkins on your taskbar.',
                    icon: Icons.celebration_outlined,
                  ),
                  ActionsRow(
                    children: [
                      for (final (label, event) in const [
                        ('Diwali lights', w.SeasonalEvent.diwali),
                        ('Christmas snow', w.SeasonalEvent.christmas),
                        ('Halloween pumpkins', w.SeasonalEvent.halloween),
                      ])
                        OutlinedButton(
                          onPressed: mischief.enabled && mischief.on(MischiefExtra.holidayTakeover) ? () => stage.previewTakeover(event) : null,
                          child: Text(label),
                        ),
                    ],
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// One extra: its switch, what it does, and why it's resting right now (when that's only about it).
class _ExtraRow extends StatelessWidget {
  const _ExtraRow({required this.extra, required this.host, required this.everything});

  final MischiefExtra extra;
  final SettingsHost host;

  /// What pauses every extra (said once, above), so not again here.
  final MischiefPause? everything;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final mischief = settings.mischief;
    final why = host.desktop.mischief.why(extra);
    final own = why != null && why != everything && why != MischiefPause.off && why != MischiefPause.extraOff && why != MischiefPause.unsupported;
    return ToggleRow(
      title: extra.title,
      subtitle: own ? '${extra.detail}\n${why.note(host.pet)}' : extra.detail,
      value: mischief.on(extra),
      onChanged: mischief.enabled && host.desktop.mischief.supported ? (value) => settings.mischief = mischief.withExtra(extra, value) : null,
    );
  }
}
