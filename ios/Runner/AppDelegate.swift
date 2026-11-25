import Flutter
import UIKit
import UniformTypeIdentifiers

private final class DocumentPickerDelegateBox: NSObject,
  UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  private let onPick: ([URL]) -> Void
  private let onCancel: () -> Void
  private let cleanupURL: URL?
  private let onComplete: (DocumentPickerDelegateBox) -> Void
  private var finished = false

  init(
    cleanupURL: URL? = nil,
    onPick: @escaping ([URL]) -> Void,
    onCancel: @escaping () -> Void,
    onComplete: @escaping (DocumentPickerDelegateBox) -> Void
  ) {
    self.cleanupURL = cleanupURL
    self.onPick = onPick
    self.onCancel = onCancel
    self.onComplete = onComplete
  }

  private func finish(_ action: () -> Void) {
    guard !finished else { return }
    finished = true
    action()
    if let cleanupURL = cleanupURL {
      try? FileManager.default.removeItem(at: cleanupURL)
    }
    onComplete(self)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    finish {
      if urls.isEmpty {
        onCancel()
      } else {
        onPick(urls)
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(onCancel)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(onCancel)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let fileChannelName = "dev.tallyisle/files"
  private var fileChannel: FlutterMethodChannel?
  private var activeDocumentPickers = Set<DocumentPickerDelegateBox>()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      if fileChannel == nil {
        registerFileChannel(messenger: controller.binaryMessenger)
      }
      AutomationBridge.shared.attach(messenger: controller.binaryMessenger)
    }
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerFileChannel(messenger: messenger)
    AutomationBridge.shared.attach(messenger: messenger)
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
      presentDocumentExportPicker(call: call, result: result)
    case "shareBytes":
      presentShareActivitySheet(call: call, result: result)
    case "openExternalUrl":
      openExternalUrl(call: call, result: result)
    case "pickBackupDirectory":
      presentBackupDirectoryPicker(result: result)
    case "checkDirectoryAccessible":
      checkDirectoryAccessible(call: call, result: result)
    case "listDirectoryBackups":
      listDirectoryBackups(call: call, result: result)
    case "writeDirectoryBackup":
      writeDirectoryBackup(call: call, result: result)
    case "readDirectoryBackup":
      readDirectoryBackup(call: call, result: result)
    case "deleteDirectoryBackup":
      deleteDirectoryBackup(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func openExternalUrl(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let rawUrl = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let url = URL(string: rawUrl),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      let host = url.host,
      !host.isEmpty
    else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: "仅支持打开 HTTP/HTTPS 网页链接",
          details: nil
        )
      )
      return
    }

    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { ok in
        if ok {
          result(nil)
        } else {
          result(
            FlutterError(
              code: "UNAVAILABLE",
              message: "无法调起系统浏览器",
              details: nil
            )
          )
        }
      }
    }
  }

  private func presentDocumentExportPicker(
    call: FlutterMethodCall,
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

    guard let data = Self.extractBytes(args["bytes"]) else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: "缺少待保存文件内容",
          details: nil
        )
      )
      return
    }

    let rawName = (args["suggestedName"] as? String) ?? (args["fileName"] as? String)
    let sanitizedName = Self.sanitizeFileName(rawName, fallback: "backup.tally")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let exportDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally_export_\(UUID().uuidString)", isDirectory: true)
      let fileURL = exportDir.appendingPathComponent(sanitizedName)
      do {
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
      } catch {
        try? FileManager.default.removeItem(at: exportDir)
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
        guard let strongSelf = self, let presenter = strongSelf.topPresentingViewController() else {
          try? FileManager.default.removeItem(at: exportDir)
          result(
            FlutterError(
              code: "UNAVAILABLE",
              message: "无法获取当前活动视图控制器",
              details: nil
            )
          )
          return
        }

        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
          picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        } else {
          picker = UIDocumentPickerViewController(url: fileURL, in: .exportToService)
        }

        let delegateBox = DocumentPickerDelegateBox(
          cleanupURL: exportDir,
          onPick: { _ in
            result(nil)
          },
          onCancel: {
            result(
              FlutterError(
                code: "CANCELLED",
                message: "已取消保存",
                details: nil
              )
            )
          },
          onComplete: { [weak self] box in
            self?.activeDocumentPickers.remove(box)
          }
        )
        strongSelf.activeDocumentPickers.insert(delegateBox)
        picker.delegate = delegateBox
        picker.presentationController?.delegate = delegateBox
        presenter.present(picker, animated: true, completion: nil)
      }
    }
  }

  private func presentBackupDirectoryPicker(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let strongSelf = self, let presenter = strongSelf.topPresentingViewController() else {
        result(
          FlutterError(
            code: "UNAVAILABLE",
            message: "无法获取当前活动视图控制器",
            details: nil
          )
        )
        return
      }

      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
      } else {
        picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
      }
      picker.allowsMultipleSelection = false

      let delegateBox = DocumentPickerDelegateBox(
        onPick: { urls in
          guard let folderURL = urls.first else {
            result(
              FlutterError(
                code: "CANCELLED",
                message: "已取消选择备份目录",
                details: nil
              )
            )
            return
          }
          let accessed = folderURL.startAccessingSecurityScopedResource()
          defer {
            if accessed {
              folderURL.stopAccessingSecurityScopedResource()
            }
          }
          do {
            let bookmarkData = try folderURL.bookmarkData(
              options: [],
              includingResourceValuesForKeys: nil,
              relativeTo: nil
            )
            let displayPath = Self.formatFolderDisplayPath(folderURL)
            result([
              "mode": "appleBookmark",
              "locator": bookmarkData.base64EncodedString(),
              "displayPath": displayPath,
            ])
          } catch {
            result(
              FlutterError(
                code: "IO_ERROR",
                message: "无法保存文件夹安全书签：\(error.localizedDescription)",
                details: nil
              )
            )
          }
        },
        onCancel: {
          result(
            FlutterError(
              code: "CANCELLED",
              message: "已取消选择备份目录",
              details: nil
            )
          )
        },
        onComplete: { [weak self] box in
          self?.activeDocumentPickers.remove(box)
        }
      )
      strongSelf.activeDocumentPickers.insert(delegateBox)
      picker.delegate = delegateBox
      picker.presentationController?.delegate = delegateBox
      presenter.present(picker, animated: true, completion: nil)
    }
  }

  private func checkDirectoryAccessible(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let locator = (args["locator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !locator.isEmpty
    else {
      result(false)
      return
    }
    let mode = (args["mode"] as? String) ?? "appleBookmark"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let accessible = try Self.withResolvedDirectory(mode: mode, locator: locator) { dirURL in
          var isDir: ObjCBool = false
          guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
            isDir.boolValue
          else {
            return false
          }
          _ = try FileManager.default.contentsOfDirectory(atPath: dirURL.path)
          return true
        }
        DispatchQueue.main.async { result(accessible) }
      } catch {
        DispatchQueue.main.async { result(false) }
      }
    }
  }

  private func listDirectoryBackups(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let locator = (args["locator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !locator.isEmpty
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "缺少目录定位标识", details: nil))
      return
    }
    let mode = (args["mode"] as? String) ?? "appleBookmark"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let entries = try Self.withResolvedDirectory(mode: mode, locator: locator) { dirURL in
          let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
          ]
          let urls = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
          )
          var items: [[String: Any]] = []
          for fileURL in urls {
            let name = fileURL.lastPathComponent
            if name.lowercased().hasSuffix(".tmp") { continue }
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            let modMs = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000.0)
            items.append([
              "fileName": name,
              "sizeBytes": size,
              "modifiedAtMs": modMs,
            ])
          }
          return items
        }
        DispatchQueue.main.async { result(entries) }
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
      }
    }
  }

  private func writeDirectoryBackup(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let locator = (args["locator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !locator.isEmpty,
      let data = Self.extractBytes(args["bytes"])
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "写入外部备份目录参数无效", details: nil))
      return
    }
    let safeName = Self.sanitizeFileName(args["fileName"] as? String, fallback: "")
    guard !safeName.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "非法的备份文件名", details: nil))
      return
    }
    let mode = (args["mode"] as? String) ?? "appleBookmark"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try Self.withResolvedDirectory(mode: mode, locator: locator) { dirURL in
          var isDir: ObjCBool = false
          guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
            isDir.boolValue
          else {
            throw NSError(
              domain: "TallyIsleFileBridge",
              code: 1,
              userInfo: [NSLocalizedDescriptionKey: "外部备份目录不存在或不可访问"]
            )
          }
          let targetURL = dirURL.appendingPathComponent(safeName)
          try data.write(to: targetURL, options: .atomic)
        }
        DispatchQueue.main.async { result(nil) }
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
      }
    }
  }

  private func readDirectoryBackup(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let locator = (args["locator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !locator.isEmpty
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "读取外部备份文件参数无效", details: nil))
      return
    }
    let safeName = Self.sanitizeFileName(args["fileName"] as? String, fallback: "")
    guard !safeName.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "非法的备份文件名", details: nil))
      return
    }
    let mode = (args["mode"] as? String) ?? "appleBookmark"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let bytes = try Self.withResolvedDirectory(mode: mode, locator: locator) { dirURL in
          let targetURL = dirURL.appendingPathComponent(safeName)
          return try Data(contentsOf: targetURL)
        }
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: bytes)) }
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
      }
    }
  }

  private func deleteDirectoryBackup(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let locator = (args["locator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !locator.isEmpty
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "删除外部备份文件参数无效", details: nil))
      return
    }
    let safeName = Self.sanitizeFileName(args["fileName"] as? String, fallback: "")
    guard !safeName.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "非法的备份文件名", details: nil))
      return
    }
    let mode = (args["mode"] as? String) ?? "appleBookmark"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try Self.withResolvedDirectory(mode: mode, locator: locator) { dirURL in
          let targetURL = dirURL.appendingPathComponent(safeName)
          if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
          }
        }
        DispatchQueue.main.async { result(nil) }
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
      }
    }
  }

  private static func withResolvedDirectory<T>(
    mode: String,
    locator: String,
    body: (URL) throws -> T
  ) throws -> T {
    if mode == "path" {
      return try body(URL(fileURLWithPath: locator, isDirectory: true))
    }
    guard let bookmarkData = Data(base64Encoded: locator) else {
      throw NSError(
        domain: "TallyIsleFileBridge",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "文件夹安全书签格式无效"]
      )
    }
    var isStale = false
    let dirURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    let accessed = dirURL.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        dirURL.stopAccessingSecurityScopedResource()
      }
    }
    return try body(dirURL)
  }

  private static func formatFolderDisplayPath(_ url: URL) -> String {
    let rawPath = url.path
    let folderName = url.lastPathComponent
    if rawPath.contains("com~apple~CloudDocs") {
      return folderName.isEmpty || folderName == "Documents"
        ? "iCloud 云盘"
        : "iCloud 云盘 / \(folderName)"
    }
    return folderName.isEmpty ? rawPath : "文件 / \(folderName)"
  }

  private static func extractBytes(_ raw: Any?) -> Data? {
    if let typed = raw as? FlutterStandardTypedData {
      return typed.data
    }
    if let data = raw as? Data {
      return data
    }
    return nil
  }

  private func presentShareActivitySheet(
    call: FlutterMethodCall,
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

    guard let data = Self.extractBytes(args["bytes"]) else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: "缺少待分享文件内容",
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
                message: "已取消分享",
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
