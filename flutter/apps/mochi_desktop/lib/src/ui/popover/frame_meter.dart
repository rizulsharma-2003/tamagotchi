// Development: how smoothly the popover's transitions run on this PC. With the stroll's debug log on, each
// transition writes one line: its frames' pacing (the time between the frames the ticker saw), and the engine's own
// build and raster times for those frames (FrameTiming, the numbers DevTools shows; the engine sends them about once
// a second in a release build, so the line comes a little after the transition).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';

class FrameMeter {
  FrameMeter(this.log);

  final void Function(String message) log;

  final Stopwatch _watch = Stopwatch()..start();
  final List<FrameTiming> _timings = [];
  final List<int> _ticks = [];
  String _label = '';
  int? _firstVsync, _lastVsync;
  bool _listening = false;
  final Map<String, int> _marks = {};

  /// Something worth timing before the transition starts (a picture taken, say): [mark] then [since].
  void mark(String name) => _marks[name] = _watch.elapsedMicroseconds;
  double since(String name) => (_watch.elapsedMicroseconds - (_marks[name] ?? 0)) / 1000;

  void start(String label) {
    _label = label;
    _ticks.clear();
    _firstVsync = _lastVsync = null;
    if (!_listening) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _listening = true;
    }
  }

  /// One frame of the transition (from its ticker).
  void tick() {
    _ticks.add(_watch.elapsedMicroseconds);
    final stamp = SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    _firstVsync ??= stamp;
    _lastVsync = stamp;
  }

  void stop([String extra = '']) {
    final ticks = List.of(_ticks);
    final from = _firstVsync, to = _lastVsync, label = _label;
    _ticks.clear();
    if (from == null || to == null || ticks.length < 2) return;
    // The engine reports frames in batches: wait for the batch with the last of these.
    Timer(const Duration(milliseconds: 1500), () {
      final frames = [
        for (final timing in _timings)
          if (timing.timestampInMicroseconds(FramePhase.vsyncStart) >= from - 40000 &&
              timing.timestampInMicroseconds(FramePhase.vsyncStart) <= to + 1000)
            timing,
      ];
      _timings.removeWhere((timing) => timing.timestampInMicroseconds(FramePhase.vsyncStart) <= to + 1000);
      final gaps = [for (var i = 1; i < ticks.length; i++) (ticks[i] - ticks[i - 1]) / 1000];
      final build = [for (final f in frames) f.buildDuration.inMicroseconds / 1000];
      final raster = [for (final f in frames) f.rasterDuration.inMicroseconds / 1000];
      final late = [for (final f in frames) f.vsyncOverhead.inMicroseconds / 1000];
      final span = (ticks.last - ticks.first) / 1000;
      log(
        'frames $label: ${ticks.length} ticks in ${span.round()} ms (${(1000 * (ticks.length - 1) / span).toStringAsFixed(1)} fps); '
        'gap ${_stats(gaps)}, over 25 ms: ${gaps.where((g) => g > 25).length}; '
        'engine frames ${frames.length}: started after vsync ${_stats(late)}; build ${_stats(build)}; raster ${_stats(raster)}'
        '${extra.isEmpty ? '' : '; $extra'}',
      );
    });
  }

  void _onTimings(List<FrameTiming> timings) {
    _timings.addAll(timings);
    if (_timings.length > 600) _timings.removeRange(0, _timings.length - 600);
  }

  static String _stats(List<double> values) {
    if (values.isEmpty) return '-';
    final sorted = List.of(values)..sort();
    final avg = values.reduce((a, b) => a + b) / values.length;
    final p90 = sorted[math.min(sorted.length - 1, (sorted.length * 0.9).floor())];
    return 'avg ${avg.toStringAsFixed(1)} p90 ${p90.toStringAsFixed(1)} max ${sorted.last.toStringAsFixed(1)}';
  }

  void dispose() {
    if (_listening) SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _listening = false;
  }
}
