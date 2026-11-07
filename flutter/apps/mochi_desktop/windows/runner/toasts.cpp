#include "toasts.h"

#include <NotificationActivationCallback.h>
#include <roapi.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>

namespace mochi_toasts {
namespace {

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::Wrappers::HStringReference;
namespace dom = ABI::Windows::Data::Xml::Dom;
namespace toast = ABI::Windows::UI::Notifications;

HWND g_window = nullptr;
UINT g_message = 0;
DWORD g_cookie = 0;

// Windows calls this when one of Mochi's toasts (or one of its buttons) is clicked: the toast's `launch` argument goes
// to the UI thread, which hands it to Dart.
class Activator : public RuntimeClass<RuntimeClassFlags<ClassicCom>, INotificationActivationCallback> {
 public:
  IFACEMETHODIMP Activate(LPCWSTR app_user_model_id, LPCWSTR invoked_args, const NOTIFICATION_USER_INPUT_DATA* data,
                          ULONG count) override {
    if (g_window == nullptr) {
      return S_OK;
    }
    auto* text = new std::wstring(invoked_args == nullptr ? L"" : invoked_args);
    if (!::PostMessageW(g_window, g_message, 0, reinterpret_cast<LPARAM>(text))) {
      delete text;
    }
    return S_OK;
  }
};

class ActivatorFactory : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IClassFactory> {
 public:
  IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    *object = nullptr;
    if (outer != nullptr) {
      return CLASS_E_NOAGGREGATION;
    }
    ComPtr<Activator> activator = Make<Activator>();
    if (!activator) {
      return E_OUTOFMEMORY;
    }
    return activator.CopyTo(riid, object);
  }

  IFACEMETHODIMP LockServer(BOOL lock) override { return S_OK; }
};

HRESULT Notifier(const std::wstring& app_id, toast::IToastNotifier** notifier) {
  ComPtr<toast::IToastNotificationManagerStatics> manager;
  HRESULT hr = ::RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(),
                                        IID_PPV_ARGS(manager.ReleaseAndGetAddressOf()));
  if (FAILED(hr)) {
    return hr;
  }
  return manager->CreateToastNotifierWithId(
      HStringReference(app_id.c_str(), static_cast<unsigned int>(app_id.size())).Get(), notifier);
}

}  // namespace

bool Start(HWND window, UINT message, const std::wstring& activator_clsid) {
  g_window = window;
  g_message = message;
  if (g_cookie != 0) {
    return true;
  }
  CLSID clsid;
  if (FAILED(::CLSIDFromString(activator_clsid.c_str(), &clsid))) {
    return false;
  }
  ComPtr<ActivatorFactory> made = Make<ActivatorFactory>();
  ComPtr<IClassFactory> factory;
  if (!made || FAILED(made.As(&factory))) {
    return false;
  }
  return SUCCEEDED(::CoRegisterClassObject(clsid, factory.Get(), CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &g_cookie));
}

HRESULT Show(const std::wstring& app_id, const std::wstring& xml, const std::wstring& tag) {
  ComPtr<IInspectable> inspectable;
  HRESULT hr = ::RoActivateInstance(HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(),
                                    inspectable.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<dom::IXmlDocument> document;
  ComPtr<dom::IXmlDocumentIO> io;
  if (FAILED(hr = inspectable.As(&document)) || FAILED(hr = document.As(&io))) {
    return hr;
  }
  hr = io->LoadXml(HStringReference(xml.c_str(), static_cast<unsigned int>(xml.size())).Get());
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<toast::IToastNotificationFactory> factory;
  hr = ::RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(),
                                IID_PPV_ARGS(factory.ReleaseAndGetAddressOf()));
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<toast::IToastNotification> notification;
  hr = factory->CreateToastNotification(document.Get(), notification.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<toast::IToastNotification2> tagged;
  if (!tag.empty() && SUCCEEDED(notification.As(&tagged))) {
    tagged->put_Tag(HStringReference(tag.c_str(), static_cast<unsigned int>(tag.size())).Get());
    tagged->put_Group(HStringReference(L"mochi").Get());
  }
  ComPtr<toast::IToastNotifier> notifier;
  hr = Notifier(app_id, notifier.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  return notifier->Show(notification.Get());
}

int Setting(const std::wstring& app_id) {
  ComPtr<toast::IToastNotifier> notifier;
  if (FAILED(Notifier(app_id, notifier.ReleaseAndGetAddressOf()))) {
    return -1;
  }
  toast::NotificationSetting setting;
  if (FAILED(notifier->get_Setting(&setting))) {
    return -1;
  }
  return static_cast<int>(setting);
}

void Stop() {
  if (g_cookie != 0) {
    ::CoRevokeClassObject(g_cookie);
    g_cookie = 0;
  }
  g_window = nullptr;
}

}  // namespace mochi_toasts
