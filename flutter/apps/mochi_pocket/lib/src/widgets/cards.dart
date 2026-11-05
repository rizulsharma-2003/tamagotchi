import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import '../theme.dart';
import 'clay.dart';

/// A message your Mac wants to send to one of your Claude sessions, waiting for your OK (iOS `ApprovalCard`).
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({super.key, required this.approval, required this.answer});

  final ApprovalRequest approval;
  final void Function(bool allow) answer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClayCard(
      outline: p.tint.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: Icons.send_rounded, tint: p.tint),
              const SizedBox(width: Space.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: Text('Send to Claude?', style: context.type.headline)),
                    Text(approval.project ?? approval.target, style: context.type.footnote),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.m),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Space.m),
            decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.inner)),
            child: Text(approval.message, style: context.type.body),
          ),
          const SizedBox(height: Space.m),
          // Side by side, or stacked when the text is too large for one row.
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: Space.s,
            overflowSpacing: Space.s,
            children: [
              OutlinedButton(onPressed: () => answer(false), child: const Text("Don't Send")),
              FilledButton.icon(onPressed: () => answer(true), icon: const Icon(Icons.send_rounded, size: 18), label: const Text('Send')),
            ],
          ),
        ],
      ),
    );
  }
}

/// What you asked your Mac lately and what it said (iOS ContentView `recent`).
class RecentCard extends StatelessWidget {
  const RecentCard({super.key, required this.exchanges, required this.macOnline});

  /// Oldest first.
  final List<Exchange> exchanges;
  final bool macOnline;

  /// How long the relay keeps a command for a Mac that's away.
  static const Duration commandLifetime = Duration(minutes: 10);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final latest = exchanges.reversed.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(title: 'Recently'),
        const SizedBox(height: Space.m),
        ClayCard(
          child: Column(
            children: [
              for (final (index, exchange) in latest.indexed) ...[
                if (index > 0) const SizedBox(height: Space.m),
                MergeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconTile(icon: _icon(exchange), tint: _tint(exchange, p)),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (exchange.project != null)
                              Text('To Claude in ${exchange.project}', style: context.type.caption.copyWith(fontWeight: FontWeight.w600)),
                            Text(
                              exchange.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(exchange.reply ?? _status(exchange), style: context.type.footnote),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Still waiting after the relay would have dropped it: the Mac never got it.
  static bool expired(Exchange exchange, {DateTime? now}) =>
      (exchange.state == ExchangeState.sending || exchange.state == ExchangeState.working) &&
      (now ?? DateTime.now()).difference(exchange.sentAt) > commandLifetime;

  static IconData _icon(Exchange exchange) => expired(exchange)
      ? Icons.schedule_rounded
      : switch (exchange.state) {
          ExchangeState.sending => Icons.send_rounded,
          ExchangeState.working => Icons.settings_suggest_rounded,
          ExchangeState.done => Icons.check_rounded,
          ExchangeState.failed => Icons.priority_high_rounded,
        };

  static Color _tint(Exchange exchange, MochiPalette p) => expired(exchange)
      ? p.warning
      : switch (exchange.state) {
          ExchangeState.done => p.success,
          ExchangeState.failed => p.warning,
          _ => p.tint,
        };

  String _status(Exchange exchange) {
    if (expired(exchange)) return "Your Mac didn't get this in time (it was away for 10 minutes). Send it again when it's back.";
    return switch (exchange.state) {
      ExchangeState.sending => macOnline ? 'Sending to your Mac…' : 'Waiting for your Mac. It gets this when it wakes (within 10 minutes).',
      ExchangeState.working => 'Your Mac is on it…',
      ExchangeState.done => 'Done',
      ExchangeState.failed => "Didn't work",
    };
  }
}

/// Mochi's speech bubble above the room (iOS `SpeechBubble`).
class SpeechBubble extends StatelessWidget {
  const SpeechBubble({super.key, required this.text, this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m),
      decoration: BoxDecoration(
        color: highlighted ? p.bubbleHighlight : p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: highlighted ? p.tint : p.stroke, width: highlighted ? 2 : 1),
        boxShadow: [
          BoxShadow(
            color: p.shadow.withValues(alpha: p.isDark ? 0.4 : 0.10),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: context.type.body.copyWith(fontWeight: FontWeight.w500),
      ),
    );
  }
}
