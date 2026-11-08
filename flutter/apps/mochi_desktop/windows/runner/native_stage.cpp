#include "native_stage.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <cstring>
#include <string>
#include <utility>

namespace mochi_stage {
namespace {

constexpr const wchar_t kWindowClass[] = L"MOCHI_STAGE_ACTOR";

// The largest picture an actor takes (a note, a firework): anything bigger is a mistake on the Dart side.
constexpr int kMaxSide = 4096;

bool RegisterActorClass(WNDPROC procedure) {
  static bool registered = false;
  if (registered) {
    return true;
  }
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = procedure;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  window_class.lpszClassName = kWindowClass;
  registered = ::RegisterClassExW(&window_class) != 0;
  return registered;
}

const flutter::EncodableValue* Field(const flutter::EncodableMap& map, const char* name) {
  const auto found = map.find(flutter::EncodableValue(name));
  return found == map.end() ? nullptr : &found->second;
}

int IntField(const flutter::EncodableMap& map, const char* name) {
  const auto* value = Field(map, name);
  if (value == nullptr) {
    return 0;
  }
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    return static_cast<int>(*narrow);
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return static_cast<int>(*wide);
  }
  return 0;
}

// An integer that Dart's codec sent as an int32 or as an int64 (a window handle can be either).
bool Int64Of(const flutter::EncodableValue& value, int64_t* out) {
  if (const auto* narrow = std::get_if<int32_t>(&value)) {
    *out = *narrow;
    return true;
  }
  if (const auto* wide = std::get_if<int64_t>(&value)) {
    *out = *wide;
    return true;
  }
  return false;
}

// An Int32List argument (Dart's Int32List), or a plain list of ints.
std::vector<int32_t> Ints(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return {};
  }
  if (const auto* list = std::get_if<std::vector<int32_t>>(value)) {
    return *list;
  }
  std::vector<int32_t> ints;
  if (const auto* list = std::get_if<flutter::EncodableList>(value)) {
    for (const auto& item : *list) {
      if (const auto* narrow = std::get_if<int32_t>(&item)) {
        ints.push_back(*narrow);
      } else if (const auto* wide = std::get_if<int64_t>(&item)) {
        ints.push_back(static_cast<int32_t>(*wide));
      }
    }
  }
  return ints;
}

}  // namespace

Stage::Stage(flutter::BinaryMessenger* messenger) {
  memory_ = ::CreateCompatibleDC(nullptr);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mochi/stage", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleCall(call, std::move(result)); });
}

Stage::~Stage() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  Clear();
  if (memory_ != nullptr) {
    ::DeleteDC(memory_);
    memory_ = nullptr;
  }
}

void Stage::DisplaysChanged() {
  if (channel_) {
    channel_->InvokeMethod("displays", nullptr);
  }
}

void Stage::HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                       std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* arguments = call.arguments();
  const auto* map = arguments == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(arguments);

  if (method == "sprites" && map != nullptr) {
    // {ids, widths, heights: Int32List, pixels: [Uint8List …]}: several pictures in one call.
    const auto ids = Ints(Field(*map, "ids"));
    const auto widths = Ints(Field(*map, "widths"));
    const auto heights = Ints(Field(*map, "heights"));
    const auto* pixels = Field(*map, "pixels");
    const auto* list = pixels == nullptr ? nullptr : std::get_if<flutter::EncodableList>(pixels);
    int defined = 0;
    if (list != nullptr && ids.size() == widths.size() && ids.size() == heights.size() && ids.size() == list->size()) {
      for (size_t i = 0; i < ids.size(); ++i) {
        const auto* bytes = std::get_if<std::vector<uint8_t>>(&(*list)[i]);
        if (bytes != nullptr && DefineSprite(ids[i], widths[i], heights[i], *bytes)) {
          ++defined;
        }
      }
    }
    result->Success(flutter::EncodableValue(static_cast<int32_t>(defined)));
    return;
  }
  if (method == "drop") {
    for (const int id : Ints(arguments)) {
      DropSprite(id);
    }
    result->Success();
    return;
  }
  if (method == "show") {
    Show(Ints(arguments));
    result->Success();
    return;
  }
  if (method == "hide") {
    for (const int id : Ints(arguments)) {
      Hide(id);
    }
    result->Success();
    return;
  }
  if (method == "remove") {
    for (const int id : Ints(arguments)) {
      Remove(id);
    }
    result->Success();
    return;
  }
  if (method == "raise") {
    for (const int id : Ints(arguments)) {
      Raise(id);
    }
    result->Success();
    return;
  }
  if (method == "below") {
    // [actor, hwnd]: the actor goes just below that window (Peekaboo).
    const auto* list = arguments == nullptr ? nullptr : std::get_if<flutter::EncodableList>(arguments);
    int64_t actor = 0;
    int64_t handle = 0;
    if (list != nullptr && list->size() == 2 && Int64Of((*list)[0], &actor) && Int64Of((*list)[1], &handle)) {
      Below(static_cast<int>(actor), reinterpret_cast<HWND>(static_cast<intptr_t>(handle)));
    }
    result->Success();
    return;
  }
  if (method == "clear") {
    Clear();
    result->Success();
    return;
  }
  if (method == "info") {
    int shown = 0;
    for (const auto& entry : actors_) {
      if (entry.second.visible) {
        ++shown;
      }
    }
    flutter::EncodableMap info;
    info[flutter::EncodableValue("sprites")] = flutter::EncodableValue(static_cast<int32_t>(sprites_.size()));
    info[flutter::EncodableValue("spriteBytes")] = flutter::EncodableValue(static_cast<int64_t>(sprite_bytes_));
    info[flutter::EncodableValue("actors")] = flutter::EncodableValue(static_cast<int32_t>(actors_.size()));
    info[flutter::EncodableValue("shown")] = flutter::EncodableValue(static_cast<int32_t>(shown));
    info[flutter::EncodableValue("frames")] = flutter::EncodableValue(static_cast<int64_t>(frames_));
    info[flutter::EncodableValue("moves")] = flutter::EncodableValue(static_cast<int64_t>(moves_));
    result->Success(flutter::EncodableValue(info));
    return;
  }
  result->NotImplemented();
}

bool Stage::DefineSprite(int id, int width, int height, const std::vector<uint8_t>& rgba) {
  if (id <= 0 || width <= 0 || height <= 0 || width > kMaxSide || height > kMaxSide ||
      rgba.size() != static_cast<size_t>(width) * static_cast<size_t>(height) * 4) {
    return false;
  }
  DropSprite(id);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // top-down, as Dart's rows are
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap = ::CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    if (bitmap != nullptr) {
      ::DeleteObject(bitmap);
    }
    return false;
  }
  // Dart's premultiplied RGBA to the premultiplied BGRA UpdateLayeredWindow wants.
  auto* out = static_cast<uint8_t*>(bits);
  const uint8_t* in = rgba.data();
  const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
  for (size_t i = 0; i < pixels; ++i, in += 4, out += 4) {
    out[0] = in[2];
    out[1] = in[1];
    out[2] = in[0];
    out[3] = in[3];
  }
  ::GdiFlush();
  sprites_[id] = Sprite{bitmap, width, height};
  sprite_bytes_ += static_cast<int64_t>(pixels) * 4;
  return true;
}

void Stage::DropSprite(int id) {
  const auto found = sprites_.find(id);
  if (found == sprites_.end()) {
    return;
  }
  sprite_bytes_ -= static_cast<int64_t>(found->second.width) * found->second.height * 4;
  ::DeleteObject(found->second.bitmap);
  sprites_.erase(found);
  // An actor showing it keeps showing it (Windows has its own copy); a later move needs no pixels.
}

void Stage::Show(const std::vector<int32_t>& shots) {
  // Six numbers an actor: id, sprite, x, y (its top-left, physical pixels), alpha (0–255), flags.
  for (size_t i = 0; i + 5 < shots.size(); i += 6) {
    ShowOne(shots[i], shots[i + 1], shots[i + 2], shots[i + 3], shots[i + 4], shots[i + 5]);
  }
}

Stage::Actor* Stage::Create(int id, int flags) {
  if (!RegisterActorClass(&Stage::WndProc)) {
    return nullptr;
  }
  DWORD style = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  if (flags & kClickThrough) {
    style |= WS_EX_TRANSPARENT;
  }
  if (flags & kTopmost) {
    style |= WS_EX_TOPMOST;
  }
  HWND window = ::CreateWindowExW(style, kWindowClass, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
                                  ::GetModuleHandleW(nullptr), this);
  if (window == nullptr) {
    return nullptr;
  }
  windows_[window] = id;
  Actor& actor = actors_[id];
  actor = Actor{};
  actor.window = window;
  actor.flags = flags;
  return &actor;
}

void Stage::ShowOne(int id, int sprite, int x, int y, int alpha, int flags) {
  if (id <= 0) {
    return;
  }
  alpha = alpha < 0 ? 0 : (alpha > 255 ? 255 : alpha);
  Actor* actor = nullptr;
  const auto found = actors_.find(id);
  if (found == actors_.end()) {
    actor = Create(id, flags);
    if (actor == nullptr) {
      return;
    }
  } else {
    actor = &found->second;
  }
  HWND window = actor->window;

  if (flags != actor->flags) {
    const LONG_PTR before = ::GetWindowLongPtrW(window, GWL_EXSTYLE);
    LONG_PTR style = before;
    style = (flags & kClickThrough) ? (style | WS_EX_TRANSPARENT) : (style & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT));
    if (style != before) {
      ::SetWindowLongPtrW(window, GWL_EXSTYLE, style);
    }
    if ((flags & kTopmost) != (actor->flags & kTopmost) && actor->flags >= 0) {
      ::SetWindowPos(window, (flags & kTopmost) ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }
    actor->flags = flags;
  }

  POINT position{x, y};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, static_cast<BYTE>(alpha), AC_SRC_ALPHA};
  const auto picture = sprite > 0 ? sprites_.find(sprite) : sprites_.end();
  const bool new_picture = picture != sprites_.end() && (sprite != actor->sprite || !actor->visible);
  if (new_picture) {
    // A new picture: its pixels go to Windows (only this sprite's).
    SIZE size{picture->second.width, picture->second.height};
    POINT origin{0, 0};
    HGDIOBJ previous = ::SelectObject(memory_, picture->second.bitmap);
    const BOOL drawn =
        ::UpdateLayeredWindow(window, nullptr, &position, &size, memory_, &origin, 0, &blend, ULW_ALPHA);
    ::SelectObject(memory_, previous);
    if (!drawn) {
      return;
    }
    actor->sprite = sprite;
    actor->width = size.cx;
    actor->height = size.cy;
    ++frames_;
  } else if (actor->sprite > 0 && (x != actor->x || y != actor->y || alpha != actor->alpha)) {
    // The same picture somewhere else, or fading: no pixels move.
    if (!::UpdateLayeredWindow(window, nullptr, &position, nullptr, nullptr, nullptr, 0, &blend, ULW_ALPHA)) {
      return;
    }
    ++moves_;
  } else if (actor->sprite <= 0) {
    // Nothing to show yet (its picture isn't here).
    return;
  }
  actor->x = x;
  actor->y = y;
  actor->alpha = alpha;
  if (!actor->visible) {
    ::ShowWindow(window, SW_SHOWNOACTIVATE);
    actor->visible = true;
  }
}

void Stage::Hide(int id) {
  const auto found = actors_.find(id);
  if (found == actors_.end() || !found->second.visible) {
    return;
  }
  ::ShowWindow(found->second.window, SW_HIDE);
  found->second.visible = false;
}

void Stage::Remove(int id) {
  const auto found = actors_.find(id);
  if (found == actors_.end()) {
    return;
  }
  HWND window = found->second.window;
  windows_.erase(window);
  actors_.erase(found);
  ::DestroyWindow(window);
}

void Stage::Raise(int id) {
  const auto found = actors_.find(id);
  if (found == actors_.end()) {
    return;
  }
  ::SetWindowPos(found->second.window, (found->second.flags & kTopmost) ? HWND_TOPMOST : HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void Stage::Below(int id, HWND above) {
  const auto found = actors_.find(id);
  if (found == actors_.end() || above == nullptr) {
    return;
  }
  ::SetWindowPos(found->second.window, above, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void Stage::Clear() {
  std::vector<HWND> windows;
  for (const auto& entry : actors_) {
    windows.push_back(entry.second.window);
  }
  actors_.clear();
  windows_.clear();
  for (HWND window : windows) {
    ::DestroyWindow(window);
  }
  for (auto& entry : sprites_) {
    ::DeleteObject(entry.second.bitmap);
  }
  sprites_.clear();
  sprite_bytes_ = 0;
}

void Stage::SendPointer(HWND window, int kind, LPARAM lparam) {
  const auto found = windows_.find(window);
  if (found == windows_.end() || !channel_) {
    return;
  }
  POINT local{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  POINT screen = local;
  if (kind == kLeave || kind == kCancel) {
    ::GetCursorPos(&screen);
    local = screen;
    ::ScreenToClient(window, &local);
  } else {
    ::ClientToScreen(window, &screen);
  }
  std::vector<int32_t> event{found->second, kind, local.x, local.y, screen.x, screen.y};
  channel_->InvokeMethod("pointer", std::make_unique<flutter::EncodableValue>(std::move(event)));
}

LRESULT CALLBACK Stage::WndProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* stage = reinterpret_cast<Stage*>(::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (stage != nullptr) {
    return stage->Handle(window, message, wparam, lparam);
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

LRESULT Stage::Handle(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  const auto found = windows_.find(window);
  Actor* actor = nullptr;
  if (found != windows_.end()) {
    const auto entry = actors_.find(found->second);
    actor = entry == actors_.end() ? nullptr : &entry->second;
  }
  switch (message) {
    case WM_MOUSEACTIVATE:
      // A click never takes the focus from what you're typing in.
      return MA_NOACTIVATE;
    case WM_SETCURSOR:
      if (LOWORD(lparam) == HTCLIENT && actor != nullptr && (actor->flags & kHandCursor)) {
        ::SetCursor(::LoadCursorW(nullptr, IDC_HAND));
        return TRUE;
      }
      break;
    case WM_DPICHANGED:
      // Dart draws each picture for the display it's on and places it in physical pixels: no resizing here.
      return 0;
    case WM_MOUSEMOVE:
      if (actor != nullptr && !actor->tracking) {
        TRACKMOUSEEVENT track{sizeof(TRACKMOUSEEVENT), TME_LEAVE, window, 0};
        actor->tracking = ::TrackMouseEvent(&track) != FALSE;
        SendPointer(window, kEnter, lparam);
      }
      SendPointer(window, kMove, lparam);
      return 0;
    case WM_MOUSELEAVE:
      if (actor != nullptr) {
        actor->tracking = false;
      }
      SendPointer(window, kLeave, lparam);
      return 0;
    case WM_LBUTTONDOWN:
      if (actor != nullptr) {
        actor->pressed = true;
      }
      ::SetCapture(window);
      SendPointer(window, kDown, lparam);
      return 0;
    case WM_LBUTTONUP:
      if (actor != nullptr && actor->pressed) {
        actor->pressed = false;
        SendPointer(window, kUp, lparam);
      }
      if (::GetCapture() == window) {
        ::ReleaseCapture();
      }
      return 0;
    case WM_CAPTURECHANGED:
      if (actor != nullptr && actor->pressed) {
        actor->pressed = false;
        SendPointer(window, kCancel, lparam);
      }
      return 0;
    case WM_RBUTTONDOWN:
      SendPointer(window, kRightDown, lparam);
      return 0;
    case WM_RBUTTONUP:
      SendPointer(window, kRightUp, lparam);
      return 0;
    case WM_NCDESTROY:
      ::SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      break;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace mochi_stage
