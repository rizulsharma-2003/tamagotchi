#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mochi/instance",
          &flutter::StandardMethodCodec::GetInstance());

  // Mochi: the window is shown by Dart (window_manager), once it has the size
  // and form it starts in (the desktop pet), so there's no Show() on the first
  // frame here as in Flutter's template.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  instance_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Mochi was launched again: show the main window instead of a second copy.
  if (message == MochiShowMainMessage()) {
    if (instance_channel_) {
      instance_channel_->InvokeMethod("showMain", nullptr);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    // Mochi: the desktop pet's window in the taskbar is Mochi's box (64 x 40
    // at 100%), smaller than Windows' minimum for a window with a title bar
    // (SM_CXMINTRACK: 136 at 100%). Left at that minimum, the window is wider
    // than the pet asked for and Mochi is drawn off the spot its clicks are
    // checked at. Unless something set a minimum of its own (window_manager,
    // for the main window), any size goes.
    if (message == WM_GETMINMAXINFO) {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = ::GetDpiForWindow(hwnd);
      if (info->ptMinTrackSize.x ==
          ::GetSystemMetricsForDpi(SM_CXMINTRACK, dpi)) {
        info->ptMinTrackSize.x = 1;
      }
      if (info->ptMinTrackSize.y ==
          ::GetSystemMetricsForDpi(SM_CYMINTRACK, dpi)) {
        info->ptMinTrackSize.y = 1;
      }
      return 0;
    }
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
