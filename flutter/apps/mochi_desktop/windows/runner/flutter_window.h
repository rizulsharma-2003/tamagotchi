#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// The window message a second copy of Mochi posts to the first before it exits (main.cpp): "show the main window".
inline UINT MochiShowMainMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"MochiShowMainWindow");
  return message;
}

// The window message the toast click handler (toasts.cpp) posts with the click's argument (a heap std::wstring*).
inline UINT MochiToastMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"MochiToastActivated");
  return message;
}

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // `mochi/instance`: tells Dart (lib/src/ui/shell.dart) that Mochi was launched again.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> instance_channel_;

  // `mochi/system` (lib/src/platform/runner_system.dart): the display going off and on, the session being locked or
  // switched, the PC going to sleep, and Mochi's global shortcuts (registered on this window, so Windows tells Mochi only
  // when one of its own combinations is pressed).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> system_channel_;
  HPOWERNOTIFY display_notification_ = nullptr;
  bool session_notifications_ = false;

  // The console display: 0 off, 1 on, 2 dimmed (-1 not known yet); the session: 1 locked, 0 not (-1 not known).
  int display_state_ = -1;
  int locked_ = -1;

  void HandleSystemCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SendSystem(const char* method, flutter::EncodableValue value);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
