/// What kind of thing a [LinkKey] carries.
enum LinkKeyKind {
  /// Only the latest value matters; the relay keeps it and hands it to every `sync`.
  state,

  /// Meant to be handled once: queued for its targets until they ack it or its TTL runs out.
  message,

  /// A device's push address (with Mochi Link these are relay state owned by the pocket).
  registration,
}

/// Everything Mochi's apps share with each other (docs/MOCHI_LINK_PLAN.md section 3): Swift `LinkKey`, with the
/// same raw values (`name`) and kinds. The relay knows a few more keys (`agentNews`, `done.<device>`) that the
/// apps don't use yet; frames for those are ignored, as in Swift.
enum LinkKey {
  // State, Mac → phone
  look,
  claude,
  sessions,
  agent,
  cloud,
  approval,
  macDone,
  // State, phone → Mac
  phoneDone,
  // Messages
  activityEnded,
  macInteraction,
  phoneInteraction,
  command,
  reply,
  verdict,
  // Registration (phone → relay)
  pushToStart,
  updateTokens,
  deviceToken,
  tokensSavedAt;

  /// The key for a raw value on the wire, or null for one this client doesn't know.
  static LinkKey? tryParse(Object? raw) {
    for (final key in values) {
      if (key.name == raw) return key;
    }
    return null;
  }

  LinkKeyKind get kind => switch (this) {
    look || claude || sessions || agent || cloud || approval || macDone || phoneDone => LinkKeyKind.state,
    activityEnded || macInteraction || phoneInteraction || command || reply || verdict => LinkKeyKind.message,
    pushToStart || updateTokens || deviceToken || tokensSavedAt => LinkKeyKind.registration,
  };

  /// Who a message goes to (Swift `relayTargets`): commands and verdicts to the computer, replies and pokes to the
  /// phone. Null (state and registration) means everyone else in the room.
  List<String>? get relayTargets => switch (this) {
    command || verdict || phoneInteraction => const ['host'],
    reply || macInteraction || activityEnded => const ['pocket'],
    _ => null,
  };

  /// Seconds a message waits for an offline device before the relay drops it (Swift `relayTTL`).
  int? get relayTtl => switch (this) {
    command || verdict || reply => 600,
    phoneInteraction || macInteraction => 90,
    activityEnded => 3600,
    _ => null,
  };

  /// The Swift apps store these values as a JSON *string* (their Codable models' `json`), not as an object; the
  /// rest are dictionaries or plain values (`link-spec/fixtures/*.json`, `storedAs`).
  bool get storedAsJsonString => switch (this) {
    look || sessions || agent || macDone || phoneDone => true,
    _ => false,
  };
}
