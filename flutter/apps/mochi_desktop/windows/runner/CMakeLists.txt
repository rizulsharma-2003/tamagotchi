cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "desktop_icons.cpp"
  "drop.cpp"
  "flutter_window.cpp"
  "jump_list.cpp"
  "main.cpp"
  "media.cpp"
  "native_stage.cpp"
  "pc_actions.cpp"
  "toasts.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# The session's lock and switch notifications (WTSRegisterSessionNotification), the AppUserModelID (shell32), and
# Windows notifications through WinRT (RoGetActivationFactory: runtimeobject).
target_link_libraries(${BINARY_NAME} PRIVATE "wtsapi32.lib" "shell32.lib" "runtimeobject.lib")
# Desktop icon play (X5): the shell's COM view of the desktop (CoCreateInstance, VariantInit, the CLSIDs).
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib" "oleaut32.lib" "uuid.lib")
# The Start menu jump list (X16): InitPropVariantFromString and PKEY_Title.
target_link_libraries(${BINARY_NAME} PRIVATE "propsys.lib")
# Ask Mochi's PC actions (W9, pc_actions.cpp): the Task Scheduler (taskschd.lib), the default speaker's volume through Core
# Audio (header-only interfaces; the CLSIDs come from __uuidof) and the shell's Apps folder (shell32, ole32, uuid above).
target_link_libraries(${BINARY_NAME} PRIVATE "taskschd.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
