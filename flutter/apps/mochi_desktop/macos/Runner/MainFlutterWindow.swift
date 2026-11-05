import Cocoa
import FlutterMacOS
import window_manager

// The macOS development build of Mochi for Windows: one transparent window that's either the desktop pet or the main
// window (lib/src/ui/shell.dart), hidden until Dart has sized it.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Transparent, so the pet sits on the desktop with nothing around it.
    self.isOpaque = false
    self.backgroundColor = .clear
    flutterViewController.backgroundColor = .clear

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
