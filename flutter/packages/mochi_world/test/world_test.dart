// Whole-world timelines against the Swift engine (link-spec/world/world.json): MochiWorld replays CompanionWorld's
// scripted timelines (ticks, Claude's events, petting, play and treats, settings) with the same seed and clock, and
// must reach the same state, the same effects and the same scene frame at every snapshot.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

class _Recorder extends WorldEffects {
  final sounds = <String>[];
  final banners = <String>[];
  final reacted = <String>[];
  final interacted = <String>[];

  @override
  void play(SoundCue sound) => sounds.add(sound.name);

  @override
  void postBanner(BannerContent content, NotificationCategory category, String? sessionID) =>
      banners.add('${category.name}: ${content.title} | ${content.body}');

  @override
  void worldDidReact(CompanionEvent event, SessionSnapshot? session) => reacted.add(event.id);

  @override
  void userDidInteract(PetInteraction kind) => interacted.add(kind.name);
}

Map<String, Object?> _playing<A extends CharacterAnimationKind>(Playing<A> p, double base) => {
  'animation': (p.animation as Enum).name,
  'priority': p.priority.name,
  'startedAt': p.startedAt - base,
  'duration': ?p.duration,
  'token': p.token,
  'scriptID': ?p.scriptID,
};

void main() {
  final fixture = readWorldFixture('world.json');

  for (final c in cases(fixture)) {
    test(c['name'], () {
      var date = DateTime.fromMicrosecondsSinceEpoch(((c['date']! as num) * 1e6).round(), isUtc: true);
      var uptime = (c['uptime']! as num).toDouble();
      final base = uptime;
      void advance(double seconds) {
        date = date.add(Duration(microseconds: (seconds * 1e6).round()));
        uptime += seconds;
      }

      final recorder = _Recorder();
      const calendar = WorldCalendar.utc();
      final world = MochiWorld(
        settings: WorldSettings.fromJson(c['settings']),
        achievements: AchievementEngine(calendar: calendar),
        seed: parseUnsigned(c['seed']),
        clock: () => date,
        uptime: () => uptime,
        calendar: calendar,
        effects: recorder,
      );
      final snapshots = objs(c['snapshots']);
      var next = 0;
      for (final step in objs(c['steps'])) {
        switch (step['op']) {
          case 'run':
            final seconds = (step['seconds']! as num).toDouble();
            final every = (step['step']! as num).toDouble();
            var elapsed = 0.0;
            while (elapsed < seconds) {
              advance(every);
              world.tick();
              elapsed += every;
            }
          case 'wire':
            advance((step['after']! as num).toDouble());
            world.ingestWire(obj(step['wire']), delivery: byName(EventDelivery.values, step['delivery'] ?? 'live'));
            world.tick();
          case 'interact':
            world.interact(byName(PetInteraction.values, step['kind']));
          case 'poke':
            world.pokeCompanion();
          case 'system':
            world.updateSystem(SystemActivity(idleSeconds: (step['idleSeconds']! as num).toDouble()));
          case 'window':
            world.setWindowVisible(step['visible'] == true);
          case 'start':
            world.startInteraction(
              byName(InteractionID.values, step['interaction']),
              priority: byName(AnimationPriority.values, step['priority']),
              variant: step['variant']! as int,
            );
          case 'settings':
            world.settings = WorldSettings.fromJson({...world.settings.toJson(), ...obj(step['settings'])});
          case 'say':
            world.say(step['text']! as String);
          case 'snapshot':
            final expected = snapshots[next];
            final where = '${c['name']} snapshot $next (t=${expected['t']})';
            next += 1;
            final playback = world.interaction;
            final primary = world.primarySession;
            final attention = world.attention;
            final frame = world.frame();
            final actual = <String, Object?>{
              't': uptime - base,
              'pet': _playing(world.pet.current, base),
              'petBase': world.pet.base.name,
              'companion': _playing(world.companion.current, base),
              'companionBase': world.companion.base.name,
              'companionPresent': world.companionPresent,
              'petAsleep': world.petAsleep,
              if (playback != null)
                'interaction': {
                  'id': playback.id.name,
                  'variant': playback.variant,
                  'startedAt': playback.startedAt - base,
                  'companionLoop': playback.companionLoop.name,
                  'sessionLabel': ?playback.sessionLabel,
                },
              if (primary != null) 'primary': {'id': primary.id, 'phase': primary.phase.name},
              'mood': world.status.mood.name,
              if (attention != null) 'attention': '${attention.kind.name} ${attention.level.name}',
              'caption': ?world.activeCaption?.text,
              if (world.burst case final b?) 'burst': b.big ? 'big' : 'small',
              if (world.activeToast case final toast?) 'toast': '${toast.title} | ${toast.detail}',
              'speech': ?world.activeSpeech?.text,
              if (world.resultCards.isNotEmpty) 'resultCards': world.resultCards.length,
              'progress': {
                'points': world.progress.affectionPoints,
                'level': world.progress.friendshipLevel,
                'unlocked': [
                  for (final id in AchievementID.values)
                    if (world.progress.unlocked.containsKey(id.name)) id.name,
                ],
              },
              if (recorder.sounds.isNotEmpty) 'sounds': [...recorder.sounds],
              if (recorder.banners.isNotEmpty) 'banners': [...recorder.banners],
              if (recorder.reacted.isNotEmpty) 'reacted': [...recorder.reacted],
              if (recorder.interacted.isNotEmpty) 'interacted': [...recorder.interacted],
            };
            recorder.sounds.clear();
            recorder.banners.clear();
            recorder.reacted.clear();
            recorder.interacted.clear();
            final withoutFrame = Map<String, Object?>.of(expected)..remove('frame');
            expect(diffJson(actual, withoutFrame), isEmpty, reason: where);
            final f = obj(expected['frame']);
            final poses = [
              ...diffPet(frame.pet, obj(f['pet'])).map((d) => 'pet$d'),
              ...diffCompanion(frame.companion, obj(f['companion'])).map((d) => 'companion$d'),
              ...diffProps(frame.props, objs(f['props'])).map((d) => 'props$d'),
            ];
            expect(poses, isEmpty, reason: where);
            expect(frame.companionVisible, f['companionVisible'], reason: where);
        }
      }
      expect(next, snapshots.length);
    });
  }
}
