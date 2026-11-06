#include "flutter_window.h"
#include "vault_authentication.h"
#include "single_instance.h"
#include <cstring>

#include <optional>
#include <shellapi.h>
#include "resource.h"
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  vault_authentication::Install(GetHandle());
  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Keep the system sizing frame and window commands; Flutter draws the title row.
  const auto hwnd = GetHandle();
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   GetWindowLongPtr(hwnd, GWL_STYLE) & ~WS_CAPTION);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "vhdx_reader/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this, hwnd](const auto& call, auto result) {
        const auto& action = call.method_name();
        if (action == "ready") {
          dart_ready_ = true;
          result->Success();
          FlushLaunchPaths();
        } else if (action == "drag") {
          result->Success();
          ReleaseCapture();
          POINT cursor{};
          GetCursorPos(&cursor);
          PostMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION,
                      MAKELPARAM(cursor.x, cursor.y));
        } else if (action == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (action == "maximize") {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (action == "close") {
          result->Success();
          PostMessage(hwnd, WM_CLOSE, 0, 0);
        } else if (action == "quit") {
          quitting_ = true;
          result->Success();
          PostMessage(hwnd, WM_CLOSE, 0, 0);
        } else {
          result->NotImplemented();
        }
      });

  SetPropW(hwnd, single_instance::kWindowProperty, reinterpret_cast<HANDLE>(1));
  AddTray();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemovePropW(GetHandle(), single_instance::kWindowProperty);
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  vault_authentication::Detach(GetHandle());
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_COPYDATA) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (!data || data->dwData != single_instance::kCopyData || !data->lpData ||
        data->cbData == 0 || data->cbData > 65536) return FALSE;
    const auto* bytes = static_cast<const char*>(data->lpData);
    if (bytes[data->cbData - 1] != '\0') return FALSE;
    std::vector<std::string> paths;
    size_t offset = 0;
    while (offset < data->cbData) {
      const auto length = strnlen(bytes + offset, data->cbData - offset);
      if (length) {
        if (paths.size() >= 64 || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
              bytes + offset, static_cast<int>(length), nullptr, 0)) return FALSE;
        paths.emplace_back(bytes + offset, length);
      }
      offset += length + 1;
    }
    Restore();
    QueueLaunchPaths(paths);
    return TRUE;
  }
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == taskbar_created) { AddTray(); return 0; }
  if (message == WM_APP + 90) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK) Restore();
    if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"显示主窗口");
      AppendMenuW(menu, MF_STRING, 2, L"锁定所有 BitLocker 卷");
      AppendMenuW(menu, MF_STRING, 3, L"设置");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, 4, L"退出应用");
      POINT point{}; GetCursorPos(&point); SetForegroundWindow(hwnd);
      const auto command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
          point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu); PostMessage(hwnd, WM_NULL, 0, 0);
      if (command) Restore();
      if (command == 2) { vault_authentication::CancelPending(); Notify("lockAll"); }
      if (command == 3) Notify("settings");
      if (command == 4) Notify("requestQuit");
    }
    return 0;
  }
  if (message == WM_CLOSE && !quitting_) {
    if (!tray_ready_) AddTray();
    if (!tray_ready_) {
      MessageBoxW(hwnd, L"无法创建托盘图标，请稍后重试。", L"VHDX Reader", MB_OK | MB_ICONWARNING);
      return 0;
    }
    vault_authentication::CancelPending();
    hidden_ = true; Notify("hidden"); ShowWindow(hwnd, SW_HIDE); return 0;
  }
  if (message == WM_QUERYENDSESSION) { quitting_ = true; return TRUE; }
  if (message == WM_ENDSESSION && wparam) { quitting_ = true; DestroyWindow(hwnd); return 0; }
  if (vault_authentication::HandleMessage(message, wparam)) return 0;

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::Notify(const char* event) {
  if (window_channel_) window_channel_->InvokeMethod(event, nullptr);
}

void FlutterWindow::Restore() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
  hidden_ = false;
  Notify("shown");
}

void FlutterWindow::AddTray() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  icon.uCallbackMessage = WM_APP + 90;
  icon.hIcon = static_cast<HICON>(LoadImageW(GetModuleHandle(nullptr),
      MAKEINTRESOURCE(IDI_TRAY_ICON), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
      GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  wcscpy_s(icon.szTip, L"VHDX Reader");
  tray_ready_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  if (tray_ready_) {
    icon.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
  } else if (hidden_) { Restore(); }
}

void FlutterWindow::QueueLaunchPaths(const std::vector<std::string>& paths) {
  launch_paths_.insert(launch_paths_.end(), paths.begin(), paths.end());
  FlushLaunchPaths();
}

void FlutterWindow::FlushLaunchPaths() {
  if (!dart_ready_ || !window_channel_ || launch_paths_.empty()) return;
  flutter::EncodableList paths;
  for (const auto& path : launch_paths_) paths.emplace_back(path);
  launch_paths_.clear();
  window_channel_->InvokeMethod("openImages", std::make_unique<flutter::EncodableValue>(paths));
}
