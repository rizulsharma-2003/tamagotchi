#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <wtsapi32.h>

#include <optional>

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
  mochi_media::Stop();
  stage_ = nullptr;
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
  // Mochi was launched again: show the main window instead of a second copy.
  if (message == MochiShowMainMessage()) {
    if (instance_channel_) {
      instance_channel_->InvokeMethod("showMain", nullptr);
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
