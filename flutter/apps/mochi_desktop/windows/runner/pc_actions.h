#ifndef RUNNER_PC_ACTIONS_H_
#define RUNNER_PC_ACTIONS_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// What Ask Mochi may do on this PC for the user (docs/SPRINT_2.md W9, docs/W9_SAFETY_REVIEW.md): list and open the apps in
// the Start menu, change the default speaker's volume, and list and start the Task Scheduler tasks in the user's own
// \Mochi\ folder. Music keys are in media.cpp.
//
// What it reads: the display names and parsing names of the entries in the shell's Apps folder (FOLDERID_AppsFolder: the
// Start menu's apps), the default output's volume and mute state, and the names of the tasks in \Mochi\.
// What it never reads: file contents, window titles, which app is running or playing, a task's actions or triggers, or any
// other task folder. It never creates, changes or deletes a task, never passes parameters to an app, and never uses the
// "runas" verb.
//
// Every COM call happens on one worker thread of its own, so the UI thread never waits on the shell, the audio service or
// the Task Scheduler. The UI thread asks with Request (which returns at once); when the worker has the answer it posts
// |message| to |notify| with the request's number in WPARAM, and the UI thread collects it with Take.
namespace mochi_pc {

enum class Kind { ListApps, LaunchApp, VolumeGet, VolumeSet, MuteSet, ListTasks, RunTask };

// How a request ended. NoFolder: there is no \Mochi\ folder. NotFound: no such task, or an id that was not in the list.
enum class Status { Ok, NotFound, NoFolder, Failed };

struct App {
  std::string name;  // the display name (UTF-8)
  std::string id;    // the parsing name relative to the Apps folder (UTF-8): the only thing LaunchApp accepts
};

struct Job {
  Kind kind = Kind::ListApps;
  std::string text;    // LaunchApp: the app's id; RunTask: the task's name (UTF-8)
  double level = 0;    // VolumeSet: 0 to 1
  bool muted = false;  // MuteSet
};

struct Answer {
  uint32_t token = 0;  // the request this answers
  Kind kind = Kind::ListApps;
  Status status = Status::Failed;
  std::vector<App> apps;           // ListApps
  std::vector<std::string> tasks;  // ListTasks
  double level = 0;                // VolumeGet: 0 to 1
  bool muted = false;              // VolumeGet
};

// Asks the worker to do |job|. Returns the request's number, or 0 when the worker could not be started or has stopped.
// Only locks briefly; never blocks on COM, never throws.
uint32_t Request(HWND notify, UINT message, const Job& job);

// The finished answer for request |token|, once (UI thread, on the |message| post). False when there is none.
bool Take(uint32_t token, Answer* answer);

// Ends the worker (call before the process ends); nothing is answered from then on.
void Stop();

}  // namespace mochi_pc

#endif  // RUNNER_PC_ACTIONS_H_
