import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    installVaultAuthentication()
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(origin: windowFrame.origin, size: NSSize(width: 1200, height: 800)), display: true)
    self.minSize = NSSize(width: 720, height: 540)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
