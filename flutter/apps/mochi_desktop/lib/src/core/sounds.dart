// Mochi's little sounds: the Mac's SoundPlayer (Sources/App/Services/SoundPlayer.swift) note for note, synthesized here
// (no audio files) as soft bell-like tones with gentle envelopes, and handed to the system's player as a WAV.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mochi_art/mochi_art.dart' show Ease;

import 'notifications.dart' show SoundCue;

/// Plays a WAV (Windows' PlaySound; nothing elsewhere, or a recorder in tests).
abstract interface class SoundOutput {
  /// False where Mochi can't play sounds (the macOS development build).
  bool get supported;

  /// False when Windows' sound scheme is "No Sounds": Mochi stays silent too (the Mac's "Play user interface sound
  /// effects").
  bool get systemSoundsOn;

  void play(Uint8List wav);
}

class SilentOutput implements SoundOutput {
  const SilentOutput();

  @override
  bool get supported => false;

  @override
  bool get systemSoundsOn => true;

  @override
  void play(Uint8List wav) {}
}

class _Note {
  const _Note(this.frequency, this.start, this.duration, [this.amplitude = 0.22]);

  final double frequency;
  final double start;
  final double duration;
  final double amplitude;
}

/// The cues' notes and their rendering.
abstract final class SoundSynth {
  static const int sampleRate = 22050;

  static List<_Note> _notes(SoundCue cue) => switch (cue) {
    SoundCue.greeting => const [_Note(784, 0, 0.18), _Note(1046.5, 0.11, 0.32)],
    SoundCue.success => const [_Note(1046.5, 0, 0.24), _Note(1318.5, 0.09, 0.24), _Note(1568, 0.18, 0.45)],
    SoundCue.celebration => const [
      _Note(1046.5, 0, 0.2),
      _Note(1318.5, 0.08, 0.2),
      _Note(1568, 0.16, 0.2),
      _Note(2093, 0.26, 0.55),
      _Note(2637, 0.36, 0.12, 0.1),
    ],
    SoundCue.sleep => const [_Note(880, 0, 0.32, 0.14), _Note(659.3, 0.2, 0.5, 0.12)],
    SoundCue.attention => const [_Note(880, 0, 0.18, 0.18), _Note(1174.7, 0.15, 0.32, 0.18)],
    SoundCue.investigate => const [_Note(587.3, 0, 0.22, 0.16), _Note(493.9, 0.15, 0.34, 0.14)],
    SoundCue.pop => const [_Note(1760, 0, 0.09, 0.14)],
    SoundCue.achievement => const [_Note(784, 0, 0.16), _Note(1046.5, 0.1, 0.16), _Note(1318.5, 0.2, 0.16), _Note(1568, 0.3, 0.6)],
    SoundCue.keyboard || SoundCue.purr => const [],
  };

  /// [cue] as 16-bit mono samples at [volume] (0–1; the Mac's player plays at 60% of the slider).
  static Int16List samples(SoundCue cue, {double volume = 0.45}) {
    final gain = volume.clamp(0.0, 1.0) * 0.6;
    if (cue == SoundCue.keyboard) {
      return _render(0.22, gain, (t) {
        var value = 0.0;
        for (final (index, start) in const [0.0, 0.07, 0.135].indexed) {
          final local = t - start;
          if (local < 0 || local >= 0.018) continue;
          final noise = Ease.hash((local * 44100).floor() + index * 997, 77) * 2 - 1;
          value += noise * 0.05 * math.exp(-local * 240);
        }
        return value;
      });
    }
    if (cue == SoundCue.purr) {
      // A low, rumbling "prrr": a soft tone and a breath of noise, fluttering about 26 times a second.
      const length = 0.34;
      return _render(length, gain, (t) {
        final swell = math.sin(math.pi * t / length);
        final flutter = 0.5 + 0.5 * math.sin(2 * math.pi * 26 * t);
        final tone = 0.6 * math.sin(2 * math.pi * 92 * t) + 0.22 * math.sin(2 * math.pi * 184 * t);
        final breath = (Ease.hash((t * 11025).floor(), 31) * 2 - 1) * 0.18;
        return (tone + breath) * flutter * swell * 0.5;
      });
    }
    final notes = _notes(cue);
    final length = notes.map((note) => note.start + note.duration).fold<double>(0.2, math.max) + 0.25;
    return _render(length, gain, (t) {
      var value = 0.0;
      for (final note in notes) {
        final local = t - note.start;
        if (local < 0) continue;
        // Fast attack, exponential decay: a soft bell.
        final attack = math.min(1.0, local / 0.006);
        final decay = math.exp(-local * (3.2 / note.duration));
        final phase = 2 * math.pi * note.frequency * local;
        final tone = math.sin(phase) + 0.28 * math.sin(2 * phase) + 0.08 * math.sin(3.01 * phase);
        value += tone * attack * decay * note.amplitude;
      }
      return value;
    });
  }

  static Int16List _render(double length, double gain, double Function(double t) sample) {
    final frames = (length * sampleRate).floor();
    final out = Int16List(frames);
    for (var index = 0; index < frames; index++) {
      final t = index / sampleRate;
      // A short fade-out at the very end, so there's no click.
      final tail = math.min(1.0, (length - t) / 0.02);
      out[index] = ((sample(t) * tail * gain).clamp(-1.0, 1.0) * 32767).round();
    }
    return out;
  }

  /// [cue] as a WAV file's bytes.
  static Uint8List wav(SoundCue cue, {double volume = 0.45}) {
    final pcm = samples(cue, volume: volume);
    final data = pcm.lengthInBytes;
    final bytes = ByteData(44 + data);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    bytes.setUint32(4, 36 + data, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // mono
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    text(36, 'data');
    bytes.setUint32(40, data, Endian.little);
    final out = bytes.buffer.asUint8List();
    out.setRange(44, 44 + data, pcm.buffer.asUint8List(pcm.offsetInBytes, data));
    return out;
  }
}

/// Plays Mochi's sounds at the volume Settings has, never the same one twice within a moment (the Mac's
/// `playSound`: 1.5 s apart, keyboard taps 4 s).
class MochiSounds {
  MochiSounds({required this.output, required double Function() volume, DateTime Function()? clock})
    : _volume = volume,
      _clock = clock ?? DateTime.now;

  final SoundOutput output;
  final double Function() _volume;
  final DateTime Function() _clock;
  final Map<SoundCue, DateTime> _lastPlayed = {};
  final Map<(SoundCue, int), Uint8List> _cache = {};

  /// How many sounds actually played (Settings › Developer, tests).
  int played = 0;

  /// Plays [cue]; false when it was too soon after the same one, or silent.
  bool play(SoundCue cue, {bool force = false}) {
    final volume = _volume();
    if (!output.supported || !output.systemSoundsOn || volume <= 0.01) return false;
    final now = _clock();
    final gap = cue == SoundCue.keyboard ? const Duration(seconds: 4) : const Duration(milliseconds: 1500);
    final last = _lastPlayed[cue];
    if (!force && last != null && now.difference(last) < gap) return false;
    _lastPlayed[cue] = now;
    // A handful of volume steps, so moving the slider doesn't render a new sound for every pixel.
    final step = (volume * 20).round();
    final wav = _cache[(cue, step)] ??= SoundSynth.wav(cue, volume: step / 20);
    played++;
    output.play(wav);
    return true;
  }
}
