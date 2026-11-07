import 'dart:io';

/// The file operations [FolderSwap] uses, so tests can make any one of them fail.
abstract interface class FolderOps {
  bool directoryExists(String path);
  bool fileExists(String path);

  /// Renames a folder (same volume: atomic on NTFS). Throws [FileSystemException].
  void rename(String from, String to);

  /// Deletes a folder and everything in it. Throws [FileSystemException].
  void deleteTree(String path);

  /// Copies a folder's contents into [to] (made if needed). Throws [FileSystemException].
  void copyTree(String from, String to);

  void sleep(Duration duration);
}

class IoFolderOps implements FolderOps {
  const IoFolderOps();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  void rename(String from, String to) => Directory(from).renameSync(to);

  @override
  void deleteTree(String path) {
    final directory = Directory(path);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  @override
  void copyTree(String from, String to) => copyDirectory(from, to);

  @override
  void sleep(Duration duration) {
    if (duration > Duration.zero) _sleep(duration);
  }
}

/// dart:io's `sleep` (the name [FolderOps.sleep] hides inside the class).
void _sleep(Duration duration) => sleep(duration);

/// Copies every file under [from] into [to] (folders made as needed; existing files replaced). Returns the bytes
/// copied. Links are copied as what they point to.
int copyDirectory(String from, String to) {
  final source = Directory(from);
  final separator = Platform.pathSeparator;
  var bytes = 0;
  Directory(to).createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: true)) {
    final relative = entity.path.substring(source.path.length).replaceFirst(RegExp(r'^[\\/]+'), '');
    final target = '$to$separator$relative';
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
      bytes += entity.lengthSync();
    }
  }
  return bytes;
}

/// Takes Windows' "downloaded from the internet" mark (the `Zone.Identifier` stream a browser or an unzip of a
/// downloaded zip leaves on each file) off every file under [directory]. Copies keep it, and an installed Mochi with
/// it would get SmartScreen's warning again whenever it's started from the Start menu; installers' own files never
/// carry it. Returns how many marks were removed. Does nothing elsewhere.
int removeDownloadMarks(String directory) {
  if (!Platform.isWindows) return 0;
  var removed = 0;
  for (final entity in Directory(directory).listSync(recursive: true)) {
    if (entity is! File) continue;
    final mark = File('${entity.path}:Zone.Identifier');
    try {
      if (mark.existsSync()) {
        mark.deleteSync();
        removed++;
      }
    } on FileSystemException {
      // Only a warning dialog: carry on.
    }
  }
  return removed;
}

/// How a swap ended.
class SwapResult {
  const SwapResult.done() : ok = true, error = null, rolledBack = false;
  const SwapResult.failed(this.error, {this.rolledBack = false}) : ok = false;

  final bool ok;

  /// What went wrong, in words (null when [ok]).
  final String? error;

  /// The new copy went in and had to be taken out again: the old copy is back.
  final bool rolledBack;

  @override
  String toString() => ok ? 'SwapResult(ok)' : 'SwapResult(failed: $error${rolledBack ? ', rolled back' : ''})';
}

/// Puts a new copy of an app folder in place of the old one, so that afterwards either the whole new copy or the whole
/// old one is there, never half of each: the old folder is renamed aside (`<target>.old`), the new one renamed in, and
/// on any failure the old one is renamed back. Renames are retried for a while, because Windows keeps a file busy for
/// a moment after the process that used it has gone (and antivirus scanners open new files).
///
/// The `.old` folder is left for the app to delete at its next launch: by then nothing in it is running.
class FolderSwap {
  FolderSwap({
    FolderOps ops = const IoFolderOps(),
    this.retryFor = const Duration(seconds: 15),
    this.retryEvery = const Duration(milliseconds: 250),
    void Function(String message)? log,
  }) : _ops = ops,
       _log = log;

  final FolderOps _ops;
  final Duration retryFor;
  final Duration retryEvery;
  final void Function(String message)? _log;

  /// Replaces [target] with [incoming]. [requiredFile] (relative) must be in [incoming] first and in [target] after.
  SwapResult swap({required String incoming, required String target, required String requiredFile, String? separator}) {
    final sep = separator ?? Platform.pathSeparator;
    if (!_ops.fileExists('$incoming$sep$requiredFile')) {
      return SwapResult.failed('The new copy of Mochi is incomplete (it has no $requiredFile).');
    }
    var old = '$target.old';
    if (_ops.directoryExists(old)) {
      // Left from an earlier update (the app deletes it at launch): out of the way first.
      if (!_retry('delete the previous .old folder', () => _ops.deleteTree(old))) {
        old = '$target.old-${DateTime.now().millisecondsSinceEpoch}';
      }
    }
    final hadTarget = _ops.directoryExists(target);
    if (hadTarget && !_retry('move the current copy aside', () => _ops.rename(target, old))) {
      return const SwapResult.failed("Mochi's folder is still in use, so nothing was changed. Close Mochi and try again.");
    }

    Object? problem;
    try {
      _retryOrThrow('move the new copy in', () => _ops.rename(incoming, target));
    } on FileSystemException catch (error) {
      if (_crossVolume(error)) {
        // The new copy is on another drive (only when Mochi's folders were moved): copy instead of rename.
        _say('the new copy is on another volume: copying it in');
        try {
          _ops.copyTree(incoming, target);
          _tryDelete(incoming);
        } on FileSystemException catch (copyError) {
          problem = copyError;
        }
      } else {
        problem = error;
      }
    }
    if (problem == null && !_ops.fileExists('$target$sep$requiredFile')) problem = 'the new copy has no $requiredFile in place';
    if (problem == null) {
      _say('swapped in the new copy');
      return const SwapResult.done();
    }

    // Roll back: whatever got in goes, the old copy comes back.
    _say('rolling back ($problem)');
    if (_ops.directoryExists(target)) {
      if (!_retry('take the new copy out', () => _ops.rename(target, incoming))) _tryDelete(target);
    }
    if (hadTarget && !_retry('put the old copy back', () => _ops.rename(old, target))) {
      return SwapResult.failed("The update failed and the old copy couldn't be put back. It's in $old.", rolledBack: false);
    }
    return SwapResult.failed("The new copy couldn't be put in place, so Mochi stayed as it was. ($problem)", rolledBack: true);
  }

  /// Runs [action] until it works or [retryFor] has passed; false if it never worked.
  bool _retry(String what, void Function() action) {
    try {
      _retryOrThrow(what, action);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  void _retryOrThrow(String what, void Function() action) {
    final watch = Stopwatch()..start();
    var attempts = 0;
    while (true) {
      attempts++;
      try {
        action();
        if (attempts > 1) _say('$what: worked on attempt $attempts');
        return;
      } on FileSystemException catch (error) {
        if (_crossVolume(error) || watch.elapsed >= retryFor) {
          _say("$what: failed after $attempts attempt${attempts == 1 ? '' : 's'} (${error.osError?.errorCode ?? error.message})");
          rethrow;
        }
        _ops.sleep(retryEvery);
      }
    }
  }

  void _tryDelete(String path) {
    try {
      _ops.deleteTree(path);
    } on FileSystemException {
      // Left behind; harmless.
    }
  }

  /// ERROR_NOT_SAME_DEVICE (Windows) or EXDEV (POSIX).
  static bool _crossVolume(FileSystemException error) {
    final code = error.osError?.errorCode;
    return (code == 17 && Platform.isWindows) || (code == 18 && !Platform.isWindows);
  }

  void _say(String message) => _log?.call(message);
}
