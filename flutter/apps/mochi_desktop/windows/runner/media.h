#ifndef RUNNER_MEDIA_H_
#define RUNNER_MEDIA_H_

// Whether media is playing (docs/SPRINT_2.md X7, "Reacts to what you do"): WinRT's
// GlobalSystemMediaTransportControlsSessionManager, and only whether the current session's playback status is Playing.
// Never a title, an artist or which app. C++/WinRT (the Windows SDK's winrt/ headers; no extra package).
namespace mochi_media {

// True while the system's current media session is playing. The session manager is requested once, on a background
// thread, and cached: until it has arrived (the first call or two) and on any failure this is false. Never blocks the
// calling (UI) thread beyond the in-process calls on the cached manager, and never throws.
bool IsPlaying();

// Lets go of the cached manager (call before the process ends).
void Stop();

}  // namespace mochi_media

#endif  // RUNNER_MEDIA_H_
