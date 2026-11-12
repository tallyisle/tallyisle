import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let fileChannelName = "dev.tallyisle/files"
  private var fileChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if fileChannel == nil, let controller = window?.rootViewController as? FlutterViewController {
      registerFileChannel(messenger: controller.binaryMessenger)
    }
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerFileChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }

  private func registerFileChannel(messenger: FlutterBinaryMessenger) {
    fileChannel?.setMethodCallHandler(nil)
    let channel = FlutterMethodChannel(
      name: Self.fileChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleFileMethodCall(call, result: result)
    }
    fileChannel = channel
  }

  private func handleFileMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "saveBytes":
      presentActivitySheet(call: call, isSave: true, result: result)
    case "shareBytes":
      presentActivitySheet(call: call, isSave: false, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentActivitySheet(
    call: FlutterMethodCall,
    isSave: Bool,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: "参数格式无效",
          details: nil
        )
      )
      return
    }

    let data: Data
    if let typed = args["bytes"] as? FlutterStandardTypedData {
      data = typed.data
    } else if let raw = args["bytes"] as? Data {
      data = raw
    } else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: isSave ? "缺少待保存文件内容" : "缺少待分享文件内容",
          details: nil
        )
      )
      return
    }

    let rawName = (args["suggestedName"] as? String) ?? (args["fileName"] as? String)
    let sanitizedName = Self.sanitizeFileName(rawName, fallback: "backup.tally")
    let subject = (args["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedName)
      do {
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try? FileManager.default.removeItem(at: fileURL)
        }
        try data.write(to: fileURL, options: .atomic)
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "IO_ERROR",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
        return
      }

      DispatchQueue.main.async {
        guard let presenter = self?.topPresentingViewController() else {
          result(
            FlutterError(
              code: "UNAVAILABLE",
              message: "无法获取当前活动视图控制器",
              details: nil
            )
          )
          return
        }

        let activityVC = UIActivityViewController(
          activityItems: [fileURL],
          applicationActivities: nil
        )
        if let subject = subject, !subject.isEmpty {
          activityVC.setValue(subject, forKey: "subject")
        }
        if let popover = activityVC.popoverPresentationController {
          let hostView = presenter.view ?? UIView()
          popover.sourceView = hostView
          popover.sourceRect = CGRect(
            x: hostView.bounds.midX,
            y: hostView.bounds.midY,
            width: 1,
            height: 1
          )
          popover.permittedArrowDirections = []
        }

        var completedOnce = false
        activityVC.completionWithItemsHandler = { _, completed, _, activityError in
          guard !completedOnce else { return }
          completedOnce = true
          if let activityError = activityError {
            result(
              FlutterError(
                code: "IO_ERROR",
                message: activityError.localizedDescription,
                details: nil
              )
            )
            return
          }
          if completed {
            result(nil)
          } else {
            result(
              FlutterError(
                code: "CANCELLED",
                message: isSave ? "已取消保存" : "已取消分享",
                details: nil
              )
            )
          }
        }

        presenter.present(activityVC, animated: true, completion: nil)
      }
    }
  }

  private func topPresentingViewController() -> UIViewController? {
    let windowScenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .sorted { lhs, rhs in
        Self.scenePriority(lhs.activationState) < Self.scenePriority(rhs.activationState)
      }

    var activeWindow: UIWindow?
    for scene in windowScenes {
      if let match = scene.windows.first(where: { $0.isKeyWindow })
        ?? scene.windows.first(where: { !$0.isHidden })
      {
        activeWindow = match
        break
      }
    }
    if activeWindow == nil {
      activeWindow = window
    }

    guard var top = activeWindow?.rootViewController else {
      return nil
    }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  private static func scenePriority(_ state: UIScene.ActivationState) -> Int {
    switch state {
    case .foregroundActive:
      return 0
    case .foregroundInactive:
      return 1
    case .background:
      return 2
    case .unattached:
      return 3
    @unknown default:
      return 4
    }
  }

  private static func sanitizeFileName(_ raw: String?, fallback: String) -> String {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return fallback
    }
    let forbidden = CharacterSet(charactersIn: "/\\:\0")
    let cleaned = trimmed.components(separatedBy: forbidden).joined(separator: "_")
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
      return fallback
    }
    return cleaned
  }
}
