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
  private var instanceLock: Int32 = -1
  private var duplicateInstance = false
  private var reopenObserver: NSObjectProtocol?
#if DEBUG
  private let reopenName = Notification.Name("org.vhdxreader.reopen.debug")
#else
  private let reopenName = Notification.Name("org.vhdxreader.reopen")
#endif
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Register before taking the lock so a concurrent launch cannot lose its
    // wake-up notification while the primary is still constructing its window.
    reopenObserver = DistributedNotificationCenter.default().addObserver(forName: reopenName, object: nil, queue: .main) { [weak self] _ in
      guard let self = self, !self.duplicateInstance else { return }
      DispatchQueue.main.async { (self.mainFlutterWindow as? MainFlutterWindow)?.restoreFromTray() }
    }
    do {
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let directory = root.appendingPathComponent("VHDXReader", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if DEBUG
      let lockURL = directory.appendingPathComponent("instance-debug.lock")
#else
      let lockURL = directory.appendingPathComponent("instance.lock")
#endif
      instanceLock = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
      guard instanceLock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
      if flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
        duplicateInstance = true
        DistributedNotificationCenter.default().postNotificationName(reopenName, object: nil, userInfo: nil, deliverImmediately: true)
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
          .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
          .first?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.terminate(nil)
        return
      }
    } catch {
      duplicateInstance = true
      let alert = NSAlert(); alert.messageText = "无法初始化应用运行状态，请稍后重试。"; alert.runModal()
      NSApp.terminate(nil)
      return
    }
    super.applicationWillFinishLaunching(notification)
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    (mainFlutterWindow as? MainFlutterWindow)?.openImages(filenames)
    sender.reply(toOpenOrPrint: .success)
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if let observer = reopenObserver { DistributedNotificationCenter.default().removeObserver(observer) }
    if instanceLock >= 0 { Darwin.close(instanceLock); instanceLock = -1 }
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    (mainFlutterWindow as? MainFlutterWindow)?.restoreFromTray()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !duplicateInstance, let window = mainFlutterWindow as? MainFlutterWindow, !window.quitting else { return .terminateNow }
    window.terminationPending = true
    window.restoreFromTray()
    window.notify("requestQuit")
    return .terminateLater
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
