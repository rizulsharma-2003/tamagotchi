// Port of `SplitMix64` (Sources/TamagotchiCore/Interactions/InteractionScheduler.swift): the small seedable PRNG behind
// every ambient choice, so the same seed gives the same choices as the Mac.

import 'ease.dart';

/// SplitMix64 over Dart's 64-bit integers. [state] holds the UInt64's bit pattern (it may print as negative); the
/// arithmetic wraps exactly like Swift's `&+` / `&*`.
class SplitMix64 {
  SplitMix64(int seed) : _state = seed;

  int _state;

  /// The raw state (a UInt64's bit pattern).
  int get state => _state;

  int next() {
    _state += 0x9E3779B97F4A7C15;
    var z = _state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// Uniform in [0, 1).
  double nextUnit() => (next() >>> 11) / twoTo53;

  double nextIn(double lower, double upper) => lower + (upper - lower) * nextUnit();

  SplitMix64 copy() => SplitMix64(_state);
}

/// `value % modulus` with `value` read as an unsigned 64-bit integer (Swift `UInt64 % n`), for a positive `modulus`.
int unsignedMod(int value, int modulus) {
  if (value >= 0) return value % modulus;
  // value = 2·(value >>> 1) + (value & 1), every part non-negative.
  final half = (value >>> 1) % modulus;
  return (2 * half + (value & 1)) % modulus;
}

/// A UInt64's bit pattern as the unsigned decimal Swift prints (for JSON and fixtures).
String unsignedString(int value) => value >= 0 ? '$value' : BigInt.from(value).toUnsigned(64).toString();

/// Parses an unsigned 64-bit decimal (or a JSON number) into its bit pattern.
int parseUnsigned(Object? value) {
  if (value is int) return value;
  if (value is String) return BigInt.parse(value).toSigned(64).toInt();
  if (value is double) return value.toInt();
  throw FormatException('not an unsigned 64-bit integer: $value');
}
