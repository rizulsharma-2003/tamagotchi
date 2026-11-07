// Settings › Phones & alerts: Phones (Mochi Link: the relay, the devices by name, pairing, a test, unpairing; talking
// from your phones; Claude's summaries) and Notifications (which of Claude's moments Mochi reacts to). The Mac's
// PhoneSettingsView and NotificationSettings; device names come from mochi_link's LinkPeerNames, as on every device.

import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';

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
              if (lastSummary != null) NoteRow(text: lastSummary, icon: Icons.chat_bubble_outline_rounded),
              SoonRow(
                title: 'Only when I’m away from this PC',
                detail: 'Notifying your phones only while you’re away from the computer works with a Mac for now.',
              ),
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

class NotificationsPane extends StatelessWidget {
  const NotificationsPane({super.key, required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = host.desktop.settings;
    final link = host.desktop.link;
    final pet = host.pet;
    final paused = settings.pauseReactions;
    final phones = LinkPeerNames.phones(link.peers, me: link.credentials?.device);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'On this PC',
          children: [
            if (paused) ...[
              NoteRow(text: 'Reactions are paused (General › Reactions).', icon: Icons.pause_circle_outline_rounded, tint: p.warning),
              ActionsRow(children: [OutlinedButton(onPressed: () => settings.pauseReactions = false, child: const Text('Resume Reactions'))]),
            ],
            ToggleRow(
              title: 'Celebrate when Claude finishes',
              subtitle: '$pet bounces and says “Claude finished!”, on the desktop and on the taskbar.',
              value: settings.celebrateFinished,
              onChanged: paused ? null : (value) => settings.celebrateFinished = value,
            ),
            ToggleRow(
              title: 'Worry when a turn fails',
              subtitle: '$pet looks concerned and says “Claude hit a snag”.',
              value: settings.showSnags,
              onChanged: paused ? null : (value) => settings.showSnags = value,
            ),
            StatusRow(
              title: 'When Claude needs you',
              ok: true,
              icon: Icons.front_hand_outlined,
              tint: p.tint,
              detail: '$pet keeps a bubble up until you answer',
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
        SettingsGroup(
          title: 'From the Mac',
          children: [
            SoonRow(
              title: 'Windows notifications',
              detail: 'Banners in the notification centre when Claude finishes or needs you. For now $pet’s bubble and your phones tell you.',
            ),
            SoonRow(title: 'Sounds', detail: 'A soft chime for Claude’s moments, and tiny keyboard taps while Claude works.'),
            SoonRow(title: 'Quiet hours', detail: 'Times when nothing makes a sound or shows a banner.'),
          ],
        ),
      ],
    );
  }
}
