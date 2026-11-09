#include "pc_actions.h"

#include <windows.h>

#include <endpointvolume.h>
#include <knownfolders.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <oleauto.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <taskschd.h>
#include <wrl/client.h>

#include <algorithm>
#include <condition_variable>
#include <cwctype>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

#include "utils.h"

namespace mochi_pc {
namespace {

using Microsoft::WRL::ComPtr;

// The most requests waiting, the most apps and tasks one answer lists, and how long the app list is kept (as the Mac does).
constexpr size_t kMostQueued = 16;
constexpr size_t kMostApps = 2000;
constexpr size_t kMostTasks = 200;
constexpr ULONGLONG kAppsKeptMs = 60ULL * 1000ULL;

struct Queued {
  uint32_t token = 0;
  Job job;
  HWND notify = nullptr;
  UINT message = 0;
};

// What the worker and the UI thread share. Allocated once and never freed, so a worker still busy when the app quits never
// touches something static destruction already took down.
struct State {
  std::mutex lock;
  std::condition_variable wake;
  bool started = false;
  bool stopping = false;
  uint32_t next_token = 0;
  std::deque<Queued> queue;
  std::map<uint32_t, Answer> answers;
  // The apps the last listing found: the only ids LaunchApp accepts.
  std::vector<App> apps;
  bool apps_known = false;
  ULONGLONG apps_at = 0;
};

State& Shared() {
  static State* state = new State();
  return *state;
}

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), wide.data(), length) <= 0) {
    return std::wstring();
  }
  return wide;
}

std::wstring Lower(const std::wstring& text) {
  std::wstring lowered = text;
  for (wchar_t& c : lowered) {
    c = static_cast<wchar_t>(std::towlower(static_cast<wint_t>(c)));
  }
  return lowered;
}

bool EndsWith(const std::wstring& text, const std::wstring& suffix) {
  return text.size() >= suffix.size() && text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Entries that are not apps to open: uninstallers, installers and repair tools by name; scripts, installers and web
// shortcuts by target.
bool Excluded(const std::wstring& name, const std::wstring& parsing) {
  static const wchar_t* const kWords[] = {L"uninstall", L"setup", L"installer", L"repair", L"reset", L"remove"};
  static const wchar_t* const kEnds[] = {L".bat", L".cmd", L".ps1", L".vbs", L".vbe", L".js",  L".jse", L".wsf", L".wsh",
                                         L".hta", L".msi", L".reg", L".scr", L".pif", L".url"};
  const std::wstring lowered_name = Lower(name);
  for (const wchar_t* word : kWords) {
    if (lowered_name.find(word) != std::wstring::npos) {
      return true;
    }
  }
  const std::wstring lowered_parsing = Lower(parsing);
  // A web shortcut in the Start menu would open a link without the https-only rule of open_url.
  if (lowered_parsing.find(L"://") != std::wstring::npos) {
    return true;
  }
  for (const wchar_t* end : kEnds) {
    if (EndsWith(lowered_parsing, end)) {
      return true;
    }
  }
  return false;
}

// A BSTR that is freed on every path.
class Bstr {
 public:
  explicit Bstr(const std::wstring& text) : value_(::SysAllocStringLen(text.data(), static_cast<UINT>(text.size()))) {}
  ~Bstr() { ::SysFreeString(value_); }
  Bstr(const Bstr&) = delete;
  Bstr& operator=(const Bstr&) = delete;
  BSTR get() const { return value_; }
  bool ok() const { return value_ != nullptr; }

 private:
  BSTR value_;
};

// MARK: Apps

// The entries of the shell's Apps folder (the Start menu's apps, Store and desktop alike), without the excluded ones. The
// display name and the folder-relative parsing name only.
Status ReadApps(std::vector<App>* out) {
  ComPtr<IShellItem> folder;
  HRESULT hr = ::SHGetKnownFolderItem(FOLDERID_AppsFolder, KF_FLAG_DEFAULT, nullptr, IID_PPV_ARGS(&folder));
  if (FAILED(hr) || !folder) {
    return Status::Failed;
  }
  ComPtr<IEnumShellItems> items;
  hr = folder->BindToHandler(nullptr, BHID_EnumItems, IID_PPV_ARGS(&items));
  if (FAILED(hr) || !items) {
    return Status::Failed;
  }
  for (;;) {
    ComPtr<IShellItem> item;
    ULONG fetched = 0;
    hr = items->Next(1, &item, &fetched);
    if (hr != S_OK || fetched != 1 || !item) {
      break;
    }
    PWSTR name = nullptr;
    PWSTR parsing = nullptr;
    const HRESULT got_name = item->GetDisplayName(SIGDN_NORMALDISPLAY, &name);
    const HRESULT got_parsing = item->GetDisplayName(SIGDN_PARENTRELATIVEPARSING, &parsing);
    if (SUCCEEDED(got_name) && SUCCEEDED(got_parsing) && name != nullptr && parsing != nullptr) {
      const std::wstring display(name);
      const std::wstring id(parsing);
      if (!display.empty() && !id.empty() && !Excluded(display, id) && out->size() < kMostApps) {
        App app;
        app.name = Utf8FromUtf16(display.c_str());
        app.id = Utf8FromUtf16(id.c_str());
        if (!app.name.empty() && !app.id.empty()) {
          out->push_back(std::move(app));
        }
      }
    }
    if (name != nullptr) {
      ::CoTaskMemFree(name);
    }
    if (parsing != nullptr) {
      ::CoTaskMemFree(parsing);
    }
  }
  return Status::Ok;
}

void DoListApps(State& state, Answer* answer) {
  {
    std::lock_guard<std::mutex> lock(state.lock);
    if (state.apps_known && ::GetTickCount64() - state.apps_at < kAppsKeptMs) {
      answer->apps = state.apps;
      answer->status = Status::Ok;
      return;
    }
  }
  std::vector<App> apps;
  const Status status = ReadApps(&apps);
  if (status != Status::Ok) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(state.lock);
    state.apps = apps;
    state.apps_known = true;
    state.apps_at = ::GetTickCount64();
  }
  answer->apps = std::move(apps);
  answer->status = Status::Ok;
}

// Starts the app whose id is in the list the last ListApps found, and nothing else: the id is checked here, so a string
// that was not in the list is never given to the shell. No verb (the default one, so an app that needs admin rights shows
// Windows' own prompt), no parameters.
void DoLaunchApp(State& state, const Job& job, Answer* answer) {
  bool listed = false;
  {
    std::lock_guard<std::mutex> lock(state.lock);
    if (state.apps_known) {
      for (const App& app : state.apps) {
        if (app.id == job.text) {
          listed = true;
          break;
        }
      }
    }
  }
  if (!listed) {
    answer->status = Status::NotFound;
    return;
  }
  const std::wstring id = Utf16FromUtf8(job.text);
  if (id.empty()) {
    answer->status = Status::NotFound;
    return;
  }
  const std::wstring target = L"shell:AppsFolder\\" + id;
  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
  info.hwnd = nullptr;
  info.lpVerb = nullptr;
  info.lpFile = target.c_str();
  info.lpParameters = nullptr;
  info.lpDirectory = nullptr;
  info.nShow = SW_SHOWNORMAL;
  answer->status = ::ShellExecuteExW(&info) ? Status::Ok : Status::Failed;
}

// MARK: Volume

// The default output's volume control (eRender, eConsole), or null.
ComPtr<IAudioEndpointVolume> OpenVolume() {
  ComPtr<IAudioEndpointVolume> volume;
  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr) || !enumerator) {
    return volume;
  }
  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr) || !device) {
    return volume;
  }
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(volume.GetAddressOf()));
  if (FAILED(hr)) {
    volume.Reset();
  }
  return volume;
}

void DoVolume(const Job& job, Answer* answer) {
  const ComPtr<IAudioEndpointVolume> volume = OpenVolume();
  if (!volume) {
    return;
  }
  if (job.kind == Kind::VolumeGet) {
    float level = 0.0f;
    BOOL muted = FALSE;
    if (FAILED(volume->GetMasterVolumeLevelScalar(&level)) || FAILED(volume->GetMute(&muted))) {
      return;
    }
    answer->level = static_cast<double>(level);
    answer->muted = muted != FALSE;
    answer->status = Status::Ok;
  } else if (job.kind == Kind::VolumeSet) {
    const double clamped = std::min(1.0, std::max(0.0, job.level));
    answer->status = SUCCEEDED(volume->SetMasterVolumeLevelScalar(static_cast<float>(clamped), nullptr)) ? Status::Ok : Status::Failed;
  } else {
    answer->status = SUCCEEDED(volume->SetMute(job.muted ? TRUE : FALSE, nullptr)) ? Status::Ok : Status::Failed;
  }
}

// MARK: Tasks

// The Task Scheduler and the user's \Mochi\ folder: the only folder ever opened.
struct MochiFolder {
  ComPtr<ITaskService> service;
  ComPtr<ITaskFolder> folder;
};

bool NotThere(HRESULT hr) {
  return hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) || hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND);
}

Status OpenMochiFolder(MochiFolder* out) {
  HRESULT hr = ::CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&out->service));
  if (FAILED(hr) || !out->service) {
    return Status::Failed;
  }
  VARIANT empty;
  VariantInit(&empty);
  hr = out->service->Connect(empty, empty, empty, empty);
  if (FAILED(hr)) {
    return Status::Failed;
  }
  const Bstr path(L"\\Mochi");
  if (!path.ok()) {
    return Status::Failed;
  }
  hr = out->service->GetFolder(path.get(), &out->folder);
  if (NotThere(hr)) {
    return Status::NoFolder;
  }
  return FAILED(hr) || !out->folder ? Status::Failed : Status::Ok;
}

void DoListTasks(Answer* answer) {
  MochiFolder mochi;
  const Status opened = OpenMochiFolder(&mochi);
  if (opened != Status::Ok) {
    answer->status = opened;
    return;
  }
  // Flags 0: the tasks that are not hidden.
  ComPtr<IRegisteredTaskCollection> tasks;
  if (FAILED(mochi.folder->GetTasks(0, &tasks)) || !tasks) {
    return;
  }
  LONG count = 0;
  if (FAILED(tasks->get_Count(&count))) {
    return;
  }
  for (LONG i = 1; i <= count && answer->tasks.size() < kMostTasks; i++) {
    VARIANT index;
    VariantInit(&index);
    index.vt = VT_I4;
    index.lVal = i;
    ComPtr<IRegisteredTask> task;
    if (FAILED(tasks->get_Item(index, &task)) || !task) {
      continue;
    }
    BSTR name = nullptr;
    if (SUCCEEDED(task->get_Name(&name)) && name != nullptr) {
      const std::string text = Utf8FromUtf16(name);
      if (!text.empty()) {
        answer->tasks.push_back(text);
      }
    }
    ::SysFreeString(name);
  }
  answer->status = Status::Ok;
}

// A task name that is only a name: no folder part, no path, nothing that walks out of \Mochi\.
bool PlainTaskName(const std::wstring& name) {
  if (name.empty() || name.size() > 256 || name == L"." || name == L"..") {
    return false;
  }
  for (const wchar_t c : name) {
    if (c == L'\\' || c == L'/' || c < 0x20) {
      return false;
    }
  }
  return true;
}

// Starts one task of \Mochi\ now (IRegisteredTask::Run, no parameters) and does not wait for it to finish.
void DoRunTask(const Job& job, Answer* answer) {
  const std::wstring name = Utf16FromUtf8(job.text);
  if (!PlainTaskName(name)) {
    answer->status = Status::NotFound;
    return;
  }
  MochiFolder mochi;
  const Status opened = OpenMochiFolder(&mochi);
  if (opened != Status::Ok) {
    answer->status = opened;
    return;
  }
  const Bstr task_name(name);
  if (!task_name.ok()) {
    return;
  }
  ComPtr<IRegisteredTask> task;
  const HRESULT found = mochi.folder->GetTask(task_name.get(), &task);
  if (NotThere(found)) {
    answer->status = Status::NotFound;
    return;
  }
  if (FAILED(found) || !task) {
    return;
  }
  VARIANT parameters;
  VariantInit(&parameters);
  ComPtr<IRunningTask> running;
  answer->status = SUCCEEDED(task->Run(parameters, &running)) ? Status::Ok : Status::Failed;
}

// MARK: The worker

// One thread with its own apartment, where every COM call is made, so none is ever made on the UI thread. (Single-threaded:
// ShellExecuteEx asks for it, and nothing here keeps an object between requests.) Woken by a request, it does the oldest,
// keeps the answer for the UI thread and posts the request's message to it.
void Work() {
  State& state = Shared();
  const HRESULT initialised = ::CoInitializeEx(nullptr, static_cast<DWORD>(COINIT_APARTMENTTHREADED) | static_cast<DWORD>(COINIT_DISABLE_OLE1DDE));
  for (;;) {
    Queued next;
    {
      std::unique_lock<std::mutex> lock(state.lock);
      state.wake.wait(lock, [&state] { return !state.queue.empty() || state.stopping; });
      if (state.stopping) {
        break;
      }
      next = std::move(state.queue.front());
      state.queue.pop_front();
    }
    Answer answer;
    answer.token = next.token;
    answer.kind = next.job.kind;
    try {
      switch (next.job.kind) {
        case Kind::ListApps:
          DoListApps(state, &answer);
          break;
        case Kind::LaunchApp:
          DoLaunchApp(state, next.job, &answer);
          break;
        case Kind::VolumeGet:
        case Kind::VolumeSet:
        case Kind::MuteSet:
          DoVolume(next.job, &answer);
          break;
        case Kind::ListTasks:
          DoListTasks(&answer);
          break;
        case Kind::RunTask:
          DoRunTask(next.job, &answer);
          break;
      }
    } catch (...) {
      answer = Answer();
      answer.token = next.token;
      answer.kind = next.job.kind;
    }
    {
      std::lock_guard<std::mutex> lock(state.lock);
      if (state.stopping) {
        break;
      }
      state.answers[next.token] = std::move(answer);
    }
    ::PostMessage(next.notify, next.message, static_cast<WPARAM>(next.token), 0);
  }
  if (SUCCEEDED(initialised)) {
    ::CoUninitialize();
  }
}

}  // namespace

uint32_t Request(HWND notify, UINT message, const Job& job) {
  try {
    State& state = Shared();
    std::lock_guard<std::mutex> lock(state.lock);
    if (state.stopping || state.queue.size() >= kMostQueued) {
      return 0;
    }
    if (!state.started) {
      std::thread(Work).detach();
      state.started = true;
    }
    state.next_token++;
    if (state.next_token == 0) {
      state.next_token = 1;
    }
    Queued queued;
    queued.token = state.next_token;
    queued.job = job;
    queued.notify = notify;
    queued.message = message;
    state.queue.push_back(std::move(queued));
    state.wake.notify_one();
    return state.next_token;
  } catch (...) {
    return 0;
  }
}

bool Take(uint32_t token, Answer* answer) {
  try {
    State& state = Shared();
    std::lock_guard<std::mutex> lock(state.lock);
    const auto found = state.answers.find(token);
    if (found == state.answers.end()) {
      return false;
    }
    *answer = std::move(found->second);
    state.answers.erase(found);
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

}  // namespace mochi_pc
