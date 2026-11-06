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

private func authenticateSavedCredential() -> Int32 {
  guard !Thread.isMainThread else { return 2 }
  let attempt = DesktopVaultAttempt()
  DispatchQueue.main.async {
    guard !attempt.isFinished else { return }
    guard NSApplication.shared.isActive else { attempt.finish(2); return }
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
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
