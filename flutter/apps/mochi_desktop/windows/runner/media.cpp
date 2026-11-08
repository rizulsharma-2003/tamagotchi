#include "media.h"

#include <windows.h>
#include <unknwn.h>

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

std::mutex g_lock;
GlobalSystemMediaTransportControlsSessionManager g_manager{nullptr};
bool g_loading = false;

// Runs on a thread of its own: asks Windows for the session manager and keeps it. A failure leaves nothing cached, so
// the next call to IsPlaying asks again.
void Load() {
  GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
  } catch (const winrt::hresult_error&) {
  } catch (...) {
  }
  std::lock_guard<std::mutex> lock(g_lock);
  g_manager = manager;
  g_loading = false;
}

}  // namespace

bool IsPlaying() {
  GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
  {
    std::lock_guard<std::mutex> lock(g_lock);
    manager = g_manager;
    if (!manager && !g_loading) {
      g_loading = true;
      try {
        std::thread(Load).detach();
      } catch (...) {
        g_loading = false;
      }
    }
  }
  if (!manager) {
    return false;
  }
  try {
    const auto session = manager.GetCurrentSession();
    if (!session) {
      return false;
    }
    return session.GetPlaybackInfo().PlaybackStatus() == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing;
  } catch (const winrt::hresult_error&) {
    return false;
  } catch (...) {
    return false;
  }
}

void Stop() {
  std::lock_guard<std::mutex> lock(g_lock);
  g_manager = nullptr;
}

}  // namespace mochi_media
