import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Mochi lives in the menu bar (the Windows tray's stand-in): closing the window doesn't quit it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
