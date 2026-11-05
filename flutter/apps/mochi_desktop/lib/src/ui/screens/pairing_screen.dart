import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../link/link_host.dart';
import '../widgets/qr_code.dart';

/// Pair a phone (Settings › Devices on the Mac): this PC's room on Mochi Link, a QR code and a copyable link for the
/// phone, the devices in the room with who's online, and Unpair (deletes the room).
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
        title: const Text('Unpair every device?'),
        content: const Text(
          "This deletes this PC's Mochi Link room. Every phone paired with it stops getting news from this PC "
          'and has to scan a new code to pair again.',
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
                        : 'In Mochi on your phone: Pair with your computer, then scan. Or copy the link to another computer.',
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
                      label: const Text('Send a test notification'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _unpair,
                    style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Unpair all devices…'),
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
      label: Text(link.paired ? 'Pair another phone' : 'Show a pairing code'),
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
              label: Text(_copied ? 'Copied' : 'Copy link'),
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
          TextButton(onPressed: link.hideCode, child: const Text('Hide')),
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
    final icon = switch ((peer.role, peer.platform?.toLowerCase())) {
      ('cloud', _) => Icons.cloud_outlined,
      ('host', _) => Icons.computer_rounded,
      (_, 'android') => Icons.phone_android_rounded,
      _ => Icons.phone_iphone_rounded,
    };
    final kind = switch (peer.role) {
      'cloud' => 'Mochi Cloud',
      'host' => 'Computer',
      _ => 'Phone',
    };
    final seen = peer.lastSeen;
    final presence = peer.online ? 'Online' : (seen == null ? 'Away' : 'Away · ${relativeTime(seen, now: now)}');
    final name = peer.name ?? kind;
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
                      Text(name, style: context.type.body.copyWith(fontWeight: FontWeight.w600)),
                      Tag(
                        text: presence,
                        icon: peer.online ? Icons.circle : Icons.circle_outlined,
                        tint: peer.online ? p.success : p.inkSecondary,
                      ),
                    ],
                  ),
                  Text([kind, if (peer.app != null) 'Mochi ${peer.app}'].join(' · '), style: context.type.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
