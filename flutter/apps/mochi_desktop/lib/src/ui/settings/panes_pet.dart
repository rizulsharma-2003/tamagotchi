// Settings › Your pet: General, Characters, Desktop Pet and Fun (the Mac's GeneralSettings, CharacterSettings,
// DesktopSettings and FunSettings). What the Mac has and Windows doesn't yet is listed, tagged, at the end of each.

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/desktop_settings.dart';
import '../../core/seasons.dart';
import '../../platform/startup.dart';
import '../../platform/taskbar.dart';
import 'previews.dart';
import 'settings_kit.dart';
import 'settings_tabs.dart';

const List<String> monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "8 November".
String dayAndMonth(DateTime date) => '${date.day} ${monthNames[date.month - 1]}';

// MARK: - General

class GeneralPane extends StatefulWidget {
  const GeneralPane({super.key, required this.host});

  final SettingsHost host;

  @override
  State<GeneralPane> createState() => _GeneralPaneState();
}

class _GeneralPaneState extends State<GeneralPane> {
  late StartupStatus _startup = widget.host.desktop.startup.status();
  String? _startupProblem;

  void _setStartup(bool on) {
    final problem = widget.host.desktop.startup.setEnabled(on);
    setState(() {
      _startupProblem = problem;
      _startup = widget.host.desktop.startup.status();
    });
  }

  Future<void> _reset() async {
    final settings = widget.host.desktop.settings;
    final confirmed = await confirmAction(
      context,
      title: 'Reset Mochi’s settings?',
      message:
          'Names, looks, the theme, reactions and every switch go back to how they were when you installed Mochi. '
          'Your phones stay paired, Claude Code stays connected, and starting with Windows stays as it is.',
      confirm: 'Reset',
      destructive: true,
    );
    if (confirmed) settings.reset();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final settings = host.desktop.settings;
    final startup = host.desktop.startup;
    final p = context.palette;
    final pet = host.pet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Names',
          footer: 'Your phones and Ask $pet use these names too.',
          children: [
            NameFieldRow(
              label: 'Your pet',
              text: settings.petNameText,
              placeholder: 'Mochi',
              onChanged: (value) => settings.petName = value,
            ),
            NameFieldRow(
              label: 'Coding companion',
              text: settings.companionNameText,
              placeholder: 'Patch',
              onChanged: (value) => settings.companionName = value,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Startup',
          children: [
            ToggleRow(
              title: 'Start $pet with Windows',
              subtitle: startup.supported
                  ? '$pet starts in the tray and on your taskbar when you sign in to this PC.'
                  : 'Starting with Windows works in Mochi for Windows.',
              value: _startup.enabled,
              onChanged: startup.supported ? _setStartup : null,
            ),
            if (startup.supported && _startup.note != null) NoteRow(text: _startup.note!, icon: Icons.info_outline_rounded),
            if (_startupProblem != null)
              NoteRow(text: _startupProblem!, icon: Icons.warning_amber_rounded, tint: p.warning, textColor: p.warning),
          ],
        ),
        SettingsGroup(
          title: 'Appearance',
          children: [
            ChoiceRow<ThemeMode>(
              label: 'Theme',
              selected: settings.themeMode,
              onSelected: (mode) => settings.themeMode = mode,
              choices: const [
                (ThemeMode.system, 'System', Icons.brightness_auto_rounded),
                (ThemeMode.light, 'Light', Icons.light_mode_rounded),
                (ThemeMode.dark, 'Dark', Icons.dark_mode_rounded),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'Reactions',
          children: [
            ToggleRow(
              title: 'Pause all reactions',
              subtitle:
                  'Sessions keep updating; $pet stops celebrating, worrying and waving at Claude’s moments, here and on '
                  'the taskbar.',
              value: settings.pauseReactions,
              onChanged: (value) => settings.pauseReactions = value,
            ),
            ActionsRow(children: [PaneLink(host: host, tab: SettingsTab.notifications, label: 'Choose the moments')]),
          ],
        ),
        SettingsGroup(
          title: 'From the Mac',
          children: [
            SoonRow(
              title: 'Quiet hours and quiet mode',
              detail: 'Times when $pet stays silent. Mochi for Windows makes no sounds and shows no Windows notifications yet.',
            ),
            SoonRow(
              title: 'Naps that follow this PC',
              detail:
                  'On a Mac, $pet sleeps while the computer rests and wakes when you’re back. Here $pet naps after '
                  '30 minutes without news from Claude.',
            ),
            SoonRow(title: 'A shortcut to show or hide $pet', detail: 'Use the tray icon’s menu for now.'),
          ],
        ),
        SettingsGroup(
          title: 'Start over',
          footer: 'Your pairing, Claude Code’s hooks and Mochi’s folder aren’t touched.',
          children: [
            ActionsRow(
              children: [
                OutlinedButton(
                  onPressed: _reset,
                  style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                  child: const Text('Reset Settings…'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// MARK: - Characters

class CharactersPane extends StatelessWidget {
  const CharactersPane({super.key, required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final pet = host.pet;
    final companion = host.companion;
    final holiday = settings.holidayOn(host.now);
    final wearables = Accessory.values.where((accessory) => accessory.slot == AccessorySlot.wearable).toList();
    final deskThings = Accessory.values.where((accessory) => accessory.slot == AccessorySlot.desk).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          footer: holiday == null
              ? 'Your paired phones show the same room.'
              : 'Dressed up for ${SeasonCalendar.title(holiday, petName: pet)} (Settings › Fun). Your paired phones show the same room.',
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.s),
              child: SizedBox(
                height: 170,
                child: RoomPreview(
                  settings: settings,
                  now: host.now,
                  library: host.library,
                  label: '$pet and $companion in the ${settings.officeTheme.title}, preview',
                ),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Coat',
          children: [
            Padding(
              padding: rowPadding,
              child: Wrap(
                spacing: Space.m,
                runSpacing: Space.s,
                children: [for (final color in PetColor.values) _CoatSwatch(color: color, selected: settings.petColor == color, onTap: () => settings.petColor = color)],
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Look',
          footer: 'With nothing chosen, $pet and $companion dress up for holidays.',
          children: [
            MenuRow<Accessory?>(
              label: '$pet wears',
              value: settings.petAccessory,
              items: [(null, 'Nothing'), for (final accessory in wearables) (accessory, accessory.title)],
              onChanged: (value) => settings.petAccessory = value,
            ),
            MenuRow<Accessory?>(
              label: '$companion wears',
              value: settings.companionAccessory,
              items: [(null, 'Nothing'), for (final accessory in wearables) (accessory, accessory.title)],
              onChanged: (value) => settings.companionAccessory = value,
            ),
            MenuRow<Accessory?>(
              label: 'On the desk',
              value: settings.deskAccessory,
              items: [(null, 'Nothing'), for (final accessory in deskThings) (accessory, accessory.title)],
              onChanged: (value) => settings.deskAccessory = value,
            ),
            MenuRow<OfficeTheme>(
              label: 'Office theme',
              value: settings.officeTheme,
              items: [for (final theme in OfficeTheme.values) (theme, theme.title)],
              onChanged: (value) => settings.officeTheme = value,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Companion',
          footer: switch (settings.companionVisibility) {
            CompanionVisibility.duringSessions =>
              '$companion joins you when a Claude Code session starts, at his desk on the taskbar and in $pet’s room, '
                  'and packs up after the last one ends.',
            CompanionVisibility.always => '$companion stays at his desk all the time, even with no Claude Code session.',
            CompanionVisibility.never => '$companion’s desk stays empty, and $pet has the taskbar to itself.',
          },
          children: [
            MenuRow<CompanionVisibility>(
              label: 'Show $companion',
              value: settings.companionVisibility,
              items: [for (final visibility in CompanionVisibility.values) (visibility, visibility.title)],
              onChanged: (value) => settings.companionVisibility = value,
            ),
            MenuRow<int>(
              label: 'Stays after the last session ends',
              value: settings.companionLingerMinutes,
              items: [
                for (final minutes in _minuteChoices(const [0, 5, 10, 15, 20, 30, 45, 60, 90, 120], settings.companionLingerMinutes))
                  (minutes, minutes == 0 ? 'Leaves at once' : '$minutes min'),
              ],
              onChanged: settings.companionVisibility == CompanionVisibility.duringSessions
                  ? (value) => settings.companionLingerMinutes = value
                  : null,
            ),
            MenuRow<int>(
              label: 'Naps after, without news from Claude',
              value: settings.companionSleepAfterMinutes,
              items: [
                for (final minutes in _minuteChoices(const [1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 45, 60], settings.companionSleepAfterMinutes))
                  (minutes, '$minutes min'),
              ],
              onChanged: settings.companionVisibility == CompanionVisibility.never ? null : (value) => settings.companionSleepAfterMinutes = value,
            ),
            ActionsRow(children: [PaneLink(host: host, tab: SettingsTab.desktop, label: '$companion on the taskbar')]),
          ],
        ),
        SettingsGroup(
          title: 'From the Mac',
          children: [
            SoonRow(
              title: 'Friendship and achievements',
              detail: 'Petting, play and treats earn friendship on a Mac, and achievements unlock new things to wear. Here everything is unlocked.',
            ),
          ],
        ),
      ],
    );
  }
}

/// The Mac's stepper values as a menu, with [current] in it even if it's between them (an older file, the Mac's
/// own).
List<int> _minuteChoices(List<int> choices, int current) => ({...choices, current}.toList()..sort());

class _CoatSwatch extends StatelessWidget {
  const _CoatSwatch({required this.color, required this.selected, required this.onTap});

  final PetColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = PetPalette(color);
    final p = context.palette;
    return Tooltip(
      message: color.title,
      child: ClayPress(
        onTap: onTap,
        selected: selected,
        semanticLabel: '${color.title} coat',
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 34,
          height: 34,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? p.tint : Colors.transparent, width: 2.5),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.body,
              border: Border.all(color: palette.outline, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

// MARK: - Desktop pet

class DesktopPetPane extends StatelessWidget {
  const DesktopPetPane({super.key, required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final pet = host.pet;
    final block = host.stroll?.block;
    final roamNote = settings.roamTaskbar && block != null && block != RoamBlock.turnedOff ? block.note : null;
    final patch = host.patch;
    final name = host.companion;
    final never = settings.companionVisibility == CompanionVisibility.never;
    // Patch is around and should be on the taskbar, but there's no stretch roomy enough for both right now.
    final noRoom = patch != null &&
        patch.visible &&
        settings.companionOnTaskbar &&
        settings.roamTaskbar &&
        (host.stroll?.onTaskbar ?? false) &&
        host.stroll?.home == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          footer: 'Show $pet again any time from the tray icon’s menu.',
          children: [
            ToggleRow(
              title: 'Show the desktop pet',
              subtitle: '$pet stays on your desktop, above your windows, while Mochi’s window is closed.',
              value: settings.showPet,
              onChanged: (value) => settings.showPet = value,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Taskbar',
          children: [
            ToggleRow(
              title: 'Roam along the taskbar',
              subtitle:
                  '$pet strolls in the taskbar’s empty stretches, naps there, and stops to face you when Claude needs '
                  'you. Drag $pet off the taskbar to leave it somewhere else.',
              value: settings.roamTaskbar,
              onChanged: settings.showPet ? (value) => settings.roamTaskbar = value : null,
            ),
            if (roamNote != null) NoteRow(text: roamNote),
            ToggleRow(
              title: '$name on the taskbar',
              subtitle:
                  'While $name is around, he keeps a little desk in an empty stretch beside $pet: he types while Claude '
                  'works, waves when Claude needs you and celebrates with $pet when it’s done, and now and then they '
                  'play or nap together.',
              value: settings.companionOnTaskbar,
              onChanged: settings.showPet && settings.roamTaskbar && !never ? (value) => settings.companionOnTaskbar = value : null,
            ),
            if (never)
              NoteRow(text: '$name is set never to show, in Characters.')
            else if (!settings.roamTaskbar && settings.companionOnTaskbar)
              NoteRow(text: '$name joins $pet on the taskbar while $pet roams it.')
            else if (noRoom)
              NoteRow(text: 'There’s no stretch of the taskbar roomy enough for both right now, so $name waits in $pet’s room.'),
            if (never) ActionsRow(children: [PaneLink(host: host, tab: SettingsTab.characters, label: 'Show $name')]),
          ],
        ),
        SettingsGroup(
          title: 'Position',
          footer: 'With roaming off, $pet stays wherever you drop it.',
          children: [
            ActionsRow(
              children: [
                OutlinedButton(
                  onPressed: settings.petPosition == null ? null : () => settings.petPosition = null,
                  child: const Text('Move Back to the Bottom Left'),
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'Using $pet',
          children: [
            TextRow(
              'Click $pet to pet it, double-click (or press Enter) to open Mochi, and right-click (or Shift+F10) for the '
              'menu. On the taskbar, clicks go through to the taskbar everywhere but on $pet.',
              secondary: true,
            ),
            NoteRow(
              icon: Icons.motion_photos_paused_outlined,
              text: host.desktop.motion.reduced
                  ? 'Animation effects are off on this PC, so $pet moves more calmly and stays put on the taskbar.'
                  : '$pet moves more calmly when you turn animation effects off in Windows’ Accessibility settings.',
            ),
          ],
        ),
        SettingsGroup(
          title: 'From the Mac',
          children: [
            SoonRow(title: 'Size', detail: 'Small, medium or large. On Windows $pet takes the taskbar’s size, or a standard size on the desktop.'),
            SoonRow(title: 'Let clicks pass through $pet', detail: 'Off the taskbar, $pet always catches clicks so you can pet and drag it.'),
          ],
        ),
      ],
    );
  }
}

// MARK: - Fun

class FunPane extends StatelessWidget {
  const FunPane({super.key, required this.host});

  final SettingsHost host;

  String _status(DateTime now) {
    final settings = host.desktop.settings;
    if (!settings.holidays) return 'Decorations are off.';
    final pet = host.pet;
    final seasonal = settings.seasonal;
    final parts = <String>[];
    final event = SeasonCalendar.event(now, seasonal, mochiBirthday: settings.adoptedAt);
    if (event != null) {
      final until = SeasonCalendar.lastDay(event, now, seasonal, mochiBirthday: settings.adoptedAt);
      final name = SeasonCalendar.title(event, petName: pet);
      final today = until == null || (until.year == now.year && until.month == now.month && until.day == now.day);
      parts.add(today ? '$name today.' : '$name until ${dayAndMonth(until)}.');
    }
    final next = SeasonCalendar.nextEvent(now, seasonal, mochiBirthday: settings.adoptedAt);
    if (next != null) parts.add('Next: ${SeasonCalendar.title(next.event, petName: pet)} from ${dayAndMonth(next.starts)}.');
    return parts.isEmpty ? 'No holidays coming up.' : parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final pet = host.pet;
    final month = settings.birthdayMonth;
    final enabled = settings.holidays;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Holidays',
          footer:
              'Halloween, Diwali, Christmas, New Year, Valentine’s Day, your birthday and $pet’s (the day $pet came to '
              'this PC, ${dayAndMonth(settings.adoptedAt)}). Mochi’s window greets the day, and $pet wears a costume '
              'when you haven’t chosen something to wear.',
          children: [
            ToggleRow(
              title: 'Celebrate holidays with decorations and costumes',
              value: enabled,
              onChanged: (value) => settings.holidays = value,
            ),
            MenuRow<int>(
              label: 'Your birthday',
              value: month ?? 0,
              items: [(0, 'Not set'), for (var m = 1; m <= 12; m++) (m, monthNames[m - 1])],
              onChanged: enabled ? (value) => settings.setBirthday(value == 0 ? null : value, settings.birthdayDay) : null,
            ),
            if (month != null)
              MenuRow<int>(
                label: 'Day',
                value: settings.birthdayDay ?? 1,
                items: [for (var d = 1; d <= DesktopSettings.daysIn(month); d++) (d, '$d')],
                onChanged: enabled ? (value) => settings.setBirthday(month, value) : null,
              ),
            NoteRow(text: _status(host.now), icon: Icons.celebration_outlined),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.s),
              child: SizedBox(
                height: 130,
                child: RoomPreview(settings: settings, now: host.now, library: host.library, label: '$pet’s room today, preview'),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'From the Mac',
          children: [
            SoonRow(title: 'Talking in speech bubbles', detail: '$pet and ${host.companion} chatting as they work, as often as you like. Here $pet speaks up only for Claude’s moments.'),
            SoonRow(title: 'Growing up', detail: 'Kitten, then young, then grown-up as your friendship grows.'),
            SoonRow(title: 'Games', detail: 'Catch and rock-paper-scissors with $pet.'),
            SoonRow(title: 'Adventures', detail: '$pet heads out to explore your desktop and comes back with stories.'),
            SoonRow(title: 'Focus sessions', detail: 'A focus timer $pet keeps you company through.'),
            SoonRow(title: 'Daily recap', detail: 'A card of what you and Claude did today.'),
            SoonRow(title: 'Room furniture', detail: 'Arrange furniture in $pet’s room.'),
          ],
        ),
      ],
    );
  }
}
