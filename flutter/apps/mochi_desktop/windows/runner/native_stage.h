#ifndef RUNNER_NATIVE_STAGE_H_
#define RUNNER_NATIVE_STAGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

// Mochi's native stage (docs/SPRINT_2.md N1): any number of small borderless windows anywhere on any monitor, each
// showing one picture that Dart drew, so Mochi, its notes and its celebrations can be out on the desktop while the
// Flutter window stays the app (also several at once: W26).
//
// Dart keeps all the logic and the art (lib/src/platform/native_stage.dart, lib/src/ui/stage/). It draws each picture
// once, premultiplied RGBA at the display's scale, and hands it over as a numbered sprite (`sprites`); after that a
// frame is only "actor N shows sprite S at x, y" (`show`), physical pixels in the virtual screen. Here each actor is a
// layered window (WS_EX_LAYERED, updated with UpdateLayeredWindow from the sprite's own DIB): Windows composites it,
// and hit-tests it per pixel, so clicks on its transparent pixels go to whatever is under it and only the character
// itself takes them. An actor can also let every click through (WS_EX_TRANSPARENT), for confetti. Actors never take
// the focus (WS_EX_NOACTIVATE, MA_NOACTIVATE), stay out of the taskbar and Alt+Tab (WS_EX_TOOLWINDOW) and are topmost
// only when asked.
//
// A move with the same picture is a move (no pixels are copied); a new picture copies only that small sprite. There
// are no timers here: nothing happens unless Dart sends a frame, and Dart sends none while the screen can't be seen.
//
// Pointer events on an actor go back to Dart on the same channel (`pointer`: actor, kind, x and y in the actor,
// x and y on the screen): a press captures the mouse until it's released, so a drag keeps reporting.
namespace mochi_stage {

class Stage {
 public:
  explicit Stage(flutter::BinaryMessenger* messenger);
  ~Stage();

  Stage(const Stage&) = delete;
  Stage& operator=(const Stage&) = delete;

  // A display came or went, or the work area changed: Dart looks at the displays again.
  void DisplaysChanged();

  // An actor's flags (`show`).
  static constexpr int kClickThrough = 1;
  static constexpr int kTopmost = 2;
  static constexpr int kHandCursor = 4;

  // Pointer event kinds (`pointer`).
  static constexpr int kDown = 1;
  static constexpr int kMove = 2;
  static constexpr int kUp = 3;
  static constexpr int kEnter = 4;
  static constexpr int kLeave = 5;
  static constexpr int kRightDown = 6;
  static constexpr int kRightUp = 7;
  static constexpr int kCancel = 9;

 private:
  struct Sprite {
    HBITMAP bitmap = nullptr;
    int width = 0;
    int height = 0;
  };

  struct Actor {
    HWND window = nullptr;
    int sprite = 0;
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    int alpha = -1;
    int flags = -1;
    bool visible = false;
    bool tracking = false;
    bool pressed = false;
  };

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) noexcept;
  LRESULT Handle(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool DefineSprite(int id, int width, int height, const std::vector<uint8_t>& rgba);
  void DropSprite(int id);
  void Show(const std::vector<int32_t>& shots);
  void ShowOne(int id, int sprite, int x, int y, int alpha, int flags);
  void Hide(int id);
  void Remove(int id);
  void Raise(int id);
  void Clear();
  Actor* Create(int id, int flags);
  void SendPointer(HWND window, int kind, LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unordered_map<int, Sprite> sprites_;
  std::unordered_map<int, Actor> actors_;
  std::unordered_map<HWND, int> windows_;
  HDC memory_ = nullptr;
  int64_t sprite_bytes_ = 0;
  int64_t frames_ = 0;
  int64_t moves_ = 0;
};

}  // namespace mochi_stage

#endif  // RUNNER_NATIVE_STAGE_H_
