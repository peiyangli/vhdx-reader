#include "flutter_window.h"
#include "vault_authentication.h"

#include <optional>
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
      [hwnd](const auto& call, auto result) {
        const auto& action = call.method_name();
        if (action == "drag") {
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
        } else {
          result->NotImplemented();
        }
      });

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
