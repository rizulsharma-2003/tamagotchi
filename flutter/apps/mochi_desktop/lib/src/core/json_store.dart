// A small JSON file in Mochi's folder for the features that keep their own (the focus log, the recap's event journal,
// the holidays already greeted), as the Mac keeps focus-log.json, the event journal and seasons.json beside its
// settings; in memory in tests and the demo.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract interface class JsonStore {
  /// What was saved (null: nothing yet, or unreadable).
  Object? read();
  void write(Object? json);

  /// Removes what was saved (the file itself goes).
  void delete();
}

class FileJsonStore implements JsonStore {
  FileJsonStore(this.path);

  final String path;

  @override
  Object? read() {
    try {
      return jsonDecode(File(path).readAsStringSync());
    } on Object {
      return null;
    }
  }

  @override
  void write(Object? json) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final temporary = File('$path.tmp');
      temporary.writeAsStringSync(jsonEncode(json), flush: true);
      temporary.renameSync(path);
    } on Object catch (error) {
      debugPrint('Mochi: ${path.split(Platform.pathSeparator).last} could not be saved (${error.runtimeType})');
    }
  }

  @override
  void delete() {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on Object catch (error) {
      debugPrint('Mochi: ${path.split(Platform.pathSeparator).last} could not be removed (${error.runtimeType})');
    }
  }
}

class MemoryJsonStore implements JsonStore {
  MemoryJsonStore([this.json]);

  Object? json;

  /// How many times it was saved (tests).
  int writes = 0;

  @override
  Object? read() => json;

  @override
  void write(Object? json) {
    writes++;
    this.json = jsonDecode(jsonEncode(json));
  }

  /// How many times it was deleted (tests).
  int deletes = 0;

  @override
  void delete() {
    deletes++;
    json = null;
  }
}
