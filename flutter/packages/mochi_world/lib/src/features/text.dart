// Swift's view of text where the speech rules depend on it: `String.count` counts characters (grapheme clusters, so
// "☀️" or "👋🏽" is one), `trimmingCharacters(in:)` trims Unicode scalars from a set, and `Character.isNewline`.
// Dart counts UTF-16 code units, so these helpers reproduce Swift's answers for the text Mochi says (emoji with
// variation selectors, skin tones, ZWJ sequences, flags, keycaps and combining marks).

/// Swift's characters in [text]: each element is one grapheme cluster.
List<String> characters(String text) {
  final out = <String>[];
  final buffer = StringBuffer();
  var joinNext = false;
  var regionalOpen = false;
  int? previous;
  for (final rune in text.runes) {
    final extend = _extends(rune) || joinNext || (rune == 0x0A && previous == 0x0D);
    final regionalPair = _isRegional(rune) && regionalOpen;
    if (buffer.isNotEmpty && !extend && !regionalPair) {
      out.add(buffer.toString());
      buffer.clear();
      regionalOpen = false;
    }
    buffer.writeCharCode(rune);
    joinNext = rune == 0x200D;
    if (_isRegional(rune)) {
      regionalOpen = !regionalPair;
    } else if (!_extends(rune)) {
      regionalOpen = false;
    }
    previous = rune;
  }
  if (buffer.isNotEmpty) out.add(buffer.toString());
  return out;
}

/// Swift `String.count`.
int characterCount(String text) => characters(text).length;

bool _isRegional(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

bool _extends(int rune) =>
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    (rune >= 0xFE20 && rune <= 0xFE2F) ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
    (rune >= 0xE0020 && rune <= 0xE007F) ||
    (rune >= 0xE0100 && rune <= 0xE01EF) ||
    rune == 0x200D;

/// `CharacterSet.whitespacesAndNewlines`.
bool isWhitespaceOrNewline(int rune) =>
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0x20 ||
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000;

/// `Character.isNewline` for a one-character string.
bool isNewlineCharacter(String character) {
  if (character == '\r\n') return true;
  final runes = character.runes.toList();
  if (runes.length != 1) return false;
  final r = runes.first;
  return (r >= 0x0A && r <= 0x0D) || r == 0x85 || r == 0x2028 || r == 0x2029;
}

/// `CharacterSet.punctuationCharacters` (Unicode's P categories) for the scripts Mochi's lines use.
bool isPunctuation(int rune) {
  if (rune < 0x80) return '!"#%&\'()*,-./:;?@[\\]_{}'.codeUnits.contains(rune);
  return rune == 0xA1 ||
      rune == 0xA7 ||
      rune == 0xAB ||
      rune == 0xB6 ||
      rune == 0xB7 ||
      rune == 0xBB ||
      rune == 0xBF ||
      (rune >= 0x2010 && rune <= 0x2027) ||
      (rune >= 0x2030 && rune <= 0x2043) ||
      (rune >= 0x2045 && rune <= 0x2051) ||
      (rune >= 0x2053 && rune <= 0x205E) ||
      (rune >= 0x3001 && rune <= 0x3003) ||
      (rune >= 0x3008 && rune <= 0x3011) ||
      (rune >= 0x3014 && rune <= 0x301F);
}

/// Swift `trimmingCharacters(in:)`: drops scalars matching [trim] from both ends.
String trimScalars(String text, bool Function(int rune) trim) {
  final runes = text.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && trim(runes[start])) {
    start++;
  }
  while (end > start && trim(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes, start, end);
}
