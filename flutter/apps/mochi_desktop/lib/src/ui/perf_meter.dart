// Development: what Mochi costs, state by state (docs/SPRINT_2.md W30). With a `perf-debug` file in Mochi's folder,
// the app samples its own processor time twice a second and charges it to what Mochi was doing (calm on the taskbar,
// roaming, napping, hidden, the popover…), and counts the engine's frames the same way (FrameTiming: how many a
// second, and their build and raster times). Every [report] it writes one line per state to `perf.log` there, so a
// build can be compared with another on the same PC.

import 'dart:async';
import 'dart:math' as math;

import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

class PerfStats {
  double seconds = 0;
  int cpuMicros = 0;
  int frames = 0;
  int buildMicros = 0;
  int rasterMicros = 0;
  final List<int> raster = [];

  double get cpuShare => seconds <= 0 ? 0 : cpuMicros / 1e6 / seconds;
  double get fps => seconds <= 0 ? 0 : frames / seconds;
  double get buildMs => frames == 0 ? 0 : buildMicros / frames / 1000;
  double get rasterMs => frames == 0 ? 0 : rasterMicros / frames / 1000;

  double get rasterP90Ms {
    if (raster.isEmpty) return 0;
    final sorted = List.of(raster)..sort();
    return sorted[math.min(sorted.length - 1, (sorted.length * 0.9).floor())] / 1000;
  }
}

class PerfMeter {
  PerfMeter({
    required this.state,
    required this.log,
    required this.cpu,
    this.sample = const Duration(milliseconds: 500),
    this.report = const Duration(seconds: 30),
    bool listenToFrames = true,
  }) {
    _watch.start();
    _lastCpu = cpu();
    _lastState = state();
    _sampler = Timer.periodic(sample, (_) => _sample());
    _reporter = Timer.periodic(report, (_) => flush());
    if (listenToFrames) {
      SchedulerBinding.instance.addTimingsCallback(_timings);
      // Each frame's state, by its vsync time (the same stamp its FrameTiming carries).
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        if (!_listening) return;
        _frameStates.add((SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds, state()));
        if (_frameStates.length > 400) _frameStates.removeRange(0, 200);
      });
      _listening = true;
    }
  }

  final List<(int, String)> _frameStates = [];

  /// The state a frame that began at [vsync] was drawn in.
  String _stateAt(int vsync) {
    for (var i = _frameStates.length - 1; i >= 0; i--) {
      if (_frameStates[i].$1 <= vsync) return _frameStates[i].$2;
    }
    return _frameStates.isEmpty ? state() : _frameStates.first.$2;
  }

  /// What Mochi is doing now ("calm", "roaming", "napping", "hidden", "popover"…).
  final String Function() state;
  final void Function(String line) log;

  /// This process's processor time so far (microseconds), or null where it can't be read.
  final int? Function() cpu;
  final Duration sample;
  final Duration report;

  final Stopwatch _watch = Stopwatch();
  final Map<String, PerfStats> stats = {};
  late Timer _sampler;
  late Timer _reporter;
  bool _listening = false;
  int? _lastCpu;
  late String _lastState;
  double _lastAt = 0;

  double get _now => _watch.elapsedMicroseconds / 1e6;

  PerfStats _of(String name) => stats.putIfAbsent(name, PerfStats.new);

  void _sample() {
    final now = _now;
    final used = cpu();
    final before = _lastCpu;
    final stat = _of(_lastState);
    stat.seconds += now - _lastAt;
    if (used != null && before != null) stat.cpuMicros += used - before;
    _lastCpu = used;
    _lastAt = now;
    _lastState = state();
  }

  void _timings(List<FrameTiming> timings) {
    // The engine sends frames in batches (about once a second in a release build).
    for (final timing in timings) {
      final stat = _of(_stateAt(timing.timestampInMicroseconds(FramePhase.vsyncStart)));
      stat.frames++;
      stat.buildMicros += timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      stat.rasterMicros += raster;
      stat.raster.add(raster);
      if (stat.raster.length > 2000) stat.raster.removeRange(0, 1000);
    }
  }

  /// One line per state seen so far (totals since launch).
  void flush() {
    final names = stats.keys.toList()..sort();
    for (final name in names) {
      final s = stats[name]!;
      if (s.seconds < 1) continue;
      log(
        'perf: $name ${s.seconds.toStringAsFixed(0)} s · cpu ${(s.cpuShare * 100).toStringAsFixed(2)}% of a core · '
        '${s.fps.toStringAsFixed(1)} fps · build ${s.buildMs.toStringAsFixed(2)} ms · raster ${s.rasterMs.toStringAsFixed(2)} ms '
        '(p90 ${s.rasterP90Ms.toStringAsFixed(2)})',
      );
    }
  }

  void dispose() {
    _sampler.cancel();
    _reporter.cancel();
    if (_listening) SchedulerBinding.instance.removeTimingsCallback(_timings);
    _listening = false;
  }
}
