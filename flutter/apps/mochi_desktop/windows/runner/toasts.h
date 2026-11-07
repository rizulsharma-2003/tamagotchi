#ifndef RUNNER_TOASTS_H_
#define RUNNER_TOASTS_H_

#include <windows.h>

#include <string>

// Windows notifications (toasts) for Mochi, an unpackaged app identified by its AppUserModelID (docs/SPRINT_2.md W1):
// WinRT's ToastNotificationManager through WRL (in the Windows SDK; no ATL, no C++/WinRT), and Mochi's own COM class
// that Windows calls when a toast is clicked (INotificationActivationCallback, registered with CoRegisterClassObject;
// HKCU\Software\Classes\AppUserModelId\<id>\CustomActivator names it, and the installer registers Mochi.exe as its
// LocalServer32, so a click in the notification centre also starts Mochi). A click's argument is posted to [window] as
// [message] with a heap std::wstring* in LPARAM, so it reaches Dart on the UI thread.
namespace mochi_toasts {

// Registers the click handler (once). False if COM refused.
bool Start(HWND window, UINT message, const std::wstring& activator_clsid);

// Shows a toast made from [xml] for [app_id], tagged [tag] in group "mochi" (a newer toast with the tag replaces it).
HRESULT Show(const std::wstring& app_id, const std::wstring& xml, const std::wstring& tag);

// Windows' NotificationSetting for [app_id]: 0 enabled, 1 off for the app, 2 off for the user, 3 off by group policy,
// 4 off by the manifest; -1 when it can't be read.
int Setting(const std::wstring& app_id);

// Lets go of the click handler.
void Stop();

}  // namespace mochi_toasts

#endif  // RUNNER_TOASTS_H_
