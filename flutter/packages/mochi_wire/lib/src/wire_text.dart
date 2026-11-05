import 'dart:convert';

import 'package:cryptography/dart.dart';

/// Text hygiene for every string that crosses the wire (Swift `WireText`).
abstract final class WireText {
  /// Collapses whitespace, removes control characters and truncates to [maxLength] characters (with "…").
  static String? clean(String? value, {required int maxLength}) {
    if (value == null) return null;
    final out = StringBuffer();
    var lastWasSpace = false;
    var any = false;
    for (final rune in value.runes) {
      if (_isWhitespace(rune)) {
        if (!lastWasSpace && any) out.write(' ');
        lastWasSpace = true;
        continue;
      }
      if (_isControl(rune)) continue;
      out.writeCharCode(rune);
      any = true;
      lastWasSpace = false;
    }
    var text = out.toString().trim();
    if (text.isEmpty) return null;
    return _truncate(text, maxLength);
  }

  /// Free text whose line breaks matter (Claude's closing message): each line is cleaned, at most one blank line in a
  /// row is kept, and the end is truncated.
  static String? paragraphs(String? value, {required int maxLength}) {
    if (value == null) return null;
    final lines = <String>[];
    for (final raw in value.replaceAll('\r\n', '\n').split('\n')) {
      final line = clean(raw, maxLength: 1 << 30);
      if (line != null) {
        lines.add(line);
      } else if (lines.isNotEmpty && lines.last.isNotEmpty) {
        lines.add('');
      }
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    final text = lines.join('\n');
    if (text.isEmpty) return null;
    return _truncate(text, maxLength);
  }

  /// Identifier-like strings (session ids, tool names, event names): only `A-Z a-z 0-9 - _ . :`.
  static String? identifier(String? value, {required int maxLength}) {
    if (value == null || value.isEmpty || value.length > maxLength) return null;
    for (final unit in value.codeUnits) {
      final ok =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x5A) ||
          (unit >= 0x61 && unit <= 0x7A) ||
          unit == 0x2D ||
          unit == 0x5F ||
          unit == 0x2E ||
          unit == 0x3A;
      if (!ok) return null;
    }
    return value;
  }

  static String _truncate(String text, int maxLength) {
    final runes = text.runes.toList();
    if (runes.length <= maxLength) return text;
    final kept = String.fromCharCodes(runes.take(maxLength > 0 ? maxLength - 1 : 0));
    return '$kept…';
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 ||
      (rune >= 0x09 && rune <= 0x0D) ||
      rune == 0x85 ||
      rune == 0xA0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;

  /// Control characters (C0, DEL, C1) and the unassigned/illegal noncharacters Swift drops.
  static bool _isControl(int rune) =>
      rune < 0x20 || (rune >= 0x7F && rune <= 0x9F) || rune == 0xFFFE || rune == 0xFFFF || (rune >= 0xFDD0 && rune <= 0xFDEF);
}

/// Paths as Claude Code reports them: POSIX (`/Users/me/project`) or Windows (`C:\Users\me\project`,
/// `\\server\share\project`).
abstract final class WirePath {
  static final RegExp _drive = RegExp(r'^[A-Za-z]:[\\/]');

  static bool isWindows(String path) => _drive.hasMatch(path) || path.startsWith(r'\\');

  static bool isAbsolute(String path) => path.startsWith('/') || isWindows(path);

  /// `.` and `..` resolved, repeated and trailing separators removed (as Swift's `standardizedFileURL.path`). Windows
  /// paths use `\` with an upper-case drive letter.
  static String standardize(String path) {
    if (isWindows(path)) {
      final unc = path.startsWith(r'\\');
      final parts = path.replaceAll('/', r'\').split(r'\');
      final String root;
      final List<String> rest;
      if (unc) {
        // \\server\share\…
        final named = parts.where((part) => part.isNotEmpty).toList();
        root = named.length >= 2 ? '\\\\${named[0]}\\${named[1]}' : '\\\\${named.join(r'\')}';
        rest = named.length >= 2 ? named.sublist(2) : const [];
      } else {
        root = '${parts.first.toUpperCase()}\\';
        rest = parts.sublist(1);
      }
      final kept = _resolve(rest);
      if (kept.isEmpty) return root;
      return unc ? '$root\\${kept.join(r'\')}' : '$root${kept.join(r'\')}';
    }
    final kept = _resolve(path.split('/'));
    return '/${kept.join('/')}';
  }

  /// The last component ("mac-Tamagotchi"), or the path itself for a root.
  static String lastComponent(String path) {
    final standardized = standardize(path);
    final separator = isWindows(standardized) ? r'\' : '/';
    final index = standardized.lastIndexOf(separator);
    final last = index < 0 ? standardized : standardized.substring(index + 1);
    return last.isEmpty ? standardized : last;
  }

  static List<String> _resolve(List<String> parts) {
    final kept = <String>[];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (kept.isNotEmpty) kept.removeLast();
        continue;
      }
      kept.add(part);
    }
    return kept;
  }
}

/// Telling projects apart without sending their paths (Swift `ProjectIdentity`).
abstract final class ProjectIdentity {
  /// A short, stable, one-way identifier for a project path: the first 6 bytes of SHA-256 of the standardized path,
  /// in hex (the same as Swift for the same POSIX path).
  static String key(String path) => hexDigest(utf8.encode(WirePath.standardize(path)), bytes: 6);

  static String displayName(String path) => WireText.clean(WirePath.lastComponent(path), maxLength: 48) ?? 'Project';
}

/// The first [bytes] bytes of SHA-256, in lower-case hex.
String hexDigest(List<int> data, {int bytes = 16}) {
  final hash = const DartSha256().hashSync(data).bytes;
  return hash.take(bytes).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
