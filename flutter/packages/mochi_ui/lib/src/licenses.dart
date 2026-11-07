import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Adds Nunito's SIL Open Font License to the app's licence page (`showLicensePage`), once. Flutter lists the
/// packages' licences by itself; a bundled font's needs adding.
void registerMochiFontLicense() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('packages/mochi_ui/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Nunito (font)'], text);
  });
}
