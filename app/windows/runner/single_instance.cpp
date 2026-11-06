#include "single_instance.h"
#include "utils.h"
#include <shellapi.h>

namespace single_instance {
namespace {
BOOL CALLBACK FindPrimary(HWND window, LPARAM value) {
  if (GetPropW(window, kWindowProperty)) {
    *reinterpret_cast<HWND*>(value) = window;
    return FALSE;
  }
  return TRUE;
}
}

std::vector<std::string> ImageArguments() {
  int count = 0;
  auto args = CommandLineToArgvW(GetCommandLineW(), &count);
  std::vector<std::string> result;
  if (!args) return result;
  for (int i = 1; i < count && result.size() < 64; ++i) {
    const std::wstring value(args[i]);
    if (value.size() < 5 || _wcsicmp(value.c_str() + value.size() - 5, L".vhdx") != 0) continue;
    std::vector<wchar_t> full(32768);
    const auto length = GetFullPathNameW(value.c_str(), static_cast<DWORD>(full.size()), full.data(), nullptr);
    if (length && length < full.size()) result.push_back(Utf8FromUtf16(full.data()));
  }
  LocalFree(args);
  return result;
}

Instance::Result Instance::Start(const std::vector<std::string>& paths) {
  mutex_ = CreateMutexW(nullptr, TRUE, kIdentity);
  if (!mutex_) return Result::failed;
  if (GetLastError() != ERROR_ALREADY_EXISTS) { owner_ = true; return Result::primary; }
  std::string payload;
  for (const auto& path : paths) { payload += path; payload.push_back('\0'); }
  if (payload.empty()) payload.push_back('\0');
  if (payload.size() > 65536) return Result::failed;
  const auto deadline = GetTickCount64() + 10000;
  do {
    // A crashed/failed primary must not leave a stale lock that blocks startup.
    const auto lock = WaitForSingleObject(mutex_, 0);
    if (lock == WAIT_OBJECT_0 || lock == WAIT_ABANDONED) { owner_ = true; return Result::primary; }
    HWND window = nullptr;
    EnumWindows(FindPrimary, reinterpret_cast<LPARAM>(&window));
    if (window) {
      DWORD process = 0;
      GetWindowThreadProcessId(window, &process);
      AllowSetForegroundWindow(process);
      COPYDATASTRUCT data{kCopyData, static_cast<DWORD>(payload.size()), payload.data()};
      DWORD_PTR handled = 0;
      if (SendMessageTimeoutW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
                             SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000, &handled) && handled) return Result::forwarded;
    }
    Sleep(50);
  } while (GetTickCount64() < deadline);
  return Result::failed;
}

Instance::~Instance() {
  if (owner_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}
}
