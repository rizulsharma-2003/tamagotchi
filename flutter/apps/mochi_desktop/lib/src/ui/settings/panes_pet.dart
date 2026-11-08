// Settings › Your pet: General, Characters, Desktop Pet and Fun (the Mac's GeneralSettings, CharacterSettings,
// DesktopSettings and FunSettings; Desktop Pet also has the Mac's menu-bar style, General › Menu bar, for the taskbar). What the Mac has and Windows doesn't yet is listed, tagged, at the end of each.

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_world/mochi_world.dart' show AchievementID, AdventureFrequency, Chattiness, FocusSettings, ProgressState, RecapSettings;
import 'package:mochi_world/mochi_world.dart' as w show SeasonCalendar;

import '../../core/desktop_settings.dart';
import '../../core/hotkeys.dart';
import '../../core/notifications.dart' show QuietHours;
import '../../core/pc_rhythm.dart';
import '../../core/seasons.dart';
import '../../platform/startup.dart';
import '../../platform/taskbar.dart';
import '../pet/room_editor.dart' show FurnitureIcon;
import 'previews.dart';
import 'settings_kit.dart';
import 'settings_tabs.dart';
import 'shortcut_row.dart';

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
                  'Sessions keep updating; $pet and ${host.companion} stop reacting, and nothing plays sounds or shows '
                  'Windows notifications.',
              value: settings.pauseReactions,
              onChanged: (value) => settings.pauseReactions = value,
            ),
            ToggleRow(
              title: 'Quiet mode',
              subtitle: 'No sounds and no Windows notifications until you turn it off.',
              value: settings.quietMode,
              onChanged: (value) => settings.quietMode = value,
            ),
            ActionsRow(
              children: [PaneLink(host: host, tab: SettingsTab.notifications, label: 'Choose the moments')],
            ),
          ],
        ),
        _QuietHoursGroup(settings: settings),
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

/// The Mac's Quiet hours: on or off, from and to (every half hour, and whatever an older file has).
class _QuietHoursGroup extends StatelessWidget {
  const _QuietHoursGroup({required this.settings});

  final DesktopSettings settings;

  static List<int> times(int current) => ({for (var minute = 0; minute < 24 * 60; minute += 30) minute, current}.toList()..sort());

  @override
  Widget build(BuildContext context) {
    final quiet = settings.quietHours;
    return SettingsGroup(
      title: 'Quiet hours',
      footer: 'During quiet hours and quiet mode there are no sounds or Windows notifications. Animations and badges still show.',
      children: [
        ToggleRow(
          title: 'Quiet hours',
          subtitle: quiet.enabled
              ? 'Every day from ${QuietHours.format(quiet.startMinute)} to ${QuietHours.format(quiet.endMinute)}.'
              : 'A quiet stretch every day, overnight if you like.',
          value: quiet.enabled,
          onChanged: (value) => settings.quietHours = quiet.copyWith(enabled: value),
        ),
        MenuRow<int>(
          label: 'From',
          value: quiet.startMinute,
          items: [for (final minute in times(quiet.startMinute)) (minute, QuietHours.format(minute))],
          onChanged: quiet.enabled ? (value) => settings.quietHours = quiet.copyWith(startMinute: value) : null,
        ),
        MenuRow<int>(
          label: 'To',
          value: quiet.endMinute,
          items: [for (final minute in times(quiet.endMinute)) (minute, QuietHours.format(minute))],
          onChanged: quiet.enabled ? (value) => settings.quietHours = quiet.copyWith(endMinute: value) : null,
        ),
      ],
    );
  }
}

/// The Mac's Characters › Naps: Mochi sleeps while this PC rests, awake while you work, and what the PC is doing now.
class _NapsGroup extends StatelessWidget {
  const _NapsGroup({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: host.desktop.rhythm,
    builder: (context, _) {
      final p = context.palette;
      final settings = host.desktop.settings;
      final rhythm = host.desktop.rhythm;
      final pet = host.pet;
      final activity = rhythm.activity;
      final (state, ok) = switch (activity) {
        null => ('Unknown', false),
        _ when activity.displaysAsleep => ('Locked or display off', false),
        _ when rhythm.resting => ('Resting', false),
        _ when activity.keepsDisplayAwake && activity.idleSeconds >= 60 => ('Kept awake: a video, call or presentation', true),
        _ when activity.cpuLoad >= SystemActivity.busyLoad => ('Busy', true),
        _ when activity.userActive => ('In use', true),
        _ => ('Quiet for a moment', true),
      };
      return SettingsGroup(
        title: 'Naps',
        footer:
            '$pet also sleeps when your display goes off or the PC is locked, stays up while a video, a call or a '
            'presentation keeps the screen on, Claude is working or the PC is busy, and wakes with a stretch when you’re '
            'back. Only the time since your last input is read, never what you type.',
        children: [
          ToggleRow(
            title: 'Sleep while my PC rests, awake while I work',
            value: settings.followSystem,
            onChanged: (value) => settings.followSystem = value,
          ),
          MenuRow<int>(
            label: 'Rests after, without typing or clicking',
            value: settings.restAfterMinutes,
            items: [
              for (final minutes in _minuteChoices(const [1, 2, 3, 5, 10, 15, 20, 30, 45, 60], settings.restAfterMinutes))
                (minutes, minutes == 1 ? '1 min' : '$minutes min'),
            ],
            onChanged: settings.followSystem ? (value) => settings.restAfterMinutes = value : null,
          ),
          if (rhythm.available)
            StatusRow(title: 'This PC now', ok: ok, icon: Icons.computer_rounded, tint: ok ? p.success : null, detail: state)
          else
            NoteRow(
              text: 'Naps follow the PC in Mochi for Windows. Here $pet naps after 30 minutes without news from Claude.',
              icon: Icons.info_outline_rounded,
            ),
        ],
      );
    },
  );
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
    // What's earned (achievements) or in season can be chosen; the rest says how to get it (the Mac's picker).
    final unlocked = host.desktop.world.world.progress.unlockedIDs;
    bool available(Accessory accessory) => accessory.isAvailable(unlocked: unlocked, date: host.now);
    String named(Accessory accessory) => available(accessory) ? accessory.title : '${accessory.title} — ${accessory.unlockHint}';
    final locked = {
      for (final accessory in Accessory.values)
        if (!available(accessory)) accessory,
    };
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
                children: [
                  for (final color in PetColor.values)
                    _CoatSwatch(color: color, selected: settings.petColor == color, onTap: () => settings.petColor = color),
                ],
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Look',
          footer: 'With nothing chosen, $pet and $companion dress up for holidays. Achievements unlock more to wear (Friendship, below).',
          children: [
            MenuRow<Accessory?>(
              label: '$pet wears',
              value: settings.petAccessory,
              items: [(null, 'Nothing'), for (final accessory in wearables) (accessory, named(accessory))],
              locked: locked,
              onChanged: (value) => settings.petAccessory = value,
            ),
            MenuRow<Accessory?>(
              label: '$companion wears',
              value: settings.companionAccessory,
              items: [(null, 'Nothing'), for (final accessory in wearables) (accessory, named(accessory))],
              locked: locked,
              onChanged: (value) => settings.companionAccessory = value,
            ),
            MenuRow<Accessory?>(
              label: 'On the desk',
              value: settings.deskAccessory,
              items: [(null, 'Nothing'), for (final accessory in deskThings) (accessory, named(accessory))],
              locked: locked,
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
        _NapsGroup(host: host),
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
                for (final minutes in _minuteChoices(const [
                  1,
                  2,
                  3,
                  4,
                  5,
                  6,
                  8,
                  10,
                  15,
                  20,
                  30,
                  45,
                  60,
                ], settings.companionSleepAfterMinutes))
                  (minutes, '$minutes min'),
              ],
              onChanged: settings.companionVisibility == CompanionVisibility.never
                  ? null
                  : (value) => settings.companionSleepAfterMinutes = value,
            ),
            ActionsRow(
              children: [PaneLink(host: host, tab: SettingsTab.desktop, label: '$companion on the taskbar')],
            ),
          ],
        ),
        _FriendshipGroup(host: host),
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

  /// What each style does (the Mac's help under its menu-bar style picker).
  static String styleHelp(DesktopStyle style, {required String pet, required String patch, required String shortcut}) => switch (style) {
    DesktopStyle.roam =>
      '$pet strolls in the taskbar’s empty stretches, naps there, and stops to face you when Claude needs you. It never '
          'walks over a button, and clicks always go through to the taskbar except on $pet. While Claude works or waits '
          'for you, $pet stays beside $patch.',
    DesktopStyle.spot =>
      '$pet stays in one spot on the taskbar and plays there, in full colour: it sits, looks around, potters and naps '
          'without wandering off. Drag it along the taskbar to move its spot.',
    DesktopStyle.icon =>
      'The original icon, in the notification area: $pet blinks, a light pulses while Claude works and it hops when a turn '
          'completes. $pet stays off the taskbar; the desktop pet (if it shows) stands wherever you leave it.',
  };

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final pet = host.pet;
    final block = host.stroll?.block;
    final style = settings.petStyle;
    final roamNote = style.onTaskbar && block != null && block != RoamBlock.turnedOff ? block.note : null;
    final patch = host.patch;
    final name = host.companion;
    final never = settings.companionVisibility == CompanionVisibility.never;
    final shortcut = settings.shortcut(MochiShortcut.pet)?.label;
    // Patch is around and should be on the taskbar, but there's no stretch roomy enough for both right now.
    final noRoom =
        patch != null &&
        patch.visible &&
        settings.companionOnTaskbar &&
        style.onTaskbar &&
        (host.stroll?.onTaskbar ?? false) &&
        (!settings.companionOnlyMoments || (host.stroll?.interesting ?? true)) &&
        host.stroll?.home == null;
    final hide = shortcut == null ? 'the tray icon’s menu' : '$shortcut or the tray icon’s menu';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          footer: shortcut == null
              ? 'Show $pet again any time from the tray icon’s menu.'
              : 'Show or hide $pet any time with $shortcut, the tray icon’s menu, or right-click › Hide the desktop pet.',
          children: [
            ToggleRow(
              title: 'Show the desktop pet',
              subtitle: style.onTaskbar
                  ? '$pet lives on your taskbar, or stands on your desktop where you leave it, while Mochi’s window is closed.'
                  : '$pet stands on your desktop where you leave it, while Mochi’s window is closed.',
              value: settings.showPet,
              onChanged: (value) => settings.showPet = value,
            ),
            ShortcutRow(
              desktop: host.desktop,
              shortcut: MochiShortcut.pet,
              title: 'Shortcut to show or hide $pet',
              subtitle: 'Press it anywhere, in any app. The Mac’s is ⌃⌥⌘P; here it’s ${Hotkey.petDefault.label}.',
            ),
          ],
        ),
        SettingsGroup(
          title: 'Taskbar',
          children: [
            ChoiceRow<DesktopStyle>(
              label: 'Style',
              selected: style,
              onSelected: (value) => settings.petStyle = value,
              choices: const [
                (DesktopStyle.roam, 'Roams the taskbar', Icons.directions_walk_rounded),
                (DesktopStyle.spot, 'Plays in its spot', Icons.place_outlined),
                (DesktopStyle.icon, 'Classic tray icon', Icons.pets_outlined),
              ],
            ),
            TextRow(styleHelp(style, pet: pet, patch: name, shortcut: hide), secondary: true),
            if (style == DesktopStyle.spot)
              ChoiceRow<PetSize>(
                label: 'Room to play',
                selected: settings.spotRoom,
                onSelected: (value) => settings.spotRoom = value,
                choices: const [
                  (PetSize.small, 'Small', Icons.crop_square_rounded),
                  (PetSize.medium, 'Medium', Icons.crop_3_2_rounded),
                  (PetSize.large, 'Large', Icons.crop_16_9_rounded),
                ],
              ),
            if (style == DesktopStyle.spot && settings.spotX != null)
              ActionsRow(
                children: [OutlinedButton(onPressed: () => settings.spotX = null, child: const Text('Move Its Spot Back Beside the Tray'))],
              ),
            if (style == DesktopStyle.icon)
              ChoiceRow<TrayAnimation>(
                label: 'Icon animation',
                selected: settings.trayAnimation,
                onSelected: (value) => settings.trayAnimation = value,
                choices: const [
                  (TrayAnimation.off, 'Static', Icons.stop_circle_outlined),
                  (TrayAnimation.subtle, 'Subtle', Icons.blur_on_rounded),
                  (TrayAnimation.full, 'Expressive', Icons.auto_awesome_rounded),
                ],
              ),
            if (roamNote != null) NoteRow(text: roamNote),
            if (style.onTaskbar) ...[
              ToggleRow(
                title: '$name on the taskbar',
                subtitle:
                    'While $name is around, he keeps a little desk in an empty stretch beside $pet: he types while Claude '
                    'works, waves when Claude needs you and celebrates with $pet when it’s done, and now and then they '
                    'play or nap together.',
                value: settings.companionOnTaskbar,
                onChanged: settings.showPet && !never ? (value) => settings.companionOnTaskbar = value : null,
              ),
              ToggleRow(
                title: 'Only for interesting moments',
                subtitle:
                    '$name comes out for arrivals, Claude waiting for you, errors and celebrations, then leaves again so '
                    '$pet stays compact while you work.',
                value: settings.companionOnlyMoments,
                onChanged: settings.showPet && settings.companionOnTaskbar && !never
                    ? (value) => settings.companionOnlyMoments = value
                    : null,
              ),
            ],
            if (never)
              NoteRow(text: '$name is set never to show, in Characters.')
            else if (noRoom)
              NoteRow(text: 'There’s no stretch of the taskbar roomy enough for both right now, so $name waits in $pet’s room.'),
            if (never)
              ActionsRow(
                children: [PaneLink(host: host, tab: SettingsTab.characters, label: 'Show $name')],
              ),
          ],
        ),
        SettingsGroup(
          title: 'On the desktop',
          footer:
              '$pet stands on your desktop when it lives in the tray, when you drag it off the taskbar, or when the taskbar '
              'can’t hold it. It remembers where you left it on each display.',
          children: [
            ChoiceRow<PetSize>(
              label: 'Size',
              selected: settings.petSize,
              onSelected: (value) => settings.petSize = value,
              choices: const [
                (PetSize.small, 'Small', Icons.photo_size_select_small_rounded),
                (PetSize.medium, 'Medium', Icons.photo_size_select_large_rounded),
                (PetSize.large, 'Large', Icons.photo_size_select_actual_outlined),
              ],
            ),
            ToggleRow(
              title: 'Always on top',
              subtitle: settings.petOnTop ? '$pet stays above your windows.' : '$pet stays on the desktop, behind the windows you use.',
              value: settings.petOnTop,
              onChanged: (value) => settings.petOnTop = value,
            ),
            ToggleRow(
              title: 'Let clicks pass through $pet',
              subtitle: settings.petClickThrough
                  ? 'Clicks go to whatever is underneath, so $pet can’t be dragged or petted. Hide it with $hide.'
                  : 'Drag $pet to move it, click to pet it, right-click for options.',
              value: settings.petClickThrough,
              onChanged: (value) => settings.petClickThrough = value,
            ),
            ActionsRow(
              children: [
                OutlinedButton(
                  onPressed: settings.petPosition == null && settings.petPlaces.isEmpty ? null : settings.resetPetPosition,
                  child: const Text('Reset Position'),
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'Using $pet',
          children: [
            TextRow(
              'Click $pet to pet it (press and hold to keep it purring), double-click (or press Enter) to open Mochi, and '
              'right-click (or Shift+F10) for the menu. On the taskbar a click opens Mochi’s popover, and clicks go through to the taskbar everywhere but on '
              '$pet.',
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
      ],
    );
  }
}

// MARK: - Fun

class FunPane extends StatelessWidget {
  const FunPane({super.key, required this.host});

  final SettingsHost host;

  /// What's on now and what's next (the Mac's status line): "Diwali until 10 November. Next: Halloween from 24 October.
  /// Mochi's birthday is 8 November, the day you met."
  String _status(DateTime now) {
    final settings = host.desktop.settings;
    return w.SeasonCalendar.statusLine(
      now,
      settings: settings.worldSeasonal,
      adopted: settings.adoptedAt,
      petName: host.pet,
      formatDay: dayAndMonth,
    );
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
        _TalkingGroup(host: host),
        _TouchGroup(host: host),
        _GrowingUpGroup(host: host),
        _FocusGroup(host: host),
        _RecapGroup(host: host),
        _GamesGroup(host: host),
        _RoomGroup(host: host),
        SettingsGroup(
          title: 'Holidays',
          footer:
              'Halloween, Diwali, Christmas, New Year, Valentine’s Day, your birthday and $pet’s (the day $pet came to '
              'this PC, ${dayAndMonth(settings.adoptedAt)}). $pet and ${host.companion} greet each occasion once and '
              'wear a costume when you haven’t chosen something to wear, and treats are seasonal: candy, laddoos, '
              'gingerbread, cake and heart cookies.',
          children: [
            ToggleRow(
              title: 'Celebrate holidays with decorations, costumes and treats',
              value: enabled,
              onChanged: (value) => settings.holidays = value,
            ),
            ToggleRow(
              title: 'A little decoration beside ${host.companion}’s desk on the taskbar',
              subtitle: settings.companionVisibility == CompanionVisibility.never || !settings.companionOnTaskbar
                  ? 'It stands by ${host.companion}’s desk, so it shows while ${host.companion} keeps $pet company on the taskbar.'
                  : null,
              value: settings.decorateTaskbar && enabled,
              onChanged: enabled ? (value) => settings.decorateTaskbar = value : null,
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
        _AdventuresGroup(host: host),
      ],
    );
  }
}

/// Settings › Fun › Adventures (the Mac's AdventureSettingsSection): whether Mochi explores the desktop, how often it sets off
/// by itself, and Explore Now.
class _AdventuresGroup extends StatelessWidget {
  const _AdventuresGroup({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final adventure = settings.adventure;
    final pet = host.pet;
    return SettingsGroup(
      title: 'Adventures',
      footer:
          'Drag $pet up off the taskbar, or choose Explore. Out there it walks along window tops, sits on the taskbar and '
          'climbs the screen’s edge. Only where windows are is read — never what they show — and only while $pet is out.',
      children: [
        ToggleRow(
          title: '$pet explores the desktop',
          value: adventure.enabled,
          onChanged: (value) => settings.adventure = adventure.copyWith(enabled: value),
        ),
        ChoiceRow<AdventureFrequency>(
          label: 'Sets off by itself',
          selected: adventure.spontaneous,
          onSelected: adventure.enabled ? (value) => settings.adventure = adventure.copyWith(spontaneous: value) : null,
          choices: const [
            (AdventureFrequency.never, 'Never', Icons.block_rounded),
            (AdventureFrequency.rarely, 'Rarely', Icons.hourglass_bottom_rounded),
            (AdventureFrequency.sometimes, 'Sometimes', Icons.directions_walk_rounded),
          ],
        ),
        ActionsRow(
          children: [
            OutlinedButton(onPressed: adventure.enabled ? host.onExplore : null, child: const Text('Explore Now')),
          ],
        ),
      ],
    );
  }
}

/// Settings › Fun › Touch (the Mac's): press and hold Mochi to keep it purring; the Mac's trackpad purr is a soft purr
/// sound here.
class _TouchGroup extends StatelessWidget {
  const _TouchGroup({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final pet = host.pet;
    final sounds = settings.soundEnabled;
    return SettingsGroup(
      title: 'Touch',
      footer: 'Press and hold $pet on the taskbar, on the desktop or in its room: it keeps purring, with little purr lines at '
          'its sides, for as long as you hold on.',
      children: [
        ToggleRow(
          title: 'Purr sound while you hold $pet',
          subtitle: sounds ? null : 'Turn on Play sounds (Notifications › Sound) to hear it.',
          value: settings.purrSound && sounds,
          onChanged: sounds ? (value) => settings.purrSound = value : null,
        ),
      ],
    );
  }
}

/// Settings › Fun › Focus buddy (the Mac's FocusSettingsSection): the lengths, naps, the chime and the notification at
/// a break, and Start or Stop Focus.
class _FocusGroup extends StatelessWidget {
  const _FocusGroup({required this.host});

  final SettingsHost host;

  static List<(int, String)> _minutes(int from, int to, int step) => [for (var m = from; m <= to; m += step) (m, '$m min')];

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final focus = settings.focus;
    final buddy = host.desktop.focus;
    void set(FocusSettings value) => settings.focus = value;
    return ListenableBuilder(
      listenable: buddy,
      builder: (context, _) => SettingsGroup(
        title: 'Focus buddy',
        footer: settings.soundEnabled
            ? 'Changes apply to the next focus session. While you focus only the sounds for what needs you play.'
            : 'Turn on Play sounds (Notifications › Sound) to hear the chime. Changes apply to the next session.',
        children: [
          MenuRow<int>(
            label: 'Focus block',
            value: focus.workMinutes.clamp(5, 120),
            items: _minutes(5, 120, 5),
            onChanged: (value) => set(focus.copyWith(workMinutes: value)),
          ),
          MenuRow<int>(
            label: 'Short break',
            value: focus.breakMinutes.clamp(1, 30),
            items: _minutes(1, 30, 1),
            onChanged: (value) => set(focus.copyWith(breakMinutes: value)),
          ),
          MenuRow<int>(
            label: 'Long break',
            value: focus.longBreakMinutes.clamp(5, 60),
            items: _minutes(5, 60, 5),
            onChanged: (value) => set(focus.copyWith(longBreakMinutes: value)),
          ),
          MenuRow<int>(
            label: 'Long break after',
            value: focus.cyclesBeforeLongBreak.clamp(2, 8),
            items: [for (var n = 2; n <= 8; n++) (n, '$n blocks')],
            onChanged: (value) => set(focus.copyWith(cyclesBeforeLongBreak: value)),
          ),
          ToggleRow(
            title: '${host.pet} naps while you focus',
            value: focus.napsDuringFocus,
            onChanged: (value) => set(focus.copyWith(napsDuringFocus: value)),
          ),
          ToggleRow(
            title: 'Chime when a break starts',
            value: focus.chimeAtBreak && settings.soundEnabled,
            onChanged: settings.soundEnabled ? (value) => set(focus.copyWith(chimeAtBreak: value)) : null,
          ),
          ToggleRow(
            title: 'Show a notification when a break starts',
            value: focus.bannerAtBreak,
            onChanged: (value) => set(focus.copyWith(bannerAtBreak: value)),
          ),
          ActionsRow(
            children: [
              FilledButton(onPressed: buddy.toggle, child: Text(buddy.running ? 'Stop Focus' : 'Start Focus')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Settings › Fun › Daily recap (the Mac's RecapSettingsSection): the evening announcement, from which hour, a Windows
/// notification too, and Open Recap….
class _RecapGroup extends StatelessWidget {
  const _RecapGroup({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    final recap = settings.recap;
    final localizations = MaterialLocalizations.of(context);
    final twentyFour = MediaQuery.alwaysUse24HourFormatOf(context);
    String hour(int h) => localizations.formatTimeOfDay(TimeOfDay(hour: h, minute: 0), alwaysUse24HourFormat: twentyFour);
    void set(void Function(RecapSettings recap) change) {
      final next = settings.recap;
      change(next);
      settings.recap = next;
    }

    final open = host.onRecap;
    return SettingsGroup(
      title: 'Daily recap',
      footer: 'Once a day, only after real Claude Code activity. Cards use your history on this PC only.',
      children: [
        ToggleRow(
          title: 'Tell me when my day’s recap is ready',
          value: recap.announce,
          onChanged: (value) => set((r) => r.announce = value),
        ),
        MenuRow<int>(
          label: 'From',
          value: recap.hour.clamp(12, 23),
          items: [for (var h = 12; h < 24; h++) (h, hour(h))],
          onChanged: recap.announce ? (value) => set((r) => r.hour = value) : null,
        ),
        ToggleRow(
          title: 'Also show a notification',
          value: recap.banner,
          onChanged: recap.announce ? (value) => set((r) => r.banner = value) : null,
        ),
        if (open != null) ActionsRow(children: [FilledButton(onPressed: open, child: const Text('Open Recap…'))]),
      ],
    );
  }
}

/// Settings › Fun › Room (the Mac's RoomSettingsSection): what's placed (each can be put away), how much is unlocked,
/// Decorate… and Clear Room.
class _RoomGroup extends StatelessWidget {
  const _RoomGroup({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final desktop = host.desktop;
    return ListenableBuilder(
      listenable: Listenable.merge([desktop.room, desktop.world]),
      builder: (context, _) {
        final room = desktop.settings.room;
        final progress = desktop.world.world.progress;
        final decorate = host.onDecorate;
        return SettingsGroup(
          title: 'Room',
          footer: room.summary(progress),
          children: [
            if (room.items.isEmpty)
              NoteRow(text: 'Nothing placed yet. Click Decorate in the popover or below, and drag furniture into the room.'),
            for (final item in room.items)
              if (FurnitureCatalog.kind(item.kind) case final kind?)
                MergeSemantics(
                  child: Padding(
                    padding: rowPadding,
                    child: Row(
                      children: [
                        ExcludeSemantics(child: FurnitureIcon(kind: kind)),
                        const SizedBox(width: Space.s),
                        Expanded(child: Text(kind.title, style: context.type.subheadline)),
                        IconButton(
                          tooltip: 'Remove ${kind.title}',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => desktop.room.remove(item.id),
                          icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
            ActionsRow(
              children: [
                if (decorate != null) FilledButton(onPressed: decorate, child: const Text('Decorate…')),
                OutlinedButton(onPressed: room.items.isEmpty ? null : desktop.room.clear, child: const Text('Clear Room')),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Settings › Fun › Games (the Mac's GamesSettingsSection): the records, Play… and Reset Records….
class _GamesGroup extends StatelessWidget {
  const _GamesGroup({required this.host});

  final SettingsHost host;

  Future<void> _reset(BuildContext context) async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset all game records?',
      message: 'High scores and win counts start over. This can’t be undone.',
      confirm: 'Reset Records',
      destructive: true,
    );
    if (confirmed) host.desktop.games.resetRecords();
  }

  @override
  Widget build(BuildContext context) {
    final records = host.desktop.settings.games;
    final play = host.onGames;
    return SettingsGroup(
      title: 'Games',
      footer: 'Catch the Treats and rock-paper-scissors with ${host.pet}${host.desktop.games.companionPlays ? ' and ${host.companion}' : ''}. '
          'Records stay on this PC.',
      children: [
        InfoRow(label: 'Catch the Treats', value: records.catchSummary),
        InfoRow(label: 'Rock, paper, scissors', value: records.rpsSummary),
        ActionsRow(
          children: [
            if (play != null) FilledButton(onPressed: play, child: const Text('Play…')),
            OutlinedButton(onPressed: records.isEmpty ? null : () => _reset(context), child: const Text('Reset Records…')),
          ],
        ),
      ],
    );
  }
}

/// Settings › Fun › Talking (the Mac's): Mochi and Patch say a word now and then in speech bubbles, as chatty as you
/// like, and (with Claude Code on this PC) now and then a fresh line from Claude Haiku.
class _TalkingGroup extends StatefulWidget {
  const _TalkingGroup({required this.host});

  final SettingsHost host;

  @override
  State<_TalkingGroup> createState() => _TalkingGroupState();
}

class _TalkingGroupState extends State<_TalkingGroup> {
  /// Where Claude Code is on this PC (fresh lines need it), looked for once.
  late final String? _claude = widget.host.desktop.locateClaude();

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final settings = host.desktop.settings;
    final pet = host.pet;
    final talking = settings.speechEnabled;
    return SettingsGroup(
      title: 'Talking',
      footer: switch (settings.chattiness) {
        Chattiness.quiet => 'Quiet: only what matters (Claude needs you, a finished turn, green tests).',
        Chattiness.normal => 'Greetings, Claude’s moments, petting and the odd sleepy mumble.',
        Chattiness.chatty => 'Chatty: more often, and musings while nothing’s going on.',
      },
      children: [
        ToggleRow(
          title: '$pet and ${host.companion} talk in speech bubbles',
          value: talking,
          onChanged: (value) => settings.speechEnabled = value,
        ),
        ChoiceRow<Chattiness>(
          label: 'Chattiness',
          selected: settings.chattiness,
          onSelected: talking ? (value) => settings.chattiness = value : null,
          choices: const [
            (Chattiness.quiet, 'Quiet', Icons.volume_mute_rounded),
            (Chattiness.normal, 'Normal', Icons.chat_bubble_outline_rounded),
            (Chattiness.chatty, 'Chatty', Icons.forum_rounded),
          ],
        ),
        ToggleRow(
          title: 'Fresh lines from Claude Haiku',
          subtitle: _claude == null
              ? 'Needs Claude Code on this PC (Settings › Claude Code).'
              : 'Now and then a line written for the moment, through Claude Code on this PC, every couple of hours while '
                    'it’s on. Only the kind of moment is sent, never anything about your work.',
          value: settings.speechFreshLines && _claude != null,
          onChanged: talking && _claude != null ? (value) => settings.speechFreshLines = value : null,
        ),
      ],
    );
  }
}

/// The Mac's five hearts: filled up to the friendship level.
class FriendshipHearts extends StatelessWidget {
  const FriendshipHearts({super.key, required this.level, this.size = 14});

  final int level;
  final double size;

  /// Hearts there are (levels 0–5).
  static const int count = 5;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Icon(
              i < level ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: size,
              color: i < level ? p.pet : p.inkSecondary.withValues(alpha: 0.6),
            ),
        ],
      ),
    );
  }
}

/// "8 November 2026".
String fullDate(DateTime date) => '${date.day} ${monthNames[date.month - 1]} ${date.year}';

/// Settings › Characters › Friendship (the Mac's): the hearts and points, how they're earned, every achievement with
/// what it takes and what it unlocks, and Reset Progress.
class _FriendshipGroup extends StatelessWidget {
  const _FriendshipGroup({required this.host});

  final SettingsHost host;

  Future<void> _reset(BuildContext context) async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset friendship and achievements?',
      message: 'The hearts, the points and every achievement start again, on this PC. Nothing else changes.',
      confirm: 'Reset',
      destructive: true,
    );
    if (confirmed) host.desktop.world.resetProgress();
  }

  @override
  Widget build(BuildContext context) {
    final world = host.desktop.world;
    return ListenableBuilder(
      listenable: world,
      builder: (context, _) {
        final progress = world.world.progress;
        final level = progress.friendshipLevel;
        final p = context.palette;
        return SettingsGroup(
          title: 'Friendship',
          footer:
              'Petting, playing and treats earn a few points a day (with daily caps). Points never go down, and nothing bad '
              'happens if you’re away.',
          children: [
            MergeSemantics(
              child: Padding(
                padding: rowPadding,
                child: Wrap(
                  spacing: Space.m,
                  runSpacing: Space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Friendship level', style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                    Semantics(
                      label: 'level $level of ${FriendshipHearts.count}',
                      child: FriendshipHearts(level: level),
                    ),
                    Text('${progress.affectionPoints} points', style: context.type.footnote),
                  ],
                ),
              ),
            ),
            for (final id in AchievementID.values) _AchievementRow(id: id, progress: progress),
            ActionsRow(
              children: [
                OutlinedButton(
                  onPressed: () => _reset(context),
                  style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                  child: const Text('Reset Progress…'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// One achievement: earned or not, what it takes, what it unlocks, and when it was earned.
class _AchievementRow extends StatelessWidget {
  const _AchievementRow({required this.id, required this.progress});

  final AchievementID id;
  final ProgressState progress;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final at = progress.unlocked[id.name];
    final reward = id.reward;
    final detail = id.criteria + (reward == null ? '' : ' Unlocks: ${reward.title}.');
    // Read as one: the achievement, what it takes, and whether (and when) it was earned.
    return Semantics(
      container: true,
      label: '${id.title}. $detail ${at == null ? 'Not earned yet.' : 'Earned on ${fullDate(at.toLocal())}.'}',
      excludeSemantics: true,
      child: Padding(
        padding: rowPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(at == null ? Icons.verified_outlined : Icons.verified_rounded, size: 20, color: at == null ? p.inkSecondary : p.success),
            const SizedBox(width: Space.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(id.title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                  Text(detail, style: context.type.caption),
                ],
              ),
            ),
            if (at != null) ...[const SizedBox(width: Space.s), Text(fullDate(at.toLocal()), style: context.type.caption)],
          ],
        ),
      ),
    );
  }
}

/// Settings › Fun › Growing up (the Mac's): Mochi grows from a kitten as your friendship grows, and what it takes next.
class _GrowingUpGroup extends StatelessWidget {
  const _GrowingUpGroup({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final world = host.desktop.world;
    final settings = host.desktop.settings;
    final pet = host.pet;
    return ListenableBuilder(
      listenable: world,
      builder: (context, _) {
        final stage = world.stage;
        final next = settings.lifeStages ? LifeStage.nextStep(world.world.progress, host.now) : null;
        final now = switch (stage) {
          LifeStage.kitten => '$pet is a kitten.',
          LifeStage.young => '$pet is a young cat.',
          LifeStage.grownUp => settings.lifeStages ? '$pet is all grown up.' : '$pet is drawn grown up.',
        };
        return SettingsGroup(
          title: 'Growing up',
          footer: 'Kitten, then young, then grown-up as your friendship grows. It never goes backwards.',
          children: [
            ToggleRow(title: '$pet grows up over time', value: settings.lifeStages, onChanged: (value) => settings.lifeStages = value),
            NoteRow(text: next == null ? now : '$now $next.', icon: Icons.pets_rounded),
          ],
        );
      },
    );
  }
}
