#include "media.h"

#include <windows.h>
#include <unknwn.h>

#include <condition_variable>
#include <mutex>
#include <thread>

// The WinRT headers are the Windows SDK's; their own warnings are not ours (the runner builds with /W4 /WX).
#pragma warning(push, 0)
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#pragma warning(pop)

namespace mochi_media {
namespace {

using winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager;
using winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus;

// What the worker and the UI thread share. Allocated once and never freed, so a worker still busy when the app quits
// never touches something static destruction already took down.
struct State {
  std::mutex lock;
  std::condition_variable wake;
  bool started = false;
  bool requested = false;
  bool stopping = false;
  bool playing = false;
};

State& Shared() {
  static State* state = new State();
  return *state;
}

// The worker: one thread with its own multi-threaded apartment, where the session manager is requested, kept and asked,
// so no WinRT call (some of them go to the media service in another process) is ever made on the UI thread and the
// manager is only used in the apartment it was made in. Woken by IsPlaying, it reads once and goes back to sleep. A
// failure drops the manager and waits longer before asking Windows for it again (10 s, 20 s, … up to 160 s), so a PC
// without the service costs nothing.
void Work() {
  State& state = Shared();
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
  } catch (...) {
  }
  GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
  ULONGLONG retry_at = 0;
  int failures = 0;
  for (;;) {
    {
      std::unique_lock<std::mutex> lock(state.lock);
      state.wake.wait(lock, [&state] { return state.requested || state.stopping; });
      if (state.stopping) {
        break;
      }
      state.requested = false;
    }
    bool playing = false;
    try {
      if (!manager && GetTickCount64() >= retry_at) {
        manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
      }
      if (manager) {
        const auto session = manager.GetCurrentSession();
        playing = session && session.GetPlaybackInfo().PlaybackStatus() ==
                                 GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing;
      }
      failures = 0;
    } catch (...) {
      manager = nullptr;
      if (failures < 5) {
        failures++;
      }
      retry_at = GetTickCount64() + (5000ULL << failures);
    }
    std::lock_guard<std::mutex> lock(state.lock);
    state.playing = playing;
  }
  manager = nullptr;
}

}  // namespace

bool IsPlaying() {
  State& state = Shared();
  std::lock_guard<std::mutex> lock(state.lock);
  if (state.stopping) {
    return false;
  }
  if (!state.started) {
    try {
      std::thread(Work).detach();
      state.started = true;
    } catch (...) {
      return false;
    }
  }
  state.requested = true;
  state.wake.notify_one();
  return state.playing;
}

void Stop() {
  State& state = Shared();
  {
    std::lock_guard<std::mutex> lock(state.lock);
    state.stopping = true;
  }
  state.wake.notify_one();
}

}  // namespace mochi_media
