// Settings › Phones & alerts: Phones (Mochi Link: the relay, the devices by name, pairing, a test, unpairing; talking
// from your phones; Claude's summaries) and Notifications (which of Claude's moments Mochi reacts to). The Mac's
// PhoneSettingsView and NotificationSettings; device names come from mochi_link's LinkPeerNames, as on every device.

import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/notifications.dart';
import '../../core/toasts.dart';
import '../../link/link_host.dart';
import 'panes_claude.dart' show ago;
import 'settings_kit.dart';
import 'settings_tabs.dart';

/// The paired phones by name ("Rizul's iPhone and Pixel 8"), or "your phones".
String phoneNames(LinkHost link) => LinkPeerNames.phoneNames(link.peers, me: link.credentials?.device);

// MARK: - Phones

class PhonesPane extends StatelessWidget {
  const PhonesPane({super.key, required this.host});

  final SettingsHost host;

  Future<void> _unpair(BuildContext context) async {
    final link = host.desktop.link;
    final names = phoneNames(link);
    final confirmed = await confirmAction(
      context,
      title: 'Unpair this PC from Mochi Link?',
      message:
          'This deletes the link on your relay: ${names == LinkPeerNames.yourPhones ? 'your phones are' : '$names are'} cut off, '
          'and their old keys stop working. Nothing reaches your phones until you pair again with a new code.',
      confirm: 'Unpair',
      destructive: true,
    );
    if (confirmed) await link.unpair();
  }

  void _sendTest(BuildContext context) {
    host.desktop.phone.sendTestNotification();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Sent a test to ${phoneNames(host.desktop.link)}.'), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([host.desktop.link, host.desktop.ask]),
    builder: (context, _) {
      final p = context.palette;
      final desktop = host.desktop;
      final settings = desktop.settings;
      final link = desktop.link;
      final pet = host.pet;
      final me = link.credentials?.device;
      final phones = LinkPeerNames.phones(link.peers, me: me);
      final names = phoneNames(link);
      final iPhone = phones.where((peer) => peer.linkPlatform == LinkPlatform.iOS).firstOrNull;
      final lastCommand = desktop.ask.exchanges.where((exchange) => exchange.fromPhone).lastOrNull;
      final lastSummary = desktop.phone.lastSummary;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsGroup(
            title: 'Mochi Link',
            footer: link.paired
                ? 'Messages between this PC and your phones go through your own relay in under a second, end-to-end '
                      'encrypted: the relay passes them on, and wakes your phones, but can’t read them. The link is kept '
                      'with ${link.vaultDescription}.'
                : 'Your phones reach this PC only through Mochi Link, your own end-to-end encrypted relay. Pair once by '
                      'scanning a code with Mochi on your iPhone or Android phone; until then, nothing from this PC goes to '
                      'your phones.',
            children: [
              if (link.paired) ...[
                StatusRow(
                  title: 'Relay',
                  ok: link.status == LinkStatus.online,
                  icon: Icons.hub_outlined,
                  tint: link.status == LinkStatus.online ? p.success : null,
                  detail: switch (link.status) {
                    LinkStatus.online => 'Connected',
                    LinkStatus.connecting => 'Connecting…',
                    LinkStatus.offline => 'Offline, retrying',
                    LinkStatus.removed => 'The link was removed: pair again',
                  },
                ),
                if (phones.isEmpty) const StatusRow(title: 'Your phones', ok: false, detail: 'None paired yet'),
                for (final peer in link.devices) _DeviceRow(peer: peer, now: host.now),
              ] else
                const StatusRow(title: 'Your phones', ok: false, detail: 'Not paired'),
              if (link.problem != null)
                NoteRow(text: link.problem!, icon: Icons.warning_amber_rounded, tint: p.warning, textColor: p.warning),
              ActionsRow(
                children: [
                  FilledButton.icon(
                    onPressed: link.working ? null : host.onPair,
                    icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                    label: const Text('Pair a Phone…'),
                  ),
                  if (link.paired) ...[
                    Tooltip(
                      message: phones.isEmpty ? 'Pair a phone first' : 'Every paired phone gets it: $names',
                      child: OutlinedButton(
                        onPressed: link.status == LinkStatus.online && phones.isNotEmpty ? () => _sendTest(context) : null,
                        child: const Text('Send a Test to All Phones'),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () => _unpair(context),
                      style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                      child: const Text('Unpair This PC…'),
                    ),
                  ],
                ],
              ),
            ],
          ),
          SettingsGroup(
            title: 'Talking from your phones',
            children: [
              ToggleRow(
                title: 'Run what I tell $pet on my phones',
                subtitle:
                    'Type to $pet on any phone: your words reach this PC through Mochi Link and run in Ask $pet exactly as '
                    'if you typed them here.',
                value: settings.acceptCommands,
                onChanged: (value) => settings.acceptCommands = value,
              ),
              if (lastCommand != null) NoteRow(text: 'Last: “${lastCommand.text}”', icon: Icons.smartphone_rounded),
              SoonRow(
                title: 'Replies to one Claude session',
                detail: 'Sending a session its next request from a phone, with an approval first, works with a Mac for now.',
              ),
            ],
          ),
          SettingsGroup(
            title: 'Claude’s summaries',
            children: [
              ToggleRow(
                title: 'Send Claude’s summaries to my phones',
                subtitle:
                    'When a Claude session finishes, your phones get a notification with the project, the files Claude '
                    'changed and a short summary of what it said, written by Claude Haiku on this PC. While this is off, '
                    'or while no phone is paired, none of Claude’s words leave this PC.',
                value: settings.shareSummaries,
                onChanged: (value) => settings.shareSummaries = value,
              ),
              if (settings.shareSummaries && !link.paired)
                const NoteRow(text: 'Pair a phone (Mochi Link, above) to get them.', icon: Icons.link_rounded),
              ToggleRow(
                title: 'Only notify me when I’m away from this PC',
                subtitle:
                    'Your phones ring for a finished turn only after 3 minutes without typing or clicking here, or while this '
                    'PC is locked or its display is off. The sessions on your phones stay up to date either way.',
                value: settings.notifyOnlyWhenAway,
                onChanged: settings.shareSummaries ? (value) => settings.notifyOnlyWhenAway = value : null,
              ),
              if (settings.shareSummaries && settings.notifyOnlyWhenAway && !desktop.rhythm.available)
                const NoteRow(text: 'Mochi can’t tell whether you’re at this computer here, so every summary is sent.', icon: Icons.info_outline_rounded),
              if (lastSummary != null) NoteRow(text: lastSummary, icon: Icons.chat_bubble_outline_rounded),
            ],
          ),
          if (iPhone != null)
            SettingsGroup(
              title: 'Live Activity',
              children: [
                NoteRow(
                  icon: Icons.phone_iphone_rounded,
                  text:
                      'The Live Activity on ${LinkPeerNames.row(iPhone)} needs Mochi on a Mac; from this PC it gets '
                      'notifications and $pet’s room.',
                ),
              ],
            ),
        ],
      );
    },
  );
}

/// One device in the link: its name and system, and whether it's there (Mochi Cloud: when it last checked).
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.peer, required this.now});

  final LinkPeer peer;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final platform = peer.linkPlatform;
    final seen = peer.lastSeenTime;
    final cloud = peer.role == 'cloud' || platform == LinkPlatform.cloud;
    final icon = switch (platform) {
      LinkPlatform.iOS => Icons.phone_iphone_rounded,
      LinkPlatform.android => Icons.phone_android_rounded,
      LinkPlatform.macOS || LinkPlatform.windows => Icons.computer_rounded,
      LinkPlatform.cloud => Icons.cloud_outlined,
      null => cloud ? Icons.cloud_outlined : (peer.role == 'host' ? Icons.computer_rounded : Icons.smartphone_rounded),
    };
    if (cloud) {
      // The cloud never stays connected: it posts when a check runs, so "away" would look like a fault.
      return StatusRow(
        title: peer.name ?? 'Mochi Cloud',
        ok: seen != null,
        icon: icon,
        tint: seen != null ? context.palette.success : null,
        detail: seen == null ? 'Hasn’t checked in yet' : 'Last check ${ago(seen, now)}',
      );
    }
    return StatusRow(
      title: LinkPeerNames.row(peer),
      ok: peer.online,
      icon: icon,
      tint: peer.online ? context.palette.success : null,
      detail: peer.online ? 'Online' : (seen == null ? 'Away' : 'Away · ${ago(seen, now)}'),
    );
  }
}

// MARK: - Notifications

/// The Mac's NotificationSettings: sound, Windows notifications (the Mac's Notification Center) and, per category,
/// whether Mochi animates, wears a badge, shows a Windows notification and plays a sound. Then what the phones get.
class NotificationsPane extends StatefulWidget {
  const NotificationsPane({super.key, required this.host});

  final SettingsHost host;

  @override
  State<NotificationsPane> createState() => _NotificationsPaneState();
}

class _NotificationsPaneState extends State<NotificationsPane> {
  @override
  void initState() {
    super.initState();
    // Windows Settings may have changed while Mochi's Settings was closed.
    widget.host.desktop.toasts.refresh();
  }

  void _refresh() => setState(widget.host.desktop.toasts.refresh);

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final p = context.palette;
    final desktop = host.desktop;
    final settings = desktop.settings;
    final link = desktop.link;
    final pet = host.pet;
    final paused = settings.pauseReactions;
    final phones = LinkPeerNames.phones(link.peers, me: link.credentials?.device);
    final output = desktop.sounds.output;
    final toasts = desktop.toasts.availability;
    final quiet = settings.quietHours;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (paused || settings.quietMode)
          SettingsGroup(
            children: [
              if (paused) ...[
                NoteRow(
                  text: 'Reactions are paused (General › Reactions): $pet doesn’t react, and nothing plays a sound or shows a notification.',
                  icon: Icons.pause_circle_outline_rounded,
                  tint: p.warning,
                ),
                ActionsRow(children: [OutlinedButton(onPressed: () => settings.pauseReactions = false, child: const Text('Resume Reactions'))]),
              ] else ...[
                NoteRow(text: 'Quiet mode is on (General › Reactions): no sounds and no notifications.', icon: Icons.do_not_disturb_on_outlined, tint: p.warning),
                ActionsRow(children: [OutlinedButton(onPressed: () => settings.quietMode = false, child: const Text('Turn Off Quiet Mode'))]),
              ],
            ],
          ),
        SettingsGroup(
          title: 'Sound',
          children: [
            ToggleRow(
              title: 'Play sounds',
              subtitle: 'Soft chimes made by $pet for Claude’s moments, with each one’s Sound below.',
              value: settings.soundEnabled,
              onChanged: (value) => settings.soundEnabled = value,
            ),
            _VolumeRow(host: host),
            ToggleRow(
              title: 'Tiny keyboard taps while Claude edits or runs commands',
              value: settings.workSounds,
              onChanged: settings.soundEnabled ? (value) => settings.workSounds = value : null,
            ),
            if (!output.supported)
              const NoteRow(text: 'Sounds play in Mochi for Windows.', icon: Icons.info_outline_rounded)
            else if (!output.systemSoundsOn)
              NoteRow(
                text: 'Windows’ sound scheme is “No Sounds” (Settings › System › Sound › More sound settings), so $pet stays silent too.',
                icon: Icons.volume_off_rounded,
                tint: p.warning,
                textColor: p.warning,
              ),
          ],
        ),
        SettingsGroup(
          title: 'Windows notifications',
          footer:
              'Banners are off for every category by default. Repeated events are batched, and nothing is sent for '
              'simulated or late events. Clicking one opens the session in Mochi’s window.',
          children: [
            StatusRow(
              title: 'Notifications from $pet',
              ok: toasts.works,
              icon: toasts.works ? Icons.notifications_active_rounded : Icons.notifications_off_outlined,
              tint: toasts.works ? p.success : null,
              detail: switch (toasts) {
                ToastAvailability.ready => 'Allowed',
                ToastAvailability.notInstalled => 'Needs Mochi installed',
                ToastAvailability.offForMochi => 'Off for Mochi in Windows Settings',
                ToastAvailability.offForAll => 'Off in Windows Settings',
                ToastAvailability.failed => 'Windows refused them',
                ToastAvailability.unsupported => 'Mochi for Windows only',
              },
            ),
            if (toasts == ToastAvailability.notInstalled) ...[
              const NoteRow(
                text:
                    'Mochi is running from where you downloaded it. Windows only shows notifications from an installed app '
                    '(with its Start menu entry), so they can’t work reliably until Mochi is installed.',
                icon: Icons.download_rounded,
              ),
              if (host.onInstall != null)
                ActionsRow(children: [FilledButton(onPressed: host.onInstall, child: const Text('Install Mochi…'))]),
            ],
            if (toasts == ToastAvailability.offForMochi || toasts == ToastAvailability.offForAll)
              ActionsRow(
                children: [
                  OutlinedButton(onPressed: () => desktop.toasts.openSystemSettings().ignore(), child: const Text('Open Notification Settings')),
                  TextButton(onPressed: _refresh, child: const Text('Check Again')),
                ],
              ),
            if (toasts == ToastAvailability.failed)
              NoteRow(text: 'Restart Mochi to try again. $pet’s bubble and your phones still tell you.', icon: Icons.warning_amber_rounded),
            StatusRow(
              title: 'Quiet hours',
              ok: quiet.enabled,
              icon: Icons.bedtime_outlined,
              tint: quiet.enabled ? p.tint : null,
              detail: quiet.enabled ? '${QuietHours.format(quiet.startMinute)}–${QuietHours.format(quiet.endMinute)}' : 'Off',
            ),
            ActionsRow(children: [PaneLink(host: host, tab: SettingsTab.general, label: 'Quiet hours and quiet mode')]),
          ],
        ),
        SettingsGroup(
          title: 'Per category',
          children: [
            _DeliveryGrid(host: host),
            ActionsRow(
              children: [
                OutlinedButton(onPressed: settings.deliveryAtDefaults ? null : settings.restoreDeliveryDefaults, child: const Text('Restore Defaults')),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'On your phones',
          children: [
            StatusRow(
              title: 'Claude finished',
              ok: settings.shareSummaries && link.paired,
              detail: !link.paired
                  ? 'No phone paired'
                  : settings.shareSummaries
                  ? 'A notification with the summary on ${phones.isEmpty ? 'your phones' : phoneNames(link)}'
                  : 'Off: turn on Claude’s summaries',
            ),
            ActionsRow(children: [PaneLink(host: host, tab: SettingsTab.phones)]),
          ],
        ),
      ],
    );
  }
}

/// The volume: a slider between two speakers, and Test (the Mac's success chime).
class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = host.desktop.settings;
    final enabled = settings.soundEnabled && host.desktop.sounds.output.supported;
    return Padding(
      padding: rowPadding,
      child: Row(
        children: [
          ExcludeSemantics(child: Icon(Icons.volume_down_rounded, size: 18, color: p.inkSecondary)),
          Expanded(
            child: Slider(
              value: settings.soundVolume,
              label: '${(settings.soundVolume * 100).round()}%',
              semanticFormatterCallback: (value) => 'Volume ${(value * 100).round()}%',
              onChanged: enabled ? (value) => settings.soundVolume = value : null,
            ),
          ),
          ExcludeSemantics(child: Icon(Icons.volume_up_rounded, size: 18, color: p.inkSecondary)),
          const SizedBox(width: Space.s),
          OutlinedButton(onPressed: enabled ? host.desktop.reactions.testSound : null, child: const Text('Test')),
        ],
      ),
    );
  }
}

/// Each category's Animate, Badge, Banner and Sound (the Mac's grid of checkboxes). Side by side when there's room;
/// at large text sizes each category's four come under its name.
class _DeliveryGrid extends StatelessWidget {
  const _DeliveryGrid({required this.host});

  final SettingsHost host;

  static const List<String> columns = ['Animate', 'Badge', 'Banner', 'Sound'];
  static const double cell = 66;

  @override
  Widget build(BuildContext context) {
    final desktop = host.desktop;
    final settings = desktop.settings;
    final toasts = desktop.toasts.availability.works;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 520 && MediaQuery.textScalerOf(context).scale(14) <= 18;
        final rows = <Widget>[
          if (wide)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.m + 2, Space.s, Space.m + 2, 0),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    for (final column in columns)
                      SizedBox(width: cell, child: Text(column, textAlign: TextAlign.center, style: context.type.caption)),
                  ],
                ),
              ),
            ),
          for (final category in NotificationCategory.values)
            _CategoryRow(
              category: category,
              delivery: settings.delivery(category),
              wide: wide,
              enabled: [
                category.availableOnWindows,
                category.availableOnWindows && category.allowsBadge,
                category.availableOnWindows && category.allowsBanner && toasts,
                category.availableOnWindows && settings.soundEnabled,
              ],
              onChanged: (delivery) => settings.setDelivery(category, delivery),
            ),
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, required this.delivery, required this.wide, required this.enabled, required this.onChanged});

  final NotificationCategory category;
  final CategoryDelivery delivery;
  final bool wide;

  /// Animate, Badge, Banner, Sound.
  final List<bool> enabled;
  final ValueChanged<CategoryDelivery> onChanged;

  @override
  Widget build(BuildContext context) {
    final values = [delivery.animate, delivery.badge, delivery.banner, delivery.sound];
    CategoryDelivery changed(int index, bool value) => switch (index) {
      0 => delivery.copyWith(animate: value),
      1 => delivery.copyWith(badge: value),
      2 => delivery.copyWith(banner: value),
      _ => delivery.copyWith(sound: value),
    };
    Widget box(int index) => Semantics(
      label: '${category.title}: ${_DeliveryGrid.columns[index]}',
      child: Checkbox(
        value: values[index] && enabled[index],
        onChanged: enabled[index] ? (value) => onChanged(changed(index, value ?? false)) : null,
      ),
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.s,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(category.title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
            if (!category.availableOnWindows) Tag(text: SoonRow.tag, icon: Icons.schedule_rounded, tint: context.palette.inkSecondary),
          ],
        ),
        const SizedBox(height: 2),
        Text(category.explanation, style: context.type.caption),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.m + 2, vertical: Space.xs),
      child: wide
          ? Row(
              children: [
                Expanded(child: title),
                for (var index = 0; index < 4; index++) SizedBox(width: _DeliveryGrid.cell, child: Center(child: box(index))),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                Wrap(
                  spacing: Space.s,
                  children: [
                    for (var index = 0; index < 4; index++)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [box(index), ExcludeSemantics(child: Text(_DeliveryGrid.columns[index], style: context.type.caption))],
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}
