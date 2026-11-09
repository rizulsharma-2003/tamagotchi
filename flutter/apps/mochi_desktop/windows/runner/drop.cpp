#include "drop.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <shellapi.h>

#include <atomic>
#include <string>

#include "utils.h"

namespace mochi_drop {
namespace {

// The registered clipboard format a browser or Explorer gives a dragged link in (CFSTR_INETURLW).
constexpr wchar_t kUrlFormatName[] = L"UniformResourceLocatorW";

// At most this many paths and this many UTF-16 units of text are handed to Dart (which keeps 5 files and 8,000 characters).
constexpr UINT kMaxFiles = 64;
constexpr size_t kMaxChars = 100000;

CLIPFORMAT UrlFormat() {
  static const CLIPFORMAT format = static_cast<CLIPFORMAT>(::RegisterClipboardFormatW(kUrlFormatName));
  return format;
}

FORMATETC Format(CLIPFORMAT format) {
  FORMATETC wanted = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  return wanted;
}

// Whether the drag offers [format]; asks only, reads nothing.
bool Offers(IDataObject* data, CLIPFORMAT format) {
  FORMATETC wanted = Format(format);
  return data != nullptr && data->QueryGetData(&wanted) == S_OK;
}

bool Droppable(IDataObject* data) {
  return Offers(data, CF_HDROP) || Offers(data, UrlFormat()) || Offers(data, CF_UNICODETEXT);
}

// A text format's contents (UTF-16, nul-terminated, cut at kMaxChars) as UTF-8; empty when it isn't there.
std::string ReadText(IDataObject* data, CLIPFORMAT format) {
  FORMATETC wanted = Format(format);
  STGMEDIUM medium = {};
  if (data->GetData(&wanted, &medium) != S_OK) {
    return std::string();
  }
  std::string text;
  if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal != nullptr) {
    const auto* chars = static_cast<const wchar_t*>(::GlobalLock(medium.hGlobal));
    if (chars != nullptr) {
      const size_t room = ::GlobalSize(medium.hGlobal) / sizeof(wchar_t);
      size_t length = 0;
      while (length < room && length < kMaxChars && chars[length] != L'\0') {
        ++length;
      }
      const std::wstring copy(chars, length);
      text = Utf8FromUtf16(copy.c_str());
      ::GlobalUnlock(medium.hGlobal);
    }
  }
  ::ReleaseStgMedium(&medium);
  return text;
}

// The dropped files' full paths (CF_HDROP), as UTF-8.
flutter::EncodableList ReadFiles(IDataObject* data) {
  flutter::EncodableList files;
  FORMATETC wanted = Format(CF_HDROP);
  STGMEDIUM medium = {};
  if (data->GetData(&wanted, &medium) != S_OK) {
    return files;
  }
  if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal != nullptr) {
    const HDROP drop = static_cast<HDROP>(medium.hGlobal);
    const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count && i < kMaxFiles; ++i) {
      const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
      if (length == 0) {
        continue;
      }
      std::wstring path(static_cast<size_t>(length) + 1, L'\0');
      const UINT copied = ::DragQueryFileW(drop, i, path.data(), length + 1);
      if (copied == 0) {
        continue;
      }
      path.resize(copied);
      files.push_back(flutter::EncodableValue(Utf8FromUtf16(path.c_str())));
    }
  }
  ::ReleaseStgMedium(&medium);
  return files;
}

}  // namespace

// The drop target: COM object, one reference held by OLE's registration and one by the Registration that made it.
class Host : public IDropTarget {
 public:
  Host(HWND view, flutter::BinaryMessenger* messenger)
      : view_(view),
        channel_(messenger, "mochi/drop", &flutter::StandardMethodCodec::GetInstance()) {}

  // The channel stops being used before the window goes.
  bool Register() {
    // OleInitialize needs a single-threaded apartment, which main.cpp's CoInitializeEx made (S_FALSE: already done).
    const HRESULT ole = ::OleInitialize(nullptr);
    ole_ = SUCCEEDED(ole);
    registered_ = ::RegisterDragDrop(view_, this) == S_OK;
    return registered_;
  }

  void Unregister() {
    live_ = false;
    if (registered_) {
      ::RevokeDragDrop(view_);
      registered_ = false;
    }
    if (ole_) {
      ::OleUninitialize();
      ole_ = false;
    }
  }

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (id == IID_IUnknown || id == IID_IDropTarget) {
      *object = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(++references_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG left = static_cast<ULONG>(--references_);
    // The Registration owns this object through a unique_ptr and OLE's reference ends at RevokeDragDrop: the object is
    // never deleted by a reference count.
    return left;
  }

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    accepting_ = live_ && Droppable(data);
    *effect = accepting_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (accepting_) {
      Hover(true);
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = accepting_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (accepting_) {
      Hover(false);
    }
    accepting_ = false;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    if (accepting_) {
      Hover(false);
    }
    const bool wanted = accepting_;
    accepting_ = false;
    if (!wanted || !live_ || data == nullptr) {
      return S_OK;
    }
    // Only now is anything read: the file paths (never the files), the link and the text.
    flutter::EncodableMap map;
    flutter::EncodableList files = ReadFiles(data);
    flutter::EncodableList uris;
    const std::string url = ReadText(data, UrlFormat());
    if (!url.empty()) {
      uris.push_back(flutter::EncodableValue(url));
    }
    const std::string text = ReadText(data, CF_UNICODETEXT);
    const bool any = !files.empty() || !uris.empty() || !text.empty();
    map[flutter::EncodableValue("files")] = flutter::EncodableValue(files);
    map[flutter::EncodableValue("uris")] = flutter::EncodableValue(uris);
    if (!text.empty()) {
      map[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
    }
    if (any) {
      channel_.InvokeMethod("dropped", std::make_unique<flutter::EncodableValue>(std::move(map)));
      *effect = DROPEFFECT_COPY;
    }
    return S_OK;
  }

 private:
  void Hover(bool over) {
    if (live_) {
      channel_.InvokeMethod("hover", std::make_unique<flutter::EncodableValue>(over));
    }
  }

  HWND view_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::atomic<long> references_{1};
  bool accepting_ = false;
  bool registered_ = false;
  bool ole_ = false;
  bool live_ = true;
};

Registration::Registration(HWND view, flutter::BinaryMessenger* messenger)
    : host_(std::make_unique<Host>(view, messenger)) {
  host_->Register();
}

Registration::~Registration() {
  if (host_) {
    host_->Unregister();
  }
}

}  // namespace mochi_drop
