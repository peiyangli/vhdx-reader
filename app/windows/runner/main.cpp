#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <roapi.h>

#include "flutter_window.h"
#include "utils.h"
#include "single_instance.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const auto paths = single_instance::ImageArguments();
  single_instance::Instance instance_guard;
  const auto instance_result = instance_guard.Start(paths);
  if (instance_result == single_instance::Instance::Result::forwarded) return EXIT_SUCCESS;
  if (instance_result == single_instance::Instance::Result::failed) {
    MessageBoxW(nullptr, L"已有窗口暂时没有响应，请稍后重新启动。", L"VHDX Reader", MB_OK | MB_ICONINFORMATION);
    return EXIT_FAILURE;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize WinRT and COM on the window thread for Windows Hello and plugins.
  if (FAILED(::RoInitialize(RO_INIT_SINGLETHREADED))) return EXIT_FAILURE;

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments;
  if (!paths.empty()) command_line_arguments.push_back(paths.front());

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 820);
  if (!window.Create(L"VHDX Reader", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (paths.size() > 1) window.QueueLaunchPaths(std::vector<std::string>(paths.begin() + 1, paths.end()));

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::RoUninitialize();
  return EXIT_SUCCESS;
}
