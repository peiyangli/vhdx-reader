import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  var quitting = false
  var terminationPending = false
  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?
  private var recentStorage: RecentDocumentStorage?
  private var dartReady = false
  private var pendingImages: [String] = []

  override func awakeFromNib() {
    installVaultAuthentication()
    let controller = FlutterViewController()
    contentViewController = controller
    setFrame(NSRect(origin: frame.origin, size: NSSize(width: 1200, height: 800)), display: true)
    minSize = NSSize(width: 720, height: 540)
    setFrameAutosaveName("VHDXReaderMainWindow")
    RegisterGeneratedPlugins(registry: controller)
    recentStorage = RecentDocumentStorage(messenger: controller.engine.binaryMessenger)
    super.awakeFromNib()
    delegate = self
    channel = FlutterMethodChannel(name: "vhdx_reader/window", binaryMessenger: controller.engine.binaryMessenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "ready" {
        self.dartReady = true
        result(nil)
        self.flushImages()
      } else if call.method == "quit" {
        self.quitting = true
        cancelDesktopVaultAuthentication()
        result(nil)
        if self.terminationPending { NSApp.reply(toApplicationShouldTerminate: true) }
        else { NSApp.terminate(nil) }
      } else if call.method == "cancelQuit" {
        if self.terminationPending { NSApp.reply(toApplicationShouldTerminate: false) }
        self.terminationPending = false
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
      NSColor.black.setFill()
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 2, y: 14)); path.line(to: NSPoint(x: 6, y: 14))
      path.line(to: NSPoint(x: 9, y: 7)); path.line(to: NSPoint(x: 12, y: 14))
      path.line(to: NSPoint(x: 16, y: 14)); path.line(to: NSPoint(x: 11, y: 3))
      path.line(to: NSPoint(x: 7, y: 3)); path.close(); path.fill()
      NSBezierPath(roundedRect: NSRect(x: 2, y: 0, width: 14, height: 2), xRadius: 1, yRadius: 1).fill()
      return true
    }
    image.isTemplate = true
    item.button?.image = image
    item.button?.toolTip = "VHDX Reader"
    let menu = NSMenu()
    for (title, action) in [("显示主窗口", #selector(showMain)),
                            ("锁定所有 BitLocker 卷", #selector(lockAll)),
                            ("设置", #selector(settings))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self; menu.addItem(entry)
    }
    menu.addItem(.separator())
    let exit = NSMenuItem(title: "退出应用", action: #selector(quit), keyEquivalent: "q")
    exit.target = self; menu.addItem(exit)
    item.menu = menu; statusItem = item
  }

  func openImages(_ paths: [String]) {
    pendingImages.append(contentsOf: paths.filter { $0.lowercased().hasSuffix(".vhdx") })
    restoreFromTray()
    flushImages()
  }
  private func flushImages() {
    guard dartReady, !pendingImages.isEmpty else { return }
    let paths = pendingImages; pendingImages.removeAll()
    channel?.invokeMethod("openImages", arguments: paths)
  }
  func notify(_ event: String) { channel?.invokeMethod(event, arguments: nil) }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if quitting { return true }
    guard statusItem?.button != nil else { NSSound.beep(); return false }
    cancelDesktopVaultAuthentication()
    notify("hidden"); orderOut(nil)
    return false
  }
  func restoreFromTray() {
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); notify("shown")
  }
  @objc private func showMain() { restoreFromTray() }
  @objc private func lockAll() { cancelDesktopVaultAuthentication(); restoreFromTray(); notify("lockAll") }
  @objc private func settings() { restoreFromTray(); notify("settings") }
  @objc private func quit() { NSApp.terminate(nil) }
}

// Keep restored security scopes alive for the process, just like NSOpenPanel's
// grants. No file contents or credentials are stored in these bookmarks.
private final class RecentDocumentStorage {
  private var channel: FlutterMethodChannel
  private var scopes: [String: URL] = [:]
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "org.vhdxreader/storage", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any], let path = args["uri"] as? String else { result(FlutterMethodNotImplemented); return }
      if call.method == "bookmarkRecent" {
        let url = URL(fileURLWithPath: path)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
          result(data.base64EncodedString())
        } catch { result(FlutterError(code: "bookmark", message: "无法保存文件授权，请重新选择镜像。", details: nil)) }
      } else if call.method == "restoreRecent" {
        do {
          var url = URL(fileURLWithPath: path)
          if let encoded = args["bookmark"] as? String, let data = Data(base64Encoded: encoded) {
            var stale = false
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
          }
          if self.scopes[url.path] == nil, url.startAccessingSecurityScopedResource() { self.scopes[url.path] = url }
          guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
          result(["uri": url.path, "name": url.lastPathComponent])
        } catch { result(FlutterError(code: "document", message: "无法访问最近镜像，请连接存储设备或重新选择文件授权。", details: nil)) }
      } else { result(FlutterMethodNotImplemented) }
    }
  }
  deinit { for url in scopes.values { url.stopAccessingSecurityScopedResource() } }
}
