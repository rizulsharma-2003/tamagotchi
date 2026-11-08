#include "desktop_icons.h"

#include <windows.h>

#include <exdisp.h>
#include <objbase.h>
#include <oleauto.h>
#include <servprov.h>
#include <shlguid.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <condition_variable>
#include <cstdio>
#include <map>
#include <mutex>
#include <thread>

namespace mochi_icons {
namespace {

using Microsoft::WRL::ComPtr;

constexpr size_t kMostIcons = 64;

struct Job {
  uint32_t seq = 0;
  Kind kind = Kind::Read;
  std::string id;
  int x = 0;
  int y = 0;
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
  uint32_t next_seq = 0;
  bool has_job = false;
  Job job;
  bool has_answer = false;
  Answer answer;
};

State& Shared() {
  static State* state = new State();
  return *state;
}

// FNV-1a, 64 bits, over |size| bytes.
uint64_t Fnv1a(const unsigned char* bytes, size_t size) {
  uint64_t hash = 14695981039346656037ULL;
  for (size_t i = 0; i < size; i++) {
    hash ^= bytes[i];
    hash *= 1099511628211ULL;
  }
  return hash;
}

// The id of an item: its relative PIDL's bytes (ILGetSize) hashed, as 16 hex characters. Never its name.
std::string IdOf(PCUITEMID_CHILD pidl) {
  const UINT size = ILGetSize(pidl);
  char text[17] = {0};
  sprintf_s(text, sizeof(text), "%016llx",
            static_cast<unsigned long long>(Fnv1a(reinterpret_cast<const unsigned char*>(pidl), size)));
  return std::string(text);
}

// The desktop's folder view, re-acquired for every job (Explorer can restart) and never kept: the shell windows, the desktop
// among them, its top-level browser, the active view, its IFolderView2 and the list view that holds the icons.
struct DesktopView {
  ComPtr<IFolderView2> folder;
  HWND list = nullptr;
};

bool Acquire(DesktopView* out) {
  ComPtr<IShellWindows> windows;
  if (FAILED(CoCreateInstance(CLSID_ShellWindows, nullptr, CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(&windows)))) {
    return false;
  }
  VARIANT location;
  VariantInit(&location);
  location.vt = VT_I4;
  location.lVal = CSIDL_DESKTOP;
  VARIANT empty;
  VariantInit(&empty);
  long found = 0;
  ComPtr<IDispatch> dispatch;
  if (FAILED(windows->FindWindowSW(&location, &empty, SWC_DESKTOP, &found, SWFO_NEEDDISPATCH, &dispatch)) || !dispatch) {
    return false;
  }
  ComPtr<IServiceProvider> provider;
  if (FAILED(dispatch.As(&provider))) {
    return false;
  }
  ComPtr<IShellBrowser> browser;
  if (FAILED(provider->QueryService(SID_STopLevelBrowser, IID_PPV_ARGS(&browser)))) {
    return false;
  }
  ComPtr<IShellView> view;
  if (FAILED(browser->QueryActiveShellView(&view)) || !view) {
    return false;
  }
  if (FAILED(view.As(&out->folder))) {
    return false;
  }
  HWND def_view = nullptr;
  if (FAILED(view->GetWindow(&def_view)) || def_view == nullptr) {
    return false;
  }
  out->list = ::FindWindowExW(def_view, nullptr, L"SysListView32", nullptr);
  return out->list != nullptr;
}

// The icons by id, as of the latest read: owned by the worker thread alone, each a clone freed with CoTaskMemFree when the
// map is replaced. Never names.
using Items = std::map<std::string, PITEMID_CHILD>;

void Forget(Items* items) {
  for (auto& item : *items) {
    CoTaskMemFree(item.second);
  }
  items->clear();
}

void DoRead(Items* items, Answer* answer) {
  DesktopView view;
  if (!Acquire(&view)) {
    return;
  }
  DWORD flags = 0;
  if (FAILED(view.folder->GetCurrentFolderFlags(&flags))) {
    return;
  }
  POINT spacing = {0, 0};
  if (FAILED(view.folder->GetSpacing(&spacing))) {
    return;
  }
  FOLDERVIEWMODE mode = FVM_ICON;
  int icon_size = 0;
  if (FAILED(view.folder->GetViewModeAndIconSize(&mode, &icon_size))) {
    return;
  }
  ComPtr<IEnumIDList> list;
  if (FAILED(view.folder->Items(SVGIO_ALLVIEW, IID_PPV_ARGS(&list))) || !list) {
    return;
  }
  Items fresh;
  std::vector<Icon> icons;
  bool more = false;
  for (;;) {
    PITEMID_CHILD pidl = nullptr;
    ULONG fetched = 0;
    if (list->Next(1, &pidl, &fetched) != S_OK || pidl == nullptr) {
      break;
    }
    if (icons.size() >= kMostIcons) {
      more = true;
      CoTaskMemFree(pidl);
      continue;
    }
    POINT at = {0, 0};
    if (FAILED(view.folder->GetItemPosition(pidl, &at))) {
      more = true;  // an icon whose place is not known: the answer is not the whole desktop
      CoTaskMemFree(pidl);
      continue;
    }
    PITEMID_CHILD copy = ILClone(pidl);
    const std::string id = IdOf(pidl);
    CoTaskMemFree(pidl);
    if (copy == nullptr) {
      more = true;
      continue;
    }
    if (fresh.count(id) != 0) {
      more = true;  // two icons with one id: they could not be told apart
      CoTaskMemFree(copy);
      continue;
    }
    ::MapWindowPoints(view.list, HWND_DESKTOP, &at, 1);
    fresh[id] = copy;
    Icon icon;
    icon.id = id;
    icon.x = static_cast<int>(at.x);
    icon.y = static_cast<int>(at.y);
    icons.push_back(icon);
  }
  Forget(items);
  *items = std::move(fresh);
  answer->ok = true;
  answer->auto_arrange = (flags & FWF_AUTOARRANGE) != 0;
  answer->grid = (flags & FWF_SNAPTOGRID) != 0;
  answer->hidden = (flags & FWF_NOICONS) != 0;
  answer->spacing_x = static_cast<int>(spacing.x);
  answer->spacing_y = static_cast<int>(spacing.y);
  answer->icon_size = icon_size;
  answer->more = more;
  answer->icons = std::move(icons);
}

void DoMove(const Items& items, const Job& job, Answer* answer) {
  const auto found = items.find(job.id);
  if (found == items.end()) {
    return;
  }
  DesktopView view;
  if (!Acquire(&view)) {
    return;
  }
  POINT at = {static_cast<LONG>(job.x), static_cast<LONG>(job.y)};
  ::MapWindowPoints(HWND_DESKTOP, view.list, &at, 1);
  PCUITEMID_CHILD pidl = found->second;
  // Only SVSI_POSITIONITEM: the icon is never selected, focused or put into editing.
  const HRESULT moved = view.folder->SelectAndPositionItems(1, &pidl, &at, SVSI_POSITIONITEM);
  answer->ok = SUCCEEDED(moved);
}

// The worker: one thread with its own multi-threaded apartment, where every shell call is made, so none is ever made on the
// UI thread. Woken by a request, it does the latest one, keeps the answer for the UI thread and posts |message| to it.
void Work() {
  State& state = Shared();
  const HRESULT initialised = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  Items items;
  for (;;) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(state.lock);
      state.wake.wait(lock, [&state] { return state.has_job || state.stopping; });
      if (state.stopping) {
        break;
      }
      job = state.job;
      state.has_job = false;
    }
    Answer answer;
    answer.seq = job.seq;
    answer.kind = job.kind;
    try {
      if (job.kind == Kind::Read) {
        DoRead(&items, &answer);
      } else {
        DoMove(items, job, &answer);
      }
    } catch (...) {
      answer = Answer();
      answer.seq = job.seq;
      answer.kind = job.kind;
    }
    {
      std::lock_guard<std::mutex> lock(state.lock);
      if (state.stopping) {
        break;
      }
      state.answer = std::move(answer);
      state.has_answer = true;
    }
    ::PostMessage(job.notify, job.message, 0, 0);
  }
  try {
    Forget(&items);
  } catch (...) {
  }
  if (SUCCEEDED(initialised)) {
    CoUninitialize();
  }
}

uint32_t Submit(const Job& request) {
  State& state = Shared();
  std::lock_guard<std::mutex> lock(state.lock);
  if (state.stopping) {
    return 0;
  }
  if (!state.started) {
    try {
      std::thread(Work).detach();
      state.started = true;
    } catch (...) {
      return 0;
    }
  }
  state.next_seq++;
  if (state.next_seq == 0) {
    state.next_seq = 1;
  }
  state.job = request;
  state.job.seq = state.next_seq;
  state.has_job = true;
  state.wake.notify_one();
  return state.next_seq;
}

}  // namespace

uint32_t RequestRead(HWND notify, UINT message) {
  try {
    Job job;
    job.kind = Kind::Read;
    job.notify = notify;
    job.message = message;
    return Submit(job);
  } catch (...) {
    return 0;
  }
}

uint32_t RequestMove(HWND notify, UINT message, const std::string& id, int x, int y) {
  try {
    Job job;
    job.kind = Kind::Move;
    job.id = id;
    job.x = x;
    job.y = y;
    job.notify = notify;
    job.message = message;
    return Submit(job);
  } catch (...) {
    return 0;
  }
}

bool Take(Answer* answer) {
  try {
    State& state = Shared();
    std::lock_guard<std::mutex> lock(state.lock);
    if (!state.has_answer) {
      return false;
    }
    *answer = std::move(state.answer);
    state.has_answer = false;
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

}  // namespace mochi_icons
