#ifndef RUNNER_JUMP_LIST_H_
#define RUNNER_JUMP_LIST_H_

#include <windows.h>

// The Start menu's jump list for Mochi (docs/SPRINT_2.md X16): two tasks, "Ask Mochi" and "Explore", that start this exe
// with `--ask` or `--explore` (a second launch hands the argument to the running copy: main.cpp, flutter_window.cpp).
namespace mochi_jumplist {

// Builds the list through ICustomDestinationList for Mochi's AppUserModelID. Call it once, on the UI thread (COM is
// initialised there), and only for the installed copy (Dart decides). Every call is checked and nothing is thrown;
// returns S_OK, or the first HRESULT that failed (the list is then left as it was).
HRESULT Build();

}  // namespace mochi_jumplist

#endif  // RUNNER_JUMP_LIST_H_
