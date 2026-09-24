import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Enforce a minimum window size so screens never overflow their layout
    // (mirrors the 1024x720 minimum in linux/runner/my_application.cc).
    self.contentMinSize = NSSize(width: 1024, height: 720)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Touch ID vault unlock — a Runner-side channel rather than a plugin, so
    // the desktop build stays free of CocoaPods (see TouchIdVaultKey.swift).
    TouchIdVaultKey.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
