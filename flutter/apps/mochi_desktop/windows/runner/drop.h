#ifndef RUNNER_DROP_H_
#define RUNNER_DROP_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// Files, text and links dropped on Mochi (docs/SPRINT_2.md X13, X14): an OLE drop target on the Flutter view that reports to
// Dart over the `mochi/drop` channel (lib/src/platform/file_drop.dart).
//
// While something is dragged over, only the formats on offer are asked about (QueryGetData); the data is read only when the
// drop happens (CF_HDROP file paths, the "UniformResourceLocatorW" link, CF_UNICODETEXT text) and handed to Dart, which
// shows it to the user. Nothing is opened, copied, kept or logged here, and no file is ever read.
namespace mochi_drop {

class Host;

// Registers the drop target on |view| (the Flutter view's window) for as long as this object lives.
class Registration {
 public:
  Registration(HWND view, flutter::BinaryMessenger* messenger);
  ~Registration();
  Registration(const Registration&) = delete;
  Registration& operator=(const Registration&) = delete;

 private:
  std::unique_ptr<Host> host_;
};

}  // namespace mochi_drop

#endif  // RUNNER_DROP_H_
