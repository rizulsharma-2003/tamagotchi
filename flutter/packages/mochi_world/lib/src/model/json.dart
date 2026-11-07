// Small helpers for reading the JSON the Swift side writes (missing keys take the defaults).

Map<String, Object?> asMap(Object? value) => value is Map ? value.cast<String, Object?>() : const {};

double dbl(Map<String, Object?> j, String key, double fallback) {
  final value = j[key];
  return value is num ? value.toDouble() : fallback;
}

int integer(Map<String, Object?> j, String key, int fallback) {
  final value = j[key];
  return value is num ? value.toInt() : fallback;
}

bool boolean(Map<String, Object?> j, String key, bool fallback) {
  final value = j[key];
  return value is bool ? value : fallback;
}

String? string(Map<String, Object?> j, String key) {
  final value = j[key];
  return value is String ? value : null;
}

List<Map<String, Object?>> list(Map<String, Object?> j, String key) {
  final value = j[key];
  if (value is! List) return const [];
  return value.whereType<Map<Object?, Object?>>().map(asMap).toList();
}

/// The enum case whose name equals `value` (the Swift raw value), or null.
T? enumByName<T extends Enum>(List<T> values, Object? value) {
  if (value is! String) return null;
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  return null;
}
