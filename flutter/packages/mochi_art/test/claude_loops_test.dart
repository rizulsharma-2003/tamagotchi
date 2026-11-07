// What Mochi and Patch do for what Claude is doing (lib/src/claude_loops.dart), as the Mac's EventToAnimationMapper
// picks it, and the celebration burst (lib/src/celebration.dart).

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';

void main() {
  test("Patch works the way Claude's tools say, typing otherwise", () {
    const loops = {
      'think': CompanionAnimation.thinking,
      'read': CompanionAnimation.reading,
      'search': CompanionAnimation.searching,
      'edit': CompanionAnimation.typing,
      'plan': CompanionAnimation.typing,
      'shell': CompanionAnimation.runningCommand,
      'web': CompanionAnimation.browsing,
      'agent': CompanionAnimation.delegating,
      'ask': CompanionAnimation.waiting,
      'other': CompanionAnimation.typing,
    };
    for (final MapEntry(key: category, value: loop) in loops.entries) {
      expect(ClaudeLoops.companionLoop('working', category: category), loop, reason: category);
    }
    expect(ClaudeLoops.companionLoop('working'), CompanionAnimation.typing);
    expect(ClaudeLoops.companionLoop('working', category: 'think', helpers: true), CompanionAnimation.delegating);
  });

  test('Patch waits with you, idles between turns, rests after a session and naps when it is quiet', () {
    expect(ClaudeLoops.companionLoop('waiting'), CompanionAnimation.waiting);
    for (final phase in ['none', 'idle', 'done', 'error']) {
      expect(ClaudeLoops.companionLoop(phase), CompanionAnimation.idleAtDesk, reason: phase);
      expect(ClaudeLoops.companionLoop(phase, sleepy: true), CompanionAnimation.sleep, reason: phase);
    }
    expect(ClaudeLoops.companionLoop('ended'), CompanionAnimation.rest);
    expect(ClaudeLoops.companionLoop('ended', sleepy: true), CompanionAnimation.sleep);
    expect(ClaudeLoops.companionLoop('working', category: 'edit', sleepy: true), CompanionAnimation.typing, reason: 'never asleep at work');
    expect(ClaudeLoops.companionLoop('working', category: 'edit', resting: true), CompanionAnimation.sleep);
  });

  test('Mochi watches Claude work, waves while Claude waits, sleeps while the computer rests', () {
    expect(ClaudeLoops.petLoop('working', category: 'edit'), PetAnimation.watch);
    expect(ClaudeLoops.petLoop('working', category: 'ask'), PetAnimation.waveGently);
    expect(ClaudeLoops.petLoop('waiting'), PetAnimation.waveGently);
    expect(ClaudeLoops.petLoop('done'), PetAnimation.idle);
    expect(ClaudeLoops.petLoop('waiting', resting: true), PetAnimation.sleep);
  });

  test('the celebration bursts for 2.6 s and then draws nothing', () async {
    Future<int> inked(double elapsed) async {
      final recorder = ui.PictureRecorder();
      Celebration.draw(
        GContext(Canvas(recorder)),
        elapsed,
        center: const Offset(60, 40),
        petHeight: 30,
        unit: 2,
        big: true,
      );
      final image = await recorder.endRecording().toImage(120, 44);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      var count = 0;
      for (var i = 3; i < bytes.length; i += 4) {
        if (bytes[i] > 0) count++;
      }
      return count;
    }

    expect(await inked(0.3), greaterThan(20));
    expect(await inked(Celebration.length + 0.1), 0);
    expect(await inked(-0.1), 0);
  });
}
