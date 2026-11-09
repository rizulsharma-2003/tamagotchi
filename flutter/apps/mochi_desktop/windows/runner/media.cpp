// Reads only whether the current media session is playing (X7), and presses the three music keys for Ask Mochi (W9).
// Never reads a title, an artist or which app plays, and never sends any key but VK_MEDIA_PLAY_PAUSE,
// VK_MEDIA_NEXT_TRACK and VK_MEDIA_PREV_TRACK (and those only when there is no media session to ask).
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
  // A music key to press (W9): -1 none, otherwise a Key.
  int pending_key = -1;
};

State& Shared() {
  static State* state = new State();
  return *state;
}

// Presses a music key as an ordinary media key: SendInput with exactly one of the three media virtual keys, down and up,
// and never any other key. Only used when there is no media session to ask.
void SendMediaKey(Key key) {
  WORD code = VK_MEDIA_PLAY_PAUSE;
  if (key == Key::Next) {
    code = VK_MEDIA_NEXT_TRACK;
  } else if (key == Key::Previous) {
    code = VK_MEDIA_PREV_TRACK;
  }
  INPUT inputs[2] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = code;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = code;
  inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
  ::SendInput(2, inputs, sizeof(INPUT));
}

// Asks the current media session to do |key| (W9). Returns false when there is no manager or no current session, so the
// caller may press the key instead; true when a session was asked (whatever it answers). Never reads a title or an artist.
bool AskSession(GlobalSystemMediaTransportControlsSessionManager& manager, Key key) {
  if (!manager) {
    return false;
  }
  const auto session = manager.GetCurrentSession();
  if (!session) {
    return false;
  }
  if (key == Key::PlayPause) {
    session.TryTogglePlayPauseAsync().get();
  } else if (key == Key::Next) {
    session.TrySkipNextAsync().get();
  } else {
    session.TrySkipPreviousAsync().get();
  }
  return true;
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
    int key = -1;
    bool wants_read = false;
    {
      std::unique_lock<std::mutex> lock(state.lock);
      state.wake.wait(lock, [&state] { return state.requested || state.pending_key >= 0 || state.stopping; });
      if (state.stopping) {
        break;
      }
      key = state.pending_key;
      state.pending_key = -1;
      wants_read = state.requested;
      state.requested = false;
    }
    if (key >= 0) {
      const Key pressed = static_cast<Key>(key);
      bool asked = false;
      try {
        if (!manager) {
          manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
        }
        asked = AskSession(manager, pressed);
      } catch (...) {
        manager = nullptr;
      }
      if (!asked) {
        // No session to ask (or no media service): the plain media key.
        SendMediaKey(pressed);
      }
    }
    if (!wants_read) {
      continue;
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

// Starts the worker if it is not running yet (the caller holds the lock). False when it could not be started.
bool StartLocked(State& state) {
  if (state.started) {
    return true;
  }
  try {
    std::thread(Work).detach();
    state.started = true;
    return true;
  } catch (...) {
    return false;
  }
}

}  // namespace

bool IsPlaying() {
  State& state = Shared();
  std::lock_guard<std::mutex> lock(state.lock);
  if (state.stopping || !StartLocked(state)) {
    return false;
  }
  state.requested = true;
  state.wake.notify_one();
  return state.playing;
}

bool Press(Key key) {
  try {
    State& state = Shared();
    std::lock_guard<std::mutex> lock(state.lock);
    if (state.stopping || !StartLocked(state)) {
      return false;
    }
    state.pending_key = static_cast<int>(key);
    state.wake.notify_one();
    return true;
  } catch (...) {
    return false;
  }
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
