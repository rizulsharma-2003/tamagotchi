// Mochi gallery: the mochi_art port of Mochi, Patch and the room, for eyeballing against the
// Swift app. The animations play from poses recorded from the Swift code
// (assets/pose_tracks.json.deflate, written by flutter/tools/pose_export).
//
//   cd flutter/apps/mochi_gallery && flutter run -d macos

import 'package:flutter/material.dart';

import 'pages.dart';
import 'tracks.dart';
import 'widgets.dart';

void main() => runApp(const GalleryApp());

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key, this.library});

  /// The pose tracks (loaded from the assets when not given).
  final Future<PoseLibrary>? library;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mochi Gallery',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFFD99D6C), useMaterial3: true),
    home: GalleryHome(library: library),
  );
}

class GalleryHome extends StatefulWidget {
  const GalleryHome({super.key, this.library});

  final Future<PoseLibrary>? library;

  @override
  State<GalleryHome> createState() => _GalleryHomeState();
}

class _GalleryHomeState extends State<GalleryHome> with SingleTickerProviderStateMixin {
  late final GalleryClock clock = GalleryClock(this);
  late final Future<PoseLibrary> library = widget.library ?? PoseLibrary.load(DefaultAssetBundle.of(context));
  int page = 0;

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClockScope(
    clock: clock,
    child: Scaffold(
      body: FutureBuilder<PoseLibrary>(
        future: library,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (snapshot.hasError) return Center(child: Text('Could not load the pose tracks: ${snapshot.error}'));
          if (data == null) return const Center(child: CircularProgressIndicator());
          return Row(
            children: [
              NavigationRail(
                selectedIndex: page,
                onDestinationSelected: (index) => setState(() => page = index),
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(icon: Icon(Icons.pets), label: Text('Mochi')),
                  NavigationRailDestination(icon: Icon(Icons.smart_toy_outlined), label: Text('Patch')),
                  NavigationRailDestination(icon: Icon(Icons.weekend_outlined), label: Text('Room')),
                  NavigationRailDestination(icon: Icon(Icons.category_outlined), label: Text('Props')),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: switch (page) {
                  0 => MochiPage(library: data),
                  1 => PatchPage(library: data),
                  2 => RoomPage(library: data),
                  _ => const PropsPage(),
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}
