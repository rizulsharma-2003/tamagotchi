// A stand-in for Mochi Cloud's routine trigger, on this computer, for trying "Check now" and "Draft a reply" from a
// debug build end to end without the real routine (never the user's). The phone reaches it through
// `adb reverse tcp:8789 tcp:8789`; tool/fake_mac.dart's `cloud` command shares its URL in the test room.
//
//   cd flutter/apps/mochi_pocket
//   dart run tool/fake_cloud.dart [--port 8789] [--control <fake_mac's control file>]
//
// It answers each request as Anthropic's API does (200, or 401 for a wrong token) and prints what was asked: the
// request's first word, and for a draft the thread and how long the note was, never the note itself or the token.
// With --control it then tells the fake Mac to send what Mochi Cloud would: its answer to "check now"
// (`cloudnews`), or "Reply drafted" (`draft`), a few seconds later.

// A command-line tool: printing is how it talks.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What fake_mac.dart's `cloud` command puts in the trigger.
const String _token = 'fake-cloud-token';

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i += 2) {
    options[arguments[i].replaceFirst('--', '')] = arguments[i + 1];
  }
  final port = int.tryParse(options['port'] ?? '') ?? 8789;
  final control = options['control'];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  print('Fake Mochi Cloud on http://127.0.0.1:$port (adb reverse tcp:$port tcp:$port).');
  await for (final request in server) {
    final body = await utf8.decoder.bind(request).join();
    final authorized = request.headers.value('authorization') == 'Bearer $_token';
    final beta = request.headers.value('anthropic-beta');
    final version = request.headers.value('anthropic-version');
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      json = null;
    }
    final text = json is Map && json['text'] is String ? json['text'] as String : '';
    final words = text.split(' ');
    final what = switch (words.first) {
      'draft' =>
        'draft for thread ${words.length > 1 ? words[1] : '?'} (${words.length > 2 ? words.sublist(2).join(' ').length : 0} characters of note)',
      _ => text,
    };
    print(
      '${request.method} ${request.uri.path}: $what · token ${authorized ? 'ok' : 'WRONG'} · beta ${beta ?? 'missing'} · '
      'version ${version ?? 'missing'}',
    );
    request.response
      ..statusCode = request.method == 'POST' && authorized ? 200 : 401
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(authorized ? {'type': 'routine_fire', 'session_id': 'fake-session'} : {'error': 'unauthorized'}));
    await request.response.close();
    if (!authorized || control == null) continue;
    final answer = words.first == 'draft' ? 'draft' : 'cloudnews';
    Timer(const Duration(seconds: 4), () {
      File(control).writeAsStringSync('$answer\n', mode: FileMode.append);
      print('  told the fake Mac: $answer');
    });
  }
}
