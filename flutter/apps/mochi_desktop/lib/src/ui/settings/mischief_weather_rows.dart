// Local weather under Settings › Mischief › "Weather and time moods" (docs/SPRINT_2.md X12): its own switch (off at first) and
// the city you type, which is looked up once. Only the city's rough position (to a tenth of a degree) is kept and sent, to
// Open-Meteo.

import 'package:flutter/material.dart';

import '../../core/mischief.dart';
import '../../core/moods.dart' show CityProblem, DesktopMoods;
import 'settings_kit.dart';

class WeatherRows extends StatefulWidget {
  const WeatherRows({super.key, required this.host});

  final SettingsHost host;

  @override
  State<WeatherRows> createState() => _WeatherRowsState();
}

class _WeatherRowsState extends State<WeatherRows> {
  late final TextEditingController _city = TextEditingController(text: widget.host.desktop.settings.weather.city ?? '');
  bool _looking = false;
  String? _said;

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
  }

  Future<void> _set(DesktopMoods moods) async {
    setState(() {
      _looking = true;
      _said = null;
    });
    final problem = await moods.setCity(_city.text);
    if (!mounted) return;
    setState(() {
      _looking = false;
      _said = switch (problem) {
        null => null,
        CityProblem.empty => 'Type a city first.',
        CityProblem.notFound => 'Open-Meteo doesn’t know that city. Try its English name.',
        CityProblem.offline => 'Couldn’t reach Open-Meteo. Try again in a moment.',
      };
    });
    final city = widget.host.desktop.settings.weather.city;
    if (problem == null && city != null) _city.text = city;
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final desktop = host.desktop;
    final settings = desktop.settings;
    final weather = settings.weather;
    final moods = host.mischief?.moods;
    final available = moods != null && settings.mischief.enabled && settings.mischief.on(MischiefExtra.moods) && desktop.mischief.supported;
    final city = weather.city;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToggleRow(
          title: 'Local weather',
          subtitle:
              '${host.pet} holds a little umbrella on the taskbar while it rains where you are. Off at first. Only the city’s rough '
              'position (to about 10 km) goes to Open-Meteo, every 30 minutes, with no key or name of yours.',
          value: weather.enabled,
          onChanged: available ? (value) => settings.weather = weather.copyWith(enabled: value) : null,
        ),
        if (weather.enabled)
          Padding(
            padding: rowPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _city,
                    maxLength: 60,
                    enabled: available,
                    textInputAction: TextInputAction.done,
                    onSubmitted: available && !_looking ? (_) => _set(moods) : null,
                    decoration: const InputDecoration(labelText: 'City', hintText: 'Pune', counterText: '', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: available && !_looking ? () => _set(moods) : null, child: Text(_looking ? 'Looking…' : 'Set')),
                if (city != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: available
                        ? () {
                            moods.forgetCity();
                            _city.clear();
                          }
                        : null,
                    child: const Text('Forget'),
                  ),
                ],
              ],
            ),
          ),
        if (weather.enabled)
          NoteRow(
            text: _said ?? (city == null ? 'No city yet: no umbrella until you set one.' : 'Using $city.'),
            icon: _said == null ? Icons.cloud_outlined : Icons.error_outline_rounded,
          ),
      ],
    );
  }
}
