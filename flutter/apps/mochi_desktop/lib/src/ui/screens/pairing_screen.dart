import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../link/link_host.dart';
import '../widgets/qr_code.dart';

/// Pair a Phone (Settings › Phones › Pair a Phone…, as on the Mac): this PC's room on Mochi Link, a QR code and a
/// copyable link for the phone, the devices in the room by name with who's online, and Unpair (deletes the room). The
/// words match what the phones say ("On your Mac or PC: open Mochi's Settings › Phones › Pair a Phone").
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.link, this.onTestNotification, this.clock});

  final LinkHost link;

  /// Sends a sealed test notification to the phones.
  final VoidCallback? onTestNotification;
  final DateTime Function()? clock;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  Timer? _tick;
  bool _copied = false;

  LinkHost get link => widget.link;
  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    link.requestDevices();
    // The expiry countdown, and a fresh device list now and then.
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timer.tick % 15 == 0) link.requestDevices();
      if (mounted && link.code != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _copy(PairingCode code) async {
    await Clipboard.setData(ClipboardData(text: code.url));
    if (!mounted) return;
    setState(() => _copied = true);
    SemanticsService.announce('Pairing link copied', TextDirection.ltr);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Unpair this PC from Mochi Link?'),
        content: Text(
          'This deletes the link on your relay: ${LinkPeerNames.phoneNames(link.peers, me: link.credentials?.device)} '
          'stop getting news from this PC, and their old keys stop working. Nothing reaches your phones until you pair '
          'again with a new code.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed == true) await link.unpair();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: link,
    builder: (context, _) {
      final p = context.palette;
      final code = link.code;
      final devices = link.devices;
      return Scrollbar(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.l, Space.xl),
          children: [
            ClayCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(code == null ? 'Pair your phone with this PC' : 'Scan this with your phone', style: context.type.title3),
                  const SizedBox(height: Space.xs),
                  Text(
                    code == null
                        ? 'Mochi on your iPhone or Android phone joins this PC through Mochi Link. It is end-to-end encrypted: '
                              'the relay only passes sealed messages along, and only your devices can open them.'
                        : 'On your iPhone or Android phone, open Mochi, tap Scan the Code and point it at this code. Or copy '
                              'the link and tap Paste Link on the phone.',
                    style: context.type.subheadline,
                  ),
                  const SizedBox(height: Space.l),
                  if (code != null) ..._code(context, code) else _makeCodeButton(),
                  if (link.problem != null) ...[
                    const SizedBox(height: Space.m),
                    NoteLabel(text: link.problem!, icon: Icons.error_outline_rounded, tint: p.danger, textColor: p.danger),
                  ],
                ],
              ),
            ),
            if (link.paired) ...[
              const SizedBox(height: Space.m),
              SectionTitle(title: 'Devices', note: _statusNote()),
              const SizedBox(height: Space.s),
              ClayCard(
                padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
                child: devices.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.s),
                        child: NoteLabel(text: 'No phone has joined yet.', icon: Icons.smartphone_rounded),
                      )
                    : Column(
                        children: [for (final device in devices) _DeviceRow(peer: device, now: _now)],
                      ),
              ),
              const SizedBox(height: Space.m),
              Wrap(
                spacing: Space.s,
                runSpacing: Space.s,
                children: [
                  if (widget.onTestNotification != null && devices.any((peer) => peer.role == 'pocket'))
                    OutlinedButton.icon(
                      onPressed: widget.onTestNotification,
                      icon: const Icon(Icons.notifications_active_outlined, size: 18),
                      label: const Text('Send a Test to All Phones'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _unpair,
                    style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Unpair This PC…'),
                  ),
                ],
              ),
              const SizedBox(height: Space.s),
              NoteLabel(text: 'The link is kept with ${link.vaultDescription}.', icon: Icons.lock_outline_rounded),
            ],
          ],
        ),
      );
    },
  );

  String _statusNote() => switch (link.status) {
    LinkStatus.online => 'Connected',
    LinkStatus.connecting => 'Connecting…',
    LinkStatus.offline => 'Not connected',
    LinkStatus.removed => 'Room removed: pair again',
  };

  Widget _makeCodeButton() => Align(
    alignment: Alignment.centerLeft,
    child: FilledButton.icon(
      autofocus: true,
      onPressed: link.working ? null : link.showCode,
      icon: link.working
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Making a code'))
          : const Icon(Icons.qr_code_2_rounded, size: 18),
      label: const Text('Pair a Phone…'),
    ),
  );

  List<Widget> _code(BuildContext context, PairingCode code) {
    final expires = link.codeExpires;
    final left = expires == null ? null : expires.difference(_now);
    final minutes = left == null ? null : (left.inSeconds / 60).ceil().clamp(0, 10);
    return [
      Center(child: QrCodeView(data: code.url, size: 228)),
      const SizedBox(height: Space.m),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
        decoration: BoxDecoration(color: context.palette.sunken, borderRadius: BorderRadius.circular(Radii.inner)),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label: 'Pairing link',
                child: Text(
                  code.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.footnote.copyWith(fontFamily: 'monospace', color: context.palette.ink),
                ),
              ),
            ),
            const SizedBox(width: Space.s),
            TextButton.icon(
              onPressed: () => _copy(code),
              icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 18),
              label: Text(_copied ? 'Copied' : 'Copy Link'),
            ),
          ],
        ),
      ),
      const SizedBox(height: Space.s),
      Wrap(
        spacing: Space.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (minutes != null)
            Text(
              minutes <= 1 ? 'Works once, for about a minute more.' : 'Works once, for $minutes more minutes.',
              style: context.type.footnote,
            ),
          TextButton(onPressed: link.working ? null : link.showCode, child: const Text('Make a new code')),
          TextButton(onPressed: link.hideCode, child: const Text('Done')),
        ],
      ),
    ];
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.peer, required this.now});

  final LinkPeer peer;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final platform = peer.linkPlatform;
    final cloud = peer.role == 'cloud' || platform == LinkPlatform.cloud;
    final icon = switch (platform) {
      LinkPlatform.iOS => Icons.phone_iphone_rounded,
      LinkPlatform.android => Icons.phone_android_rounded,
      LinkPlatform.macOS || LinkPlatform.windows => Icons.computer_rounded,
      LinkPlatform.cloud => Icons.cloud_outlined,
      null => cloud ? Icons.cloud_outlined : (peer.role == 'host' ? Icons.computer_rounded : Icons.smartphone_rounded),
    };
    final seen = peer.lastSeen;
    // Mochi Cloud never stays connected: it posts when a check runs.
    final presence = cloud
        ? (seen == null ? 'Hasn’t checked in yet' : 'Last check ${relativeTime(seen, now: now)}')
        : peer.online
        ? 'Online'
        : (seen == null ? 'Away' : 'Away · ${relativeTime(seen, now: now)}');
    final good = cloud ? seen != null : peer.online;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        child: Row(
          children: [
            IconTile(icon: icon, tint: p.tint),
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
                      Text(LinkPeerNames.row(peer), style: context.type.body.copyWith(fontWeight: FontWeight.w600)),
                      Tag(text: presence, icon: good ? Icons.circle : Icons.circle_outlined, tint: good ? p.success : p.inkSecondary),
                    ],
                  ),
                  Text([LinkPeerNames.label(peer), if (peer.app != null) 'Mochi ${peer.app}'].join(' · '), style: context.type.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
