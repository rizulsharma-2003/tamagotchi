import 'dart:typed_data';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

/// The pairing QR code, matching Swift `PairingCode` (LinkTests.pairingCode) and the URLs Swift's `URLComponents`
/// actually writes.
void main() {
  final key = LinkCrypto.base64url(Uint8List(32)..fillRange(0, 32, 9));
  PairingCode code(String name, {String relay = 'link.example.com'}) =>
      PairingCode(relay: relay, room: 'room_5TQ9', invite: 'inv_X1', key: key, name: name);

  test('a pairing code survives the QR round trip, and incomplete codes are refused', () {
    final original = code("Rizul's MacBook & Mochi");
    expect(original.url, startsWith('mochi://pair?v=1&'));
    expect(PairingCode.parse(original.url), original);
    expect(PairingCode.parse('  ${original.url}\n'), original);
    expect(PairingCode.parse(original.url.replaceFirst('v=1', 'v=2')), isNull);
    expect(PairingCode.parse('mochi://pair?v=1&relay=r&room=x&invite=y&key=short'), isNull);
    expect(PairingCode.parse('https://example.com/pair?v=1'), isNull);
  });

  test('more refusals: a missing field, an empty one, another host, a 16-byte key, not a URL', () {
    final url = code('Mac').url;
    expect(PairingCode.parse(url.replaceFirst('&invite=inv_X1', '')), isNull);
    expect(PairingCode.parse(url.replaceFirst('room=room_5TQ9', 'room=')), isNull);
    expect(PairingCode.parse(url.replaceFirst('mochi://pair', 'mochi://join')), isNull);
    expect(PairingCode.parse(url.replaceFirst('v=1&', '')), isNull);
    expect(PairingCode.parse(url.replaceFirst(key, LinkCrypto.base64url(Uint8List(16)))), isNull);
    expect(PairingCode.parse(''), isNull);
    expect(PairingCode.parse('not a code'), isNull);
  });

  test('a code without a name is from "Mochi"', () {
    final url = code('Mac').url.replaceFirst('&name=Mac', '');
    expect(PairingCode.parse(url)?.name, 'Mochi');
  });

  test('the URL is written exactly as Swift writes it', () {
    // Printed by Swift's URLComponents with the same query items as PairingCode.url (macOS 27, Swift 6.4).
    const prefix =
        'mochi://pair?v=1&relay=link.example.com&room=room_5TQ9&invite=inv_X1&key=CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk&name=';
    final swift = {
      "Rizul's MacBook & Mochi": "Rizul's%20MacBook%20%26%20Mochi",
      'C++ Mac': 'C++%20Mac',
      r'a=b?c/d#e;f,g:h@i$j!k*l(m)n~o_p.q-r': r'a%3Db?c/d%23e;f,g:h@i$j!k*l(m)n~o_p.q-r',
      'मोची 🐾': '%E0%A4%AE%E0%A5%8B%E0%A4%9A%E0%A5%80%20%F0%9F%90%BE',
      r'100% "x" [y] {z} <w> |v| \u ^t `s': '100%25%20%22x%22%20%5By%5D%20%7Bz%7D%20%3Cw%3E%20%7Cv%7C%20%5Cu%20%5Et%20%60s',
    };
    swift.forEach((name, encoded) {
      expect(code(name).url, '$prefix$encoded');
      expect(PairingCode.parse('$prefix$encoded')?.name, name, reason: 'Swift-written code for $name');
    });
    expect(
      code('Mac', relay: 'localhost:8787').url,
      'mochi://pair?v=1&relay=localhost:8787&room=room_5TQ9&invite=inv_X1&key=CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk&name=Mac',
    );
  });

  test('a + in a name stays a +, as URLComponents reads it', () {
    final parsed = PairingCode.parse('mochi://pair?v=1&relay=r&room=x&invite=y&key=$key&name=C++%20Mac');
    expect(parsed?.name, 'C++ Mac');
  });

  test('printing a code leaves out the invite and the key', () {
    final text = code('Mac').toString();
    expect(text, isNot(contains(key)));
    expect(text, isNot(contains('inv_X1')));
  });
}
