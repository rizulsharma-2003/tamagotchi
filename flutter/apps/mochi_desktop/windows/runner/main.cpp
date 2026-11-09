#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// One Mochi per signed-in user: the bridge for Claude Code's hooks, the tray
// icon and the Mochi Link connection can only have one owner.
constexpr const wchar_t kSingleInstanceMutex[] =
    L"Local\\InsideEdge.Mochi.SingleInstance";
constexpr const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kWindowTitle[] = L"Mochi";

// Mochi's AppUserModelID: the installed copy's Start-menu shortcut carries it (lib/src/update/self_install.dart), and
// Windows attributes toasts, the taskbar button and jump lists by it.
constexpr const wchar_t kAppUserModelId[] = L"InsideEdge.Mochi";

// What this launch asks of the running copy besides showing its window: the jump list's tasks start `Mochi.exe --ask`
// and `Mochi.exe --explore`. Any other argument is ignored.
WPARAM LaunchRequestFromArguments() {
  for (const std::string& argument : GetCommandLineArguments()) {
    if (argument == "--ask") {
      return kLaunchAsk;
    }
    if (argument == "--explore") {
      return kLaunchExplore;
    }
  }
  return kLaunchShow;
}

// Asks the copy that's already running to show its main window (and to open Ask Mochi, or set off exploring).
void ShowRunningCopy() {
  HWND running = ::FindWindowW(kWindowClass, kWindowTitle);
  if (running == nullptr) {
    return;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(running, &process_id);
  // Let it come to the front: this process was just started by the user, so
  // it may hand its foreground right over.
  ::AllowSetForegroundWindow(process_id);
  ::PostMessageW(running, MochiShowMainMessage(), LaunchRequestFromArguments(), 0);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ShowRunningCopy();
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Before any window: this process is Mochi, the app of the Start-menu shortcut, so its notifications and taskbar
  // button are attributed to Mochi.
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // The desktop pet's size; Dart moves and resizes it before showing it.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(176, 200);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) {
    ::ReleaseMutex(single_instance);
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
