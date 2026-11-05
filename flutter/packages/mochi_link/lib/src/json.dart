// Small helpers for the JSON the Swift apps write (JSONSerialization / JSONEncoder).

import 'dart:convert';

/// [json] as a string-keyed map, or null when it isn't an object.
Map<String, Object?>? asJsonMap(Object? json) => json is Map ? json.map((key, value) => MapEntry('$key', value)) : null;

Object? tryJsonDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

String? jsonString(Object? value) => value is String ? value : null;

bool? jsonBool(Object? value) => value is bool ? value : null;

double? jsonDouble(Object? value) => value is num ? value.toDouble() : null;

/// A whole number (Swift `Int` also decodes `3.0`).
int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble() && value.isFinite) return value.toInt();
  return null;
}

/// How Swift writes a `Double`: `1762243200`, not `1762243200.0`.
num? jsonNumber(num? value) {
  if (value is double && value.isFinite && value == value.truncateToDouble() && value.abs() < 9007199254740992) {
    return value.toInt();
  }
  return value;
}

/// A list of strings (other entries dropped), or null when it isn't a list.
List<String>? jsonStrings(Object? value) => value is List ? value.whereType<String>().toList() : null;

/// A Swift Codable value that may arrive as its JSON string (how the apps store `look`, `sessions`, …) or already
/// decoded as an object.
Map<String, Object?>? jsonObjectValue(Object? value) => asJsonMap(value is String ? tryJsonDecode(value) : value);
