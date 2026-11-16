import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var fileChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "dev.tallyisle/files",
        binaryMessenger: controller.engine.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "openExternalUrl":
          guard
            let args = call.arguments as? [String: Any],
            let rawUrl = args["url"] as? String,
            let url = URL(string: rawUrl),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
          else {
            result(
              FlutterError(
                code: "INVALID_URL",
                message: "仅支持打开 HTTP/HTTPS 网页链接",
                details: nil
              )
            )
            return
          }
          if NSWorkspace.shared.open(url) {
            result(nil)
          } else {
            result(
              FlutterError(
                code: "OPEN_FAILED",
                message: "无法调起系统浏览器",
                details: nil
              )
            )
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      self.fileChannel = channel
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
