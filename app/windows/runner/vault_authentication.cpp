#include "vault_authentication.h"

#include <userconsentverifierinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>

namespace vault_authentication {
namespace {
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Security::Credentials::UI::UserConsentVerificationResult;
using winrt::Windows::Security::Credentials::UI::UserConsentVerifier;
constexpr UINT kBegin = WM_APP + 81;
constexpr UINT kFinish = WM_APP + 82;
std::atomic<HWND> host{nullptr};
std::mutex pending_mutex;
uintptr_t next_id = 0;
struct Attempt {
  HWND window;
  uintptr_t id;
  std::mutex mutex;
  std::condition_variable changed;
  std::optional<int32_t> result;
  // Accessed only on the window thread; completion callbacks use their argument.
  IAsyncOperation<UserConsentVerificationResult> operation{nullptr};
  void Finish(int32_t code) {
    std::lock_guard<std::mutex> guard(mutex);
    if (!result) { result = code; changed.notify_all(); }
  }
};
std::shared_ptr<Attempt> pending;

void Cancel(const std::shared_ptr<Attempt>& attempt) {
  attempt->Finish(1);
  auto operation = std::move(attempt->operation);
  try { if (operation) operation.Cancel(); } catch (...) {}
}

int32_t AuthenticateImpl() {
  const HWND window = host.load();
  if (!window || !IsWindow(window) ||
      GetCurrentThreadId() == GetWindowThreadProcessId(window, nullptr)) return 2;
  auto attempt = std::make_shared<Attempt>();
  attempt->window = window;
  {
    std::lock_guard<std::mutex> guard(pending_mutex);
    if (pending) return 3;
    attempt->id = ++next_id;
    pending = attempt;
  }
  if (!PostMessage(window, kBegin, attempt->id, 0)) {
    std::lock_guard<std::mutex> guard(pending_mutex);
    if (pending == attempt) pending.reset();
    return 2;
  }
  int32_t result;
  {
    std::unique_lock<std::mutex> guard(attempt->mutex);
    if (!attempt->changed.wait_for(guard, std::chrono::seconds(120),
                                  [&]() { return attempt->result.has_value(); })) {
      attempt->result = 1;
    }
    result = *attempt->result;
  }
  // The UI thread releases/cancels this exact request. Late replies cannot
  // authorize the next request or a recreated window.
  PostMessage(window, kFinish, attempt->id, 0);
  return host.load() == window && IsWindow(window) ? result : 1;
}

int32_t Authenticate() noexcept {
  try { return AuthenticateImpl(); } catch (...) { return 2; }
}

void Begin(const std::shared_ptr<Attempt>& attempt) {
  {
    std::lock_guard<std::mutex> guard(attempt->mutex);
    if (attempt->result) return;
  }
  if (host.load() != attempt->window || !IsWindowVisible(attempt->window) ||
      GetAncestor(GetForegroundWindow(), GA_ROOT) != attempt->window) {
    attempt->Finish(2);
    return;
  }
  try {
    auto factory = winrt::get_activation_factory<UserConsentVerifier,
                                                IUserConsentVerifierInterop>();
    const winrt::hstring reason = L"验证身份后使用已保存的密码解锁 BitLocker";
    attempt->operation = winrt::capture<IAsyncOperation<UserConsentVerificationResult>>(
        factory, &IUserConsentVerifierInterop::RequestVerificationForWindowAsync,
        attempt->window, reinterpret_cast<HSTRING>(winrt::get_abi(reason)));
    attempt->operation.Completed([attempt](const auto& operation, AsyncStatus status) {
      try {
        if (status != AsyncStatus::Completed) {
          attempt->Finish(status == AsyncStatus::Canceled ? 1 : 2);
          return;
        }
        int32_t code = 2;
        switch (operation.GetResults()) {
          case UserConsentVerificationResult::Verified: code = 0; break;
          case UserConsentVerificationResult::Canceled:
          case UserConsentVerificationResult::RetriesExhausted: code = 1; break;
          case UserConsentVerificationResult::DeviceBusy: code = 3; break;
          default: break;
        }
        attempt->Finish(host.load() == attempt->window && IsWindow(attempt->window)
                            ? code : 1);
      } catch (...) { attempt->Finish(2); }
    });
  } catch (...) { attempt->Finish(2); }
}
}  // namespace

void Install(HWND window) {
  host.store(window);
  // Load the same absolute library path used by Dart; retain it for the process.
  wchar_t executable[32768]{};
  const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
  if (!length || length >= 32768) return;
  const auto path = std::filesystem::path(executable).parent_path() /
                    L"native" / L"vhdx_app.dll";
  const auto library = LoadLibraryExW(path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if (!library) return;
  const auto symbol = GetProcAddress(library, "vhdx_install_device_authentication");
  if (!symbol) return;
  using Installer = void (__cdecl *)(int32_t (__cdecl *)());
  Installer install = nullptr;
  static_assert(sizeof(install) == sizeof(symbol));
  std::memcpy(&install, &symbol, sizeof(install));
  install(Authenticate);
}

void Detach(HWND window) {
  if (host.load() != window) return;
  host.store(nullptr);
  std::shared_ptr<Attempt> attempt;
  {
    std::lock_guard<std::mutex> guard(pending_mutex);
    attempt = std::move(pending);
  }
  if (attempt) Cancel(attempt);
}

bool HandleMessage(UINT message, WPARAM id) {
  if (message != kBegin && message != kFinish) return false;
  std::shared_ptr<Attempt> attempt;
  {
    std::lock_guard<std::mutex> guard(pending_mutex);
    if (!pending || pending->id != id) return true;
    attempt = pending;
    if (message == kFinish) pending.reset();
  }
  if (message == kBegin) Begin(attempt); else Cancel(attempt);
  return true;
}
}  // namespace vault_authentication
