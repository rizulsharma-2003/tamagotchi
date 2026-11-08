#ifndef RUNNER_DESKTOP_ICONS_H_
#define RUNNER_DESKTOP_ICONS_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// Desktop icon play (docs/SPRINT_2.md X5, Mischief): where the desktop's icons are, and moving one. The shell is asked
// through its own COM view of the desktop (IFolderView2), never by messages or memory read from Explorer's process. Names,
// paths and contents are never read: an icon is an opaque id (a hash of its item id) and its position.
//
// Every shell call happens on one worker thread of its own (its own multi-threaded COM apartment), so the UI thread never
// waits on Explorer. The UI thread asks with RequestRead / RequestMove (which return at once); when the worker has the
// answer it posts |message| to |notify| and the UI thread collects it with Take, and completes the method channel's result
// there.
namespace mochi_icons {

struct Icon {
  std::string id;  // 16 hex characters: FNV-1a 64 of the item's relative PIDL bytes
  int x = 0;       // the icon cell's top-left, screen physical pixels
  int y = 0;
};

enum class Kind { Read, Move };

struct Answer {
  uint32_t seq = 0;  // the request this answers
  Kind kind = Kind::Read;
  bool ok = false;   // Read: the desktop could be read; Move: the shell took the move
  bool auto_arrange = false;
  bool grid = false;
  bool hidden = false;
  int spacing_x = 0;  // one cell's width and height in pixels
  int spacing_y = 0;
  int icon_size = 0;
  bool more = false;  // icons this answer does not list (more than 64, or one whose place is not known)
  std::vector<Icon> icons;
  int failed_step = 0;  // when !ok: which shell call failed (desktop_icons.cpp's Step), and its HRESULT (0: none)
  long failed_hr = 0;
};

// Asks the worker to read the desktop (Read), or to move icon |id| (from the latest Read) to the screen pixel (|x|, |y|)
// (Move). A newer request replaces one that has not started yet. Returns the request's number, or 0 when the worker could not
// be started. Only locks briefly; never blocks on the shell.
uint32_t RequestRead(HWND notify, UINT message);
uint32_t RequestMove(HWND notify, UINT message, const std::string& id, int x, int y);

// The finished answer, if there is one (UI thread, on the |message| post). False when there is none.
bool Take(Answer* answer);

// Ends the worker (call before the process ends); nothing is answered from then on.
void Stop();

}  // namespace mochi_icons

#endif  // RUNNER_DESKTOP_ICONS_H_
