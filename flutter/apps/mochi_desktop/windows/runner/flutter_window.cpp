#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <wtsapi32.h>

#include <cstdio>
#include <optional>

#include "desktop_icons.h"
#include "drop.h"
#include "jump_list.h"
#include "flutter/generated_plugin_registrant.h"
#include "media.h"
#include "native_stage.h"
#include "toasts.h"
#include "utils.h"

namespace {

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), wide.data(), length);
  return wide;
}

std::wstring StringArgument(const flutter::EncodableMap& arguments, const char* name) {
  const auto found = arguments.find(flutter::EncodableValue(name));
  if (found == arguments.end()) {
    return std::wstring();
  }
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::wstring() : Utf16FromUtf8(*value);
}

// GUID_CONSOLE_DISPLAY_STATE: the console display is off (0), on (1) or dimmed (2).
constexpr GUID kConsoleDisplayState = {0x6fe69556, 0x704a, 0x47a0, {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};

// Whether this session is locked now (WTSQuerySessionInformation's WTSSessionInfoEx): 1 locked, 0 not, -1 not known.
int SessionLocked() {
  LPWSTR buffer = nullptr;
  DWORD size = 0;
  if (!::WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, WTSSessionInfoEx, &buffer, &size) ||
      buffer == nullptr) {
    return -1;
  }
  int locked = -1;
  const auto* info = reinterpret_cast<const WTSINFOEXW*>(buffer);
  if (size >= sizeof(WTSINFOEXW) && info->Level == 1) {
    const LONG flags = info->Data.WTSInfoExLevel1.SessionFlags;
    if (flags == WTS_SESSIONSTATE_LOCK) {
      locked = 1;
    } else if (flags == WTS_SESSIONSTATE_UNLOCK) {
      locked = 0;
    }
  }
  ::WTSFreeMemory(buffer);
  return locked;
}

// X5: a desktop icon answer that says why there is none (for the stroll-debug log).
flutter::EncodableValue IconsError(const char* why) {
  flutter::EncodableMap error;
  error[flutter::EncodableValue("error")] = flutter::EncodableValue(std::string(why));
  return flutter::EncodableValue(error);
}

// A string argument that stays as UTF-8 (the icon ids are 16 hex characters).
std::string RawStringArgument(const flutter::EncodableMap& arguments, const char* name) {
  const auto found = arguments.find(flutter::EncodableValue(name));
  if (found == arguments.end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::string() : *value;
}

int IntArgument(const flutter::EncodableMap& arguments, const char* name) {
  const auto found = arguments.find(flutter::EncodableValue(name));
  if (found == arguments.end()) {
    return -1;
  }
  if (const auto* value = std::get_if<int32_t>(&found->second)) {
    return static_cast<int>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&found->second)) {
    return static_cast<int>(*value);
  }
  return -1;
}

}  // namespace

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

  system_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mochi/system",
          &flutter::StandardMethodCodec::GetInstance());
  system_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleSystemCall(call, std::move(result)); });
  // `mochi/stage`: Mochi's native stage (native_stage.h), windows of its own anywhere on any display.
  stage_ = std::make_unique<mochi_stage::Stage>(flutter_controller_->engine()->messenger());
  // `mochi/drop`: files, text and links dropped on Mochi (drop.h), an OLE drop target on the Flutter view.
  drop_ = std::make_unique<mochi_drop::Registration>(flutter_controller_->view()->GetNativeWindow(),
                                                     flutter_controller_->engine()->messenger());
  // Windows sends the display's state right away, and again whenever it changes.
  display_notification_ = ::RegisterPowerSettingNotification(GetHandle(), &kConsoleDisplayState, DEVICE_NOTIFY_WINDOW_HANDLE);
  session_notifications_ = ::WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION) != FALSE;
  locked_ = SessionLocked();

  // Mochi: the window is shown by Dart (window_manager), once it has the size
  // and form it starts in (the desktop pet), so there's no Show() on the first
  // frame here as in Flutter's template.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  mochi_toasts::Stop();
  // Win32Window::Create calls Destroy (and so this) before the window exists. The media and icon workers stop for good, so
  // they are stopped only once the window was made (the Flutter controller is OnCreate's); stopping them at that first
  // call left music detection (X7) and icon play (X5) off for the whole run.
  if (flutter_controller_) {
    mochi_media::Stop();
    mochi_icons::Stop();
  }
  if (icons_result_) {
    icons_result_->Success(IconsError("closing"));
    icons_result_ = nullptr;
  }
  stage_ = nullptr;
  drop_ = nullptr;
  if (display_notification_ != nullptr) {
    ::UnregisterPowerSettingNotification(display_notification_);
    display_notification_ = nullptr;
  }
  if (session_notifications_) {
    ::WTSUnRegisterSessionNotification(GetHandle());
    session_notifications_ = false;
  }
  system_channel_ = nullptr;
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
  // X5: the icon worker has an answer: the pending result is completed here, on the UI thread.
  if (message == kDesktopIconsDone) {
    AnswerIcons();
    return 0;
  }

  // Mochi was launched again: show the main window instead of a second copy. WPARAM is what the jump list's task asked
  // for; Dart gets that task's own argument (`--ask`, `--explore`) and parses it, anything else is just the window.
  if (message == MochiShowMainMessage()) {
    if (instance_channel_) {
      if (wparam == kLaunchAsk || wparam == kLaunchExplore) {
        instance_channel_->InvokeMethod(
            "showMain", std::make_unique<flutter::EncodableValue>(std::string(wparam == kLaunchAsk ? "--ask" : "--explore")));
      } else {
        instance_channel_->InvokeMethod("showMain", nullptr);
      }
    }
    return 0;
  }

  // A toast was clicked (toasts.cpp posts its argument here, on the UI thread).
  if (message == MochiToastMessage()) {
    auto* text = reinterpret_cast<std::wstring*>(lparam);
    if (text != nullptr) {
      SendSystem("toastActivated", flutter::EncodableValue(Utf8FromUtf16(text->c_str())));
      delete text;
    }
    return 0;
  }

  switch (message) {
    case WM_HOTKEY:
      // One of Mochi's own shortcuts (its id); nothing else is ever seen.
      SendSystem("hotkey", flutter::EncodableValue(static_cast<int32_t>(wparam)));
      return 0;
    case WM_POWERBROADCAST:
      if (wparam == PBT_POWERSETTINGCHANGE && lparam != 0) {
        const auto* setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
        if (::IsEqualGUID(setting->PowerSetting, kConsoleDisplayState) && setting->DataLength >= sizeof(DWORD)) {
          display_state_ = static_cast<int>(*reinterpret_cast<const DWORD*>(setting->Data));
          SendSystem("display", flutter::EncodableValue(static_cast<int32_t>(display_state_)));
        }
      } else if (wparam == PBT_APMSUSPEND) {
        SendSystem("power", flutter::EncodableValue("suspend"));
      } else if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
        SendSystem("power", flutter::EncodableValue("resume"));
      }
      break;
    case WM_DISPLAYCHANGE:
      // A display came or went, or changed its resolution: the stage's actors may be off screen now.
      if (stage_) {
        stage_->DisplaysChanged();
      }
      break;
    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA && stage_) {
        stage_->DisplaysChanged();
      }
      break;
    case WM_QUERYENDSESSION:
    case WM_ENDSESSION:
      // Windows is ending the session: the window nudges (X2) put back any window they moved. This never holds up the
      // shutdown; the message goes on to Flutter and the default handling as before.
      SendSystem("sessionEnding", flutter::EncodableValue(true));
      break;
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_SESSION_LOCK || wparam == WTS_CONSOLE_DISCONNECT) {
        locked_ = 1;
      } else if (wparam == WTS_SESSION_UNLOCK || wparam == WTS_CONSOLE_CONNECT) {
        locked_ = 0;
      }
      SendSystem("session", flutter::EncodableValue(static_cast<int32_t>(wparam)));
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
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

void FlutterWindow::SendSystem(const char* method, flutter::EncodableValue value) {
  if (system_channel_) {
    system_channel_->InvokeMethod(method, std::make_unique<flutter::EncodableValue>(std::move(value)));
  }
}

void FlutterWindow::HandleSystemCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "state") {
    if (locked_ < 0) {
      locked_ = SessionLocked();
    }
    flutter::EncodableMap state;
    state[flutter::EncodableValue("display")] = flutter::EncodableValue(static_cast<int32_t>(display_state_));
    state[flutter::EncodableValue("locked")] = flutter::EncodableValue(static_cast<int32_t>(locked_));
    result->Success(flutter::EncodableValue(state));
    return;
  }
  // X7: whether media is playing (media.cpp; a bool, never what is playing).
  if (method == "isMediaPlaying") {
    result->Success(flutter::EncodableValue(mochi_media::IsPlaying()));
    return;
  }
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  // X5: desktop icon play (desktop_icons.cpp; opaque ids and positions only, never a name). The answer comes later, from
  // the worker thread's post (kDesktopIconsDone).
  if (method == "desktopIcons") {
    AskIcons(false, nullptr, std::move(result));
    return;
  }
  if (method == "moveDesktopIcon") {
    AskIcons(true, arguments, std::move(result));
    return;
  }
  if (method == "registerHotKey" && arguments != nullptr) {
    const int id = IntArgument(*arguments, "id");
    const int modifiers = IntArgument(*arguments, "modifiers");
    const int key = IntArgument(*arguments, "key");
    if (id <= 0 || modifiers < 0 || key <= 0) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    // MOD_NOREPEAT: holding the keys down sends one press, not a stream of them.
    const BOOL registered =
        ::RegisterHotKey(GetHandle(), id, static_cast<UINT>(modifiers) | MOD_NOREPEAT, static_cast<UINT>(key));
    result->Success(flutter::EncodableValue(registered != FALSE));
    return;
  }
  if (method == "unregisterHotKey" && arguments != nullptr) {
    const int id = IntArgument(*arguments, "id");
    if (id > 0) {
      ::UnregisterHotKey(GetHandle(), id);
    }
    result->Success();
    return;
  }
  // X16: the Start menu's jump list (jump_list.cpp), built on this (the UI) thread; the HRESULT, 0 when built.
  if (method == "buildJumpList") {
    result->Success(flutter::EncodableValue(static_cast<int32_t>(mochi_jumplist::Build())));
    return;
  }
  if (method == "toastStart" && arguments != nullptr) {
    const bool started = mochi_toasts::Start(GetHandle(), MochiToastMessage(), StringArgument(*arguments, "clsid"));
    result->Success(flutter::EncodableValue(started));
    return;
  }
  if (method == "toastShow" && arguments != nullptr) {
    const HRESULT shown = mochi_toasts::Show(StringArgument(*arguments, "appId"), StringArgument(*arguments, "xml"),
                                             StringArgument(*arguments, "tag"));
    result->Success(flutter::EncodableValue(static_cast<int32_t>(shown)));
    return;
  }
  if (method == "toastSetting" && arguments != nullptr) {
    result->Success(flutter::EncodableValue(static_cast<int32_t>(mochi_toasts::Setting(StringArgument(*arguments, "appId")))));
    return;
  }
  result->NotImplemented();
}

// Starts a desktop icon request. One result is pending at a time: a second call answers the old one with null first (Dart
// then reads again before it trusts anything).
void FlutterWindow::AskIcons(bool move, const flutter::EncodableMap* arguments,
                             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (icons_result_) {
    icons_result_->Success(IconsError("replaced"));
    icons_result_ = nullptr;
  }
  uint32_t seq = 0;
  if (!move) {
    seq = mochi_icons::RequestRead(GetHandle(), kDesktopIconsDone);
  } else if (arguments != nullptr) {
    const std::string id = RawStringArgument(*arguments, "id");
    const bool has_point = arguments->count(flutter::EncodableValue("x")) != 0 && arguments->count(flutter::EncodableValue("y")) != 0;
    if (!id.empty() && has_point) {
      seq = mochi_icons::RequestMove(GetHandle(), kDesktopIconsDone, id, IntArgument(*arguments, "x"), IntArgument(*arguments, "y"));
    }
  }
  if (seq == 0) {
    result->Success(IconsError(move ? "no move asked" : "worker not started"));
    return;
  }
  icons_seq_ = seq;
  icons_result_ = std::move(result);
}

// The worker answered: completes the pending result when the answer is the one it waits for (an older answer is dropped).
void FlutterWindow::AnswerIcons() {
  mochi_icons::Answer answer;
  if (!mochi_icons::Take(&answer) || !icons_result_ || answer.seq != icons_seq_) {
    return;
  }
  auto result = std::move(icons_result_);
  icons_result_ = nullptr;
  if (answer.kind == mochi_icons::Kind::Move) {
    result->Success(flutter::EncodableValue(answer.ok));
    return;
  }
  if (!answer.ok) {
    // Which shell call failed, for the stroll-debug log (a step number and an HRESULT, nothing about the desktop).
    char failure[48] = {0};
    sprintf_s(failure, sizeof(failure), "step %d, 0x%08lx", answer.failed_step, static_cast<unsigned long>(answer.failed_hr));
    flutter::EncodableMap error;
    error[flutter::EncodableValue("error")] = flutter::EncodableValue(std::string(failure));
    result->Success(flutter::EncodableValue(error));
    return;
  }
  flutter::EncodableMap map;
  map[flutter::EncodableValue("autoArrange")] = flutter::EncodableValue(answer.auto_arrange);
  map[flutter::EncodableValue("grid")] = flutter::EncodableValue(answer.grid);
  map[flutter::EncodableValue("hidden")] = flutter::EncodableValue(answer.hidden);
  map[flutter::EncodableValue("more")] = flutter::EncodableValue(answer.more);
  map[flutter::EncodableValue("iconSize")] = flutter::EncodableValue(static_cast<int32_t>(answer.icon_size));
  flutter::EncodableList spacing;
  spacing.push_back(flutter::EncodableValue(static_cast<int32_t>(answer.spacing_x)));
  spacing.push_back(flutter::EncodableValue(static_cast<int32_t>(answer.spacing_y)));
  map[flutter::EncodableValue("spacing")] = flutter::EncodableValue(spacing);
  flutter::EncodableList icons;
  for (const auto& icon : answer.icons) {
    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("id")] = flutter::EncodableValue(icon.id);
    entry[flutter::EncodableValue("x")] = flutter::EncodableValue(static_cast<int32_t>(icon.x));
    entry[flutter::EncodableValue("y")] = flutter::EncodableValue(static_cast<int32_t>(icon.y));
    icons.push_back(flutter::EncodableValue(entry));
  }
  map[flutter::EncodableValue("icons")] = flutter::EncodableValue(icons);
  result->Success(flutter::EncodableValue(map));
}
