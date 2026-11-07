import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mochi_link/mochi_link.dart';

/// One HTTPS POST to Mochi Cloud's trigger: the status code, or an exception when it couldn't be reached.
typedef CloudPost = Future<int> Function(Uri url, Map<String, String> headers, String body);

/// The real POST (dart:io, no extra package). The token is only ever in the request's header.
Future<int> postToCloud(Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.postUrl(url);
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final response = await request.close().timeout(const Duration(seconds: 30));
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// Mochi Cloud from the phone (iOS/MochiPocket/MacLink.swift `fireCloud`, `checkInCloudNow`, `draftReply`): the
/// computer shares Mochi Cloud's "check now" trigger in the room (`cloud`: a URL and a token that can only start that
/// one routine), and the phone fires it straight at Anthropic's API, so "Check now" and "Draft reply" work while the
/// computer is off. The answer comes back the usual way: a notification and a new "Waiting for you" card from the
/// room's Mochi Cloud device.
abstract final class MochiCloud {
  /// What "Check now" asks for.
  static const String checkText = 'check now';

  /// Mochi Cloud was asked a moment ago and its answer hasn't come yet (the iPhone's 240 s).
  static const Duration checkingFor = Duration(seconds: 240);

  /// The trigger, when it's safe to send the token to: Anthropic's API over HTTPS only (as the iPhone checks). A
  /// development build's throwaway test room may also use a trigger on this phone (`http://127.0.0.1`, through
  /// `adb reverse`), for trying it end to end without the real routine; [allowLocal] is never set for a real room.
  static CloudTrigger? usable(CloudTrigger? trigger, {bool allowLocal = false}) {
    if (trigger == null || trigger.token.isEmpty) return null;
    final url = Uri.tryParse(trigger.url);
    if (url == null) return null;
    if (url.scheme == 'https' && url.host == 'api.anthropic.com') return trigger;
    if (allowLocal && url.scheme == 'http' && (url.host == '127.0.0.1' || url.host == 'localhost')) return trigger;
    return null;
  }

  /// Asks Mochi Cloud for [text] ("check now", or a draft request). Null when it took the request; otherwise why
  /// not, in words for the card (the iPhone's). [host] names the computer whose Settings hold the token.
  static Future<String?> fire(
    CloudTrigger trigger, {
    String text = checkText,
    required CloudPost post,
    required LinkHostName host,
    void Function(String line)? log,
  }) async {
    final url = Uri.parse(trigger.url);
    final headers = {
      'authorization': 'Bearer ${trigger.token}',
      'anthropic-beta': 'experimental-cc-routine-2026-04-01',
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    };
    try {
      final status = await post(url, headers, jsonEncode({'text': text}));
      // The request's first word only ("check", "draft"): never the token, nor what you asked the draft to say.
      log?.call('asked Mochi Cloud (${text.split(' ').first}): HTTP $status');
      if (status >= 200 && status < 300) return null;
      return switch (status) {
        401 || 403 => 'Mochi Cloud refused the request. Save a fresh API token on ${host.yours} (Settings › Agent › Mochi Cloud).',
        429 => 'Mochi Cloud is busy (too many requests this hour). Try again in a few minutes.',
        _ => "Couldn't reach Mochi Cloud (HTTP $status).",
      };
    } on Object catch (error) {
      log?.call('asking Mochi Cloud failed (${error.runtimeType})');
      return "Couldn't reach Mochi Cloud. Check the phone's connection and try again.";
    }
  }

  /// The words of a "Draft reply" request (the iPhone's): `draft <thread>` and, if you said what it should say, one
  /// line of up to 300 characters with no angle brackets, so it can't be mistaken for the request's wrapper. Null when
  /// [threadId] isn't a Gmail thread id.
  static String? draftRequest(String? threadId, String note) {
    if (threadId == null || threadId.isEmpty || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(threadId)) return null;
    final words = note.split(RegExp(r'[\r\n  ]+')).join(' ').replaceAll(RegExp('[<>]'), '').trim();
    final clipped = String.fromCharCodes(words.runes.take(300));
    return 'draft $threadId${clipped.isEmpty ? '' : ' $clipped'}';
  }
}

/// "Waiting for you" cards from more than one place (the computer, Mochi Cloud, notifications), folded together as
/// TamagotchiCore's `AgentPending.merging` does.
abstract final class AgentCards {
  /// Notes go 30 hours after they came in; meetings ten minutes after they start (`AgentMemory.pendingHours`).
  static const double pendingHours = 30;

  /// At most this many on a card (`AgentPending.maxItems`).
  static const int maxItems = 8;

  /// Whether [card] is from Mochi Cloud: "cloud" (an hourly run) or "cloud-manual" (Check now).
  static bool fromCloud(AgentPending card) => card.origin?.startsWith('cloud') ?? false;

  /// [newer] folded into [older]: the computer's card and a "Check now" card replace it; an hourly Mochi Cloud card
  /// only adds what it found that hour (it never looked at the rest).
  static AgentPending merge(AgentPending older, AgentPending newer, {required double now}) {
    if (newer.origin != 'cloud') return newer;
    var items = older.items;
    if (newer.items.isNotEmpty) {
      final ids = {for (final note in newer.items) note.id};
      items = [...newer.items, ...older.items.where((note) => !ids.contains(note.id))];
    }
    return AgentPending(
      enabled: older.enabled || newer.enabled,
      headline: newer.items.isEmpty ? older.headline : (newer.headline ?? older.headline),
      items: prune(items, now: now),
      lookedAt: math.max(older.lookedAt ?? 0, newer.lookedAt ?? 0),
      updatedAt: newer.updatedAt,
      origin: newer.origin,
    );
  }

  /// What's still current, in the card's order, at most [maxItems] (`AgentMemory.prunePending`).
  static List<AgentNote> prune(List<AgentNote> notes, {required double now}) => ordered([
    for (final note in notes)
      if (note.due != null ? note.due! > now - 600 : note.at > now - pendingHours * 3600) note,
  ]).take(maxItems).toList();

  /// Coming meetings first (soonest first), then what needs you, then tasks, then the rest, newest first
  /// (`AgentMemory.ordered`).
  static List<AgentNote> ordered(List<AgentNote> notes) {
    int group(AgentNote note) {
      if (note.source == AgentSource.calendar) return 0;
      if (note.important) return 1;
      return note.source == AgentSource.notion ? 2 : 3;
    }

    final sorted = [...notes];
    // A stable sort: equal notes keep their order.
    _stableSort(
      sorted,
      compare: (a, b) {
        final (ga, gb) = (group(a), group(b));
        if (ga != gb) return ga.compareTo(gb);
        if (ga == 0) return (a.due ?? double.infinity).compareTo(b.due ?? double.infinity);
        return b.at.compareTo(a.at);
      },
    );
    return sorted;
  }
}

/// A merge sort that keeps equal elements in order (List.sort isn't stable; Swift's sort is).
void _stableSort<T>(List<T> list, {required int Function(T a, T b) compare}) {
  if (list.length < 2) return;
  final middle = list.length ~/ 2;
  final left = list.sublist(0, middle), right = list.sublist(middle);
  _stableSort(left, compare: compare);
  _stableSort(right, compare: compare);
  var i = 0, j = 0, k = 0;
  while (i < left.length && j < right.length) {
    list[k++] = compare(left[i], right[j]) <= 0 ? left[i++] : right[j++];
  }
  while (i < left.length) {
    list[k++] = left[i++];
  }
  while (j < right.length) {
    list[k++] = right[j++];
  }
}
