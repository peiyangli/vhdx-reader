import Cocoa
import FlutterMacOS
import LocalAuthentication
import Darwin

private final class DesktopVaultAttempt {
  let context = LAContext()
  let completed = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var value: Int32? = nil
  func finish(_ code: Int32) {
    lock.lock()
    defer { lock.unlock() }
    if value == nil { value = code; completed.signal() }
  }
  var result: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return value ?? 1
  }
  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value != nil
  }
}

private var desktopVaultAttempts: [DesktopVaultAttempt] = []
func cancelDesktopVaultAuthentication() {
  for attempt in desktopVaultAttempts { attempt.finish(1); attempt.context.invalidate() }
  desktopVaultAttempts.removeAll()
}

private func authenticateSavedCredential() -> Int32 {
  guard !Thread.isMainThread else { return 2 }
  let attempt = DesktopVaultAttempt()
  DispatchQueue.main.async {
    guard !attempt.isFinished else { return }
    guard NSApplication.shared.isActive else { attempt.finish(2); return }
    desktopVaultAttempts.removeAll { $0.isFinished }
    desktopVaultAttempts.append(attempt)
    var error: NSError?
    guard attempt.context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      attempt.finish(2)
      return
    }
    attempt.context.localizedCancelTitle = "取消"
    attempt.context.touchIDAuthenticationAllowableReuseDuration = 0
    attempt.context.evaluatePolicy(.deviceOwnerAuthentication,
      localizedReason: "验证身份后使用已保存的密码解锁 BitLocker") { success, _ in
        attempt.finish(success ? 0 : 1)
    }
  }
  if attempt.completed.wait(timeout: .now() + 120) == .timedOut { attempt.finish(1) }
  attempt.context.invalidate()
  return attempt.result
}

// Process-lifetime library ownership matches the Rust worker and Dart bindings.
private var vaultLibrary: UnsafeMutableRawPointer?
func installVaultAuthentication() {
  guard vaultLibrary == nil,
        let frameworks = Bundle.main.privateFrameworksPath,
        let library = dlopen(frameworks + "/vhdx/libvhdx_app.dylib", RTLD_NOW | RTLD_LOCAL)
  else { return }
  vaultLibrary = library
  guard let symbol = dlsym(library, "vhdx_install_device_authentication") else { return }
  typealias Authenticate = @convention(c) () -> Int32
  typealias Install = @convention(c) (Authenticate) -> Void
  unsafeBitCast(symbol, to: Install.self)(authenticateSavedCredential)
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    (mainFlutterWindow as? MainFlutterWindow)?.restoreFromTray()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = mainFlutterWindow as? MainFlutterWindow, !window.quitting else { return .terminateNow }
    window.terminationPending = true
    window.restoreFromTray()
    window.notify("requestQuit")
    return .terminateLater
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
