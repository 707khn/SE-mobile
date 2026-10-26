#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Одно окно на пользователя Windows. Второй запуск — ярлык нажали ещё
  // раз — не открывает второе приложение, а поднимает первое: две копии
  // писали бы код, вход и настройки в одни и те же файлы одновременно.
  HANDLE single_instance =
      ::CreateMutexW(nullptr, FALSE, L"Local\\SemEngSingleInstance");
  if (single_instance != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"SemEng");
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }

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

  // Окно — высокое и узкое, как телефон на столе: все экраны свёрстаны под
  // телефон в руке. Высота — сколько позволяет экран без панели задач, но не
  // больше 900 точек; ставим посередине основного монитора. Растянуть или
  // развернуть окно можно — тогда содержимое встанет колонкой посередине.
  RECT work;
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  HMONITOR monitor = ::MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const int work_width = static_cast<int>((work.right - work.left) / scale);
  const int work_height = static_cast<int>((work.bottom - work.top) / scale);
  const int width = 520;
  const int height = std::max(560, std::min(900, work_height - 60));
  Win32Window::Point origin(
      static_cast<unsigned int>(
          std::max(0, static_cast<int>(work.left / scale) +
                          (work_width - width) / 2)),
      static_cast<unsigned int>(
          std::max(0, static_cast<int>(work.top / scale) +
                          (work_height - height) / 2)));
  Win32Window::Size size(width, height);
  if (!window.Create(L"SemEng", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
