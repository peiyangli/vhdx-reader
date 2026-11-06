import Flutter
import UIKit
import LocalAuthentication

// Runs synchronously on the Rust worker; all UI work stays on the main queue.
private final class VaultAuthenticationAttempt {
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
  let attempt = VaultAuthenticationAttempt()
  DispatchQueue.main.async {
    guard !attempt.isFinished else { return }
    guard UIApplication.shared.applicationState == .active else { attempt.finish(2); return }
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

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    vhdx_install_device_authentication(authenticateSavedCredential)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DocumentStorage") {
      DocumentStorage.register(with: registrar)
    }
  }
}
