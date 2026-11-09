#ifndef RUNNER_MEDIA_H_
#define RUNNER_MEDIA_H_

// Whether media is playing (docs/SPRINT_2.md X7, "Reacts to what you do"): WinRT's
// GlobalSystemMediaTransportControlsSessionManager, and only whether the current session's playback status is Playing.
// Never a title, an artist or which app. C++/WinRT (the Windows SDK's winrt/ headers; no extra package).
//
// Also (docs/SPRINT_2.md W9, Ask Mochi's music keys): Press asks the current session to play/pause, skip or go back
// (TryTogglePlayPauseAsync, TrySkipNextAsync, TrySkipPreviousAsync). Only when there is no session does it send the one
// matching media key with SendInput (VK_MEDIA_PLAY_PAUSE, VK_MEDIA_NEXT_TRACK or VK_MEDIA_PREV_TRACK, down and up), and
// never any other key. It never reads a title or an artist.
namespace mochi_media {

enum class Key { PlayPause, Next, Previous };

// Whether the system's current media session was playing at the last read, and asks for a fresh read: every WinRT call
// happens on a worker thread of its own, so the answer is one call behind (false on the first call, and on any failure).
// Only takes a lock on the calling (UI) thread; never blocks on WinRT, never throws.
bool IsPlaying();

// Asks the worker to press |key| (on its own thread: the UI thread never waits on WinRT). True when the request was taken;
// false when the worker could not be started or has stopped. Never throws.
bool Press(Key key);

// Ends the worker (call before the process ends); IsPlaying is false from then on.
void Stop();

}  // namespace mochi_media

#endif  // RUNNER_MEDIA_H_
