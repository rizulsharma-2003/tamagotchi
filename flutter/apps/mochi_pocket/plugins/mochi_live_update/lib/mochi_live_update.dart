/// Mochi for Android's ongoing notification while Claude works on the computer: the Android twin of the iPhone's Live
/// Activity (iOS/MochiLiveActivity). The app decides what it says (`lib/src/live` in mochi_pocket); this posts it,
/// from the app or from the FCM push handler's background isolate.
///
/// One notification, updated in place: Mochi's pose for the phase (the iPhone's art, copied into the app's drawables
/// at build time), the title and detail, the elapsed time, Open (and Open the Session when Claude needs you). On
/// Android 16 it asks to be promoted to a Live Update with a status bar chip; before that it's an ongoing notification
/// whose expanded view shows the whole scene.
library;

import 'package:flutter/services.dart';

/// What [MochiLiveUpdate.show] says happened.
enum LiveUpdatePosted {
  /// Posted (or updated in place).
  shown,

  /// Not posted: something newer was posted already (the other isolate got there first).
  older,

  /// Not posted: notifications are turned off for Mochi.
  blocked,

  /// The platform side isn't there (tests, other platforms).
  unavailable,
}

/// The notification's state on the phone ([MochiLiveUpdate.status]).
class LiveUpdateStatus {
  const LiveUpdateStatus({required this.enabled, this.promotable, this.sdk = 0});

  /// Mochi may post notifications, and the "While Claude works" channel isn't turned off.
  final bool enabled;

  /// Android 16+: whether the user lets Mochi's notifications be Live Updates (null before Android 16).
  final bool? promotable;

  /// Android's API level.
  final int sdk;
}

abstract final class MochiLiveUpdate {
  static const MethodChannel _channel = MethodChannel('com.insideedge.mochi/live_update');

  /// Posts [view] (see `LiveUpdateView.toMap` in the app), unless its `timestamp` is older than the last one posted.
  static Future<LiveUpdatePosted> show(Map<String, Object?> view) async {
    try {
      final answer = await _channel.invokeMethod<String>('show', view);
      return LiveUpdatePosted.values.where((value) => value.name == answer).firstOrNull ?? LiveUpdatePosted.unavailable;
    } on MissingPluginException {
      return LiveUpdatePosted.unavailable;
    }
  }

  /// Takes it away, unless [timestamp] is older than the last one posted ([force]: always).
  static Future<void> cancel({int? timestamp, bool force = false}) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'timestamp': ?timestamp, 'force': force});
    } on MissingPluginException {
      // Nothing to take away.
    }
  }

  /// Whether it's in the notification shade right now (the user may have swiped it away).
  static Future<bool> isShowing() async {
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<LiveUpdateStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
      return LiveUpdateStatus(
        enabled: map['enabled'] == true,
        promotable: map['promotable'] as bool?,
        sdk: (map['sdk'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      return const LiveUpdateStatus(enabled: false);
    }
  }

  /// Forgets the last timestamp posted (after unpairing: a new room starts afresh).
  static Future<void> reset() async {
    try {
      await _channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // Nothing kept.
    }
  }
}
