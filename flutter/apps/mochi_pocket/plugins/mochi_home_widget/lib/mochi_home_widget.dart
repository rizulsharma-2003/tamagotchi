/// Mochi for Android's home-screen widget, "Mochi & Claude" (the iPhone's Lock Screen and Home Screen widget,
/// iOS/MochiLiveActivity/WaitingWidget.swift, plus Claude): the app decides what it shows (`lib/src/widget` in
/// mochi_pocket); this hands it to Android, from the app or from the FCM push handler's background isolate. The widget's
/// provider and layouts are in the app (android/app/src/main/kotlin/com/insideedge/mochi/widget).
library;

import 'package:flutter/services.dart';

/// The widget on this phone ([MochiHomeWidget.status]).
class HomeWidgetPlacement {
  const HomeWidgetPlacement({this.placed = 0, this.canPin = false});

  /// How many are on the home screen.
  final int placed;

  /// The launcher can be asked to add one ([MochiHomeWidget.pin]).
  final bool canPin;
}

abstract final class MochiHomeWidget {
  static const MethodChannel _channel = MethodChannel('com.insideedge.mochi/home_widget');

  /// Keeps [view] for the widget and redraws every one on the home screen. How many there are; null when the
  /// platform side isn't there (tests, other platforms).
  static Future<int?> update(Map<String, Object?> view) async {
    try {
      return await _channel.invokeMethod<int>('update', view);
    } on MissingPluginException {
      return null;
    }
  }

  /// Asks the launcher to add the widget (Android shows its own question). False when it can't be asked.
  static Future<bool> pin() async {
    try {
      return await _channel.invokeMethod<bool>('pin') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<HomeWidgetPlacement> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
      return HomeWidgetPlacement(placed: (map['placed'] as num?)?.toInt() ?? 0, canPin: map['canPin'] == true);
    } on MissingPluginException {
      return const HomeWidgetPlacement();
    }
  }
}
