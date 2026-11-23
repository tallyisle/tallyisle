import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.contentMinSize = NSSize(width: 420, height: 600)
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    let preferredLanguage = (Locale.preferredLanguages.first ?? "").lowercased()
    self.title = preferredLanguage.hasPrefix("zh") ? "帐屿" : "TallyIsle"
  }
}
