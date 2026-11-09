#include "jump_list.h"

#include <propkey.h>
#include <propvarutil.h>
#include <shobjidl.h>
#include <wrl/client.h>

namespace mochi_jumplist {
namespace {

using Microsoft::WRL::ComPtr;

// Mochi's AppUserModelID, as main.cpp and the installer's Start-menu shortcut have it.
constexpr wchar_t kAppUserModelId[] = L"InsideEdge.Mochi";

// One task: a link that starts [exe] with [arguments], shown as [title].
HRESULT AddTask(IObjectCollection* tasks, const wchar_t* exe, const wchar_t* arguments, const wchar_t* title) {
  ComPtr<IShellLinkW> link;
  HRESULT hr = ::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link));
  if (FAILED(hr)) {
    return hr;
  }
  hr = link->SetPath(exe);
  if (FAILED(hr)) {
    return hr;
  }
  hr = link->SetArguments(arguments);
  if (FAILED(hr)) {
    return hr;
  }
  hr = link->SetIconLocation(exe, 0);
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IPropertyStore> store;
  hr = link.As(&store);
  if (FAILED(hr)) {
    return hr;
  }
  PROPVARIANT name;
  hr = ::InitPropVariantFromString(title, &name);
  if (FAILED(hr)) {
    return hr;
  }
  hr = store->SetValue(PKEY_Title, name);
  ::PropVariantClear(&name);
  if (FAILED(hr)) {
    return hr;
  }
  hr = store->Commit();
  if (FAILED(hr)) {
    return hr;
  }
  return tasks->AddObject(link.Get());
}

// Fills the list that was begun with the two tasks and commits it.
HRESULT Fill(ICustomDestinationList* list, const wchar_t* exe) {
  ComPtr<IObjectCollection> tasks;
  HRESULT hr = ::CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&tasks));
  if (FAILED(hr)) {
    return hr;
  }
  hr = AddTask(tasks.Get(), exe, L"--ask", L"Ask Mochi");
  if (FAILED(hr)) {
    return hr;
  }
  hr = AddTask(tasks.Get(), exe, L"--explore", L"Explore");
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IObjectArray> array;
  hr = tasks.As(&array);
  if (FAILED(hr)) {
    return hr;
  }
  hr = list->AddUserTasks(array.Get());
  if (FAILED(hr)) {
    return hr;
  }
  return list->CommitList();
}

}  // namespace

HRESULT Build() {
  wchar_t exe[MAX_PATH] = {0};
  const DWORD length = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return E_FAIL;
  }
  ComPtr<ICustomDestinationList> list;
  HRESULT hr = ::CoCreateInstance(CLSID_DestinationList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list));
  if (FAILED(hr)) {
    return hr;
  }
  hr = list->SetAppID(kAppUserModelId);
  if (FAILED(hr)) {
    return hr;
  }
  UINT slots = 0;
  ComPtr<IObjectArray> removed;
  hr = list->BeginList(&slots, IID_PPV_ARGS(&removed));
  if (FAILED(hr)) {
    return hr;
  }
  hr = Fill(list.Get(), exe);
  if (FAILED(hr)) {
    // The list was begun and not committed: put it back as it was.
    list->AbortList();
  }
  return hr;
}

}  // namespace mochi_jumplist
