#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <map>
#include <memory>

#include "drop.h"
#include "native_stage.h"
#include "pc_actions.h"
#include "win32_window.h"

// The window message a second copy of Mochi posts to the first before it exits (main.cpp): "show the main window".
inline UINT MochiShowMainMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"MochiShowMainWindow");
  return message;
}

// What the second copy asks for in MochiShowMainMessage's WPARAM, from its command line (the Start-menu jump list's tasks
// start `Mochi.exe --ask` and `Mochi.exe --explore`): the window only, Ask Mochi, or Explore.
constexpr WPARAM kLaunchShow = 0;
constexpr WPARAM kLaunchAsk = 1;
constexpr WPARAM kLaunchExplore = 2;

// The window message the toast click handler (toasts.cpp) posts with the click's argument (a heap std::wstring*).
inline UINT MochiToastMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"MochiToastActivated");
  return message;
}

// The window message desktop_icons.cpp's worker posts when it has an answer (X5); the UI thread completes the method
// channel's pending result then.
constexpr UINT kDesktopIconsDone = WM_APP + 5;

// The window message pc_actions.cpp's worker posts when it has an answer (W9), with the request's number in WPARAM; the UI
// thread completes that request's method channel result then.
constexpr UINT kPcActionsDone = WM_APP + 6;

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

  // `mochi/stage` (lib/src/platform/native_stage.dart): Mochi's native stage, windows of its own anywhere on screen.
  std::unique_ptr<mochi_stage::Stage> stage_;
  bool session_notifications_ = false;

  // `mochi/drop` (lib/src/platform/file_drop.dart): the OLE drop target on the Flutter view (X13, X14).
  std::unique_ptr<mochi_drop::Registration> drop_;

  // The console display: 0 off, 1 on, 2 dimmed (-1 not known yet); the session: 1 locked, 0 not (-1 not known).
  int display_state_ = -1;
  int locked_ = -1;

  // X5: the one pending `desktopIcons` / `moveDesktopIcon` result (completed on the UI thread when the worker answers),
  // and the request it waits for.
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> icons_result_;
  uint32_t icons_seq_ = 0;
  void AskIcons(bool move, const flutter::EncodableMap* arguments,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void AnswerIcons();

  // W9: the pending results of Ask Mochi's PC actions (apps, volume, tasks), by the request's number; each is completed on the
  // UI thread when pc_actions.cpp's worker answers.
  std::map<uint32_t, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>> pc_results_;
  void AskPc(const mochi_pc::Job& job, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void AnswerPc(uint32_t token);

  void HandleSystemCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SendSystem(const char* method, flutter::EncodableValue value);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
