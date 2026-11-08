#ifndef RUNNER_MEDIA_H_
#define RUNNER_MEDIA_H_

// Whether media is playing (docs/SPRINT_2.md X7, "Reacts to what you do"): WinRT's
// GlobalSystemMediaTransportControlsSessionManager, and only whether the current session's playback status is Playing.
// Never a title, an artist or which app. C++/WinRT (the Windows SDK's winrt/ headers; no extra package).
namespace mochi_media {

// Whether the system's current media session was playing at the last read, and asks for a fresh read: every WinRT call
// happens on a worker thread of its own, so the answer is one call behind (false on the first call, and on any failure).
// Only takes a lock on the calling (UI) thread; never blocks on WinRT, never throws.
bool IsPlaying();

// Ends the worker (call before the process ends); IsPlaying is false from then on.
void Stop();

}  // namespace mochi_media

#endif  // RUNNER_MEDIA_H_
