import AVFAudio
import Darwin
import Flutter
import UIKit
import UniformTypeIdentifiers

/// A descriptor lease keeps both the security scope and coordinated access alive.
/// Rust duplicates the descriptor; Dart releases the lease only after its reader closes.
private final class DocumentLease {
  let finished = DispatchSemaphore(value: 0)
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
}

private enum PlaybackSession {
  // Platform channel and engine-detach callbacks are serialized on the main thread.
  static var users = 0
  static func acquire() throws {
    if users == 0 {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    }
    users += 1
  }
  static func release(_ count: Int = 1) {
    users = max(0, users - count)
    if users == 0 {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
}

final class DocumentStorage: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private struct Document {
    let url: URL
    let scope: URL
    let writable: Bool
    var createdIdentity: (dev_t, ino_t)?
  }
  private var documents: [String: Document] = [:]
  private var leases: [Int: DocumentLease] = [:]
  private var nextHandle = 1
  private var playbackUsers = 0
  private var detached = false
  private var pickerResult: FlutterResult?
  private var exportName: String?
  private weak var presenter: UIViewController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DocumentStorage()
    instance.presenter = registrar.viewController
    let channel = FlutterMethodChannel(name: "org.vhdxreader/storage", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !detached else { fail(result, "closed", "读取组件已关闭。"); return }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "screenDirection":
      result(UserDefaults.standard.string(forKey: "reader_screen_direction") ?? "automatic")
    case "setScreenDirection":
      guard let value = args["value"] as? String,
            ["automatic", "portrait", "landscape"].contains(value) else {
        fail(result, "direction", "无效的屏幕方向。"); return
      }
      UserDefaults.standard.set(value, forKey: "reader_screen_direction")
      result(nil)
    case "beginPlayback":
#if targetEnvironment(simulator)
      // The pinned libmpv simulator slices disable every audio output driver.
      result(false)
#else
      do {
        try PlaybackSession.acquire()
        playbackUsers += 1
        result(true)
      } catch { fail(result, "audio", "无法启用音频输出，请结束通话或检查播放设备。") }
#endif
    case "endPlayback":
      if playbackUsers > 0 { playbackUsers -= 1; PlaybackSession.release() }
      result(nil)
    case "nativeDirectory":
      result(Bundle.main.privateFrameworksPath)
    case "chooseImages", "chooseCredential", "createExport":
      guard pickerResult == nil else { fail(result, "busy", "文件选择窗口已打开。"); return }
      let exporting = call.method == "createExport"
      if exporting {
        guard let name = args["name"] as? String, !name.isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
          fail(result, "name", "无法使用此导出文件名。"); return
        }
        exportName = name
      }
      // Unknown VHDX types must remain selectable in Files and third-party providers.
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: exporting ? [.folder] : [.data], asCopy: false)
      picker.allowsMultipleSelection = call.method == "chooseImages"
      picker.delegate = self
      pickerResult = result
      let host = presenter ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
      guard let host = host, host.presentedViewController == nil else {
        pickerResult = nil; exportName = nil
        fail(result, "presentation", "请先关闭当前弹窗，再选择文件。"); return
      }
      host.present(picker, animated: true)
    case "openDescriptor":
      guard let uri = args["uri"] as? String, let document = documents[uri] else {
        fail(result, "document", "文件授权已失效，请重新选择文件。"); return
      }
      let write = args["write"] as? Bool ?? false
      guard write == document.writable else { fail(result, "readonly", "镜像和密码文件仅允许读取。"); return }
      open(uri, document, write, result)
    case "closeDescriptor":
      guard let handle = args["handle"] as? Int, let lease = leases.removeValue(forKey: handle) else {
        result(nil); return
      }
      // The Rust operation has completed before Dart releases this lease.
      Darwin.close(lease.fd)
      lease.finished.signal()
      result(nil)
    case "removeExport":
      guard let uri = args["uri"] as? String, let document = documents[uri], document.writable else {
        fail(result, "readonly", "只能清理本次创建的导出文件。"); return
      }
      guard let identity = document.createdIdentity else { result(nil); return }
      DispatchQueue.global(qos: .utility).async {
        let scoped = document.scope.startAccessingSecurityScopedResource()
        defer { if scoped { document.scope.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var removed = false
        NSFileCoordinator().coordinate(writingItemAt: document.url, options: .forDeleting, error: &error) { url in
          var info = stat()
          if lstat(url.path, &info) == 0 {
            if info.st_dev == identity.0 && info.st_ino == identity.1 { removed = unlink(url.path) == 0 }
          } else if errno == ENOENT { removed = true }
        }
        DispatchQueue.main.async {
          if error == nil && removed { result(nil) }
          else { self.fail(result, "cleanup", "无法清理未完成的导出，请在文件 App 中检查目标目录。") }
        }
      }
#if DEBUG && targetEnvironment(simulator)
    case "testRegisterDocument":
      let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("vhdx-validation", isDirectory: true).resolvingSymlinksInPath()
      guard let name = args["name"] as? String, !name.contains("/"), !name.contains("\0"),
            name != ".", name != ".." else { fail(result, "fixture", "Invalid fixture"); return }
      let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
      guard url.deletingLastPathComponent() == root else { fail(result, "fixture", "Invalid fixture"); return }
      result(remember([url]))
    case "testFixtureDirectory":
      result(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("vhdx-validation", isDirectory: true).path)
    case "testLeaseCount": result(leases.count)
#endif
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ uri: String, _ document: Document, _ write: Bool, _ result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let scoped = document.scope.startAccessingSecurityScopedResource()
      defer { if scoped { document.scope.stopAccessingSecurityScopedResource() } }
      var error: NSError?
      var accessed = false
      let accessor: (URL) -> Void = { url in
        accessed = true
        // O_EXCL prevents replacing an existing document, including the source image.
        let flags = write ? (O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW) : (O_RDONLY | O_CLOEXEC)
        let fd = Darwin.open(url.path, flags, mode_t(0o600))
        guard fd >= 0 else {
          DispatchQueue.main.async { self.fail(result, "open", write ? "无法新建导出文件，请选择可写目录并确保不存在同名文件。" : "无法读取文件，请确认外置磁盘已连接且文件已下载到本地。") }
          return
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
          Darwin.close(fd)
          DispatchQueue.main.async { self.fail(result, "seek", "所选文件不支持随机读取。") }
          return
        }
        let identity = (info.st_dev, info.st_ino)
        let lease = DocumentLease(fd)
        DispatchQueue.main.async {
          guard !self.detached else { Darwin.close(fd); lease.finished.signal(); return }
          let handle = self.nextHandle
          self.nextHandle += 1
          self.leases[handle] = lease
          if write { self.documents[uri]?.createdIdentity = identity }
          result(["fd": Int(fd), "handle": handle])
        }
        // Keep coordination open for the reader's lifetime, off the UI thread.
        lease.finished.wait()
      }
      let coordinator = NSFileCoordinator()
      if write { coordinator.coordinate(writingItemAt: document.url, options: [], error: &error, byAccessor: accessor) }
      else { coordinator.coordinate(readingItemAt: document.url, options: .withoutChanges, error: &error, byAccessor: accessor) }
      if !accessed {
        DispatchQueue.main.async { self.fail(result, "coordinate", "无法获得文件访问权限，请重新选择文件。") }
      }
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let selected = remember(urls, exportName: exportName)
    let callback = pickerResult
    pickerResult = nil; exportName = nil
    callback?(selected)
  }

  // Internal entry point also exercised by host-side XCTest with temporary files.
  func remember(_ urls: [URL], exportName name: String? = nil) -> [[String: String]] {
    return urls.map { scope -> [String: String] in
      let url = name.map { scope.appendingPathComponent($0, isDirectory: false) } ?? scope
      if name == nil, let previous = documents.first(where: {
        !$0.value.writable && $0.value.url.standardizedFileURL == url.standardizedFileURL
      }) {
        return ["uri": previous.key, "name": url.lastPathComponent]
      }
      let uri = "vhdx-document://" + UUID().uuidString
      documents[uri] = Document(url: url, scope: scope, writable: name != nil)
      return ["uri": uri, "name": url.lastPathComponent]
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callback = pickerResult
    pickerResult = nil; exportName = nil
    callback?([])
  }

  private func fail(_ result: FlutterResult, _ code: String, _ message: String) {
    result(FlutterError(code: code, message: message, details: nil))
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    detached = true
    if playbackUsers > 0 { PlaybackSession.release(playbackUsers); playbackUsers = 0 }
    pickerResult = nil
    documents.removeAll()
    guard let directory = Bundle.main.privateFrameworksPath,
          let library = dlopen(directory + "/vhdx_app.framework/vhdx_app", RTLD_NOW | RTLD_LOCAL),
          let watermarkSymbol = dlsym(library, "vhdx_context_watermark"),
          let retireSymbol = dlsym(library, "vhdx_retire_contexts_before") else { return }
    let watermark = unsafeBitCast(watermarkSymbol, to: (@convention(c) () -> UInt64).self)()
    let retire = unsafeBitCast(retireSymbol, to: (@convention(c) (UInt64) -> UInt8).self)
    DispatchQueue.global(qos: .utility).async {
      let completed = retire(watermark) != 0
      dlclose(library)
      DispatchQueue.main.async {
        // On timeout keep the scopes alive until process exit; never revoke a live read.
        if completed {
          for lease in self.leases.values { Darwin.close(lease.fd); lease.finished.signal() }
          self.leases.removeAll()
        }
      }
    }
  }

  deinit {
    for lease in leases.values { Darwin.close(lease.fd); lease.finished.signal() }
  }
}
