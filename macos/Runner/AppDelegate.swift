import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var fileChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.tallyisle/files",
        binaryMessenger: controller.engine.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleFileMethodCall(call, result: result)
      }
      self.fileChannel = channel
    }
    super.applicationDidFinishLaunching(notification)
  }

  private func handleFileMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "openExternalUrl":
      handleOpenExternalUrl(call: call, result: result)
    case "pickBackupDirectory":
      handlePickBackupDirectory(call: call, result: result)
    case "checkDirectoryAccessible":
      handleCheckDirectoryAccessible(call: call, result: result)
    case "listDirectoryBackups":
      handleListDirectoryBackups(call: call, result: result)
    case "writeDirectoryBackup":
      handleWriteDirectoryBackup(call: call, result: result)
    case "readDirectoryBackup":
      handleReadDirectoryBackup(call: call, result: result)
    case "deleteDirectoryBackup":
      handleDeleteDirectoryBackup(call: call, result: result)
    case "openBackupDirectory":
      handleOpenBackupDirectory(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleOpenExternalUrl(call: FlutterMethodCall, result: @escaping FlutterResult) {
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
  }

  private func handlePickBackupDirectory(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let initialDir = (args?["initialDirectory"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    DispatchQueue.main.async { [weak self] in
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      panel.prompt = "选择此备份文件夹"
      panel.message = "选择用于保存帐屿 (.tally) 备份文件的外部文件夹"
      if let initialDir = initialDir, !initialDir.isEmpty {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: initialDir, isDirectory: &isDir), isDir.boolValue {
          panel.directoryURL = URL(fileURLWithPath: initialDir, isDirectory: true)
        }
      }

      let completion: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let folderURL = panel.url else {
          result(
            FlutterError(
              code: "CANCELLED",
              message: "已取消选择备份目录",
              details: nil
            )
          )
          return
        }
        do {
          let bookmarkData = try folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          result([
            "mode": "appleBookmark",
            "locator": bookmarkData.base64EncodedString(),
            "displayPath": folderURL.path,
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
      }

      if let window = self?.mainFlutterWindow {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        panel.begin(completionHandler: completion)
      }
    }
  }

  private func handleCheckDirectoryAccessible(
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

  private func handleListDirectoryBackups(
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

  private func handleWriteDirectoryBackup(
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

  private func handleReadDirectoryBackup(
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

  private func handleDeleteDirectoryBackup(
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

  private func handleOpenBackupDirectory(
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
    DispatchQueue.main.async {
      do {
        let opened = try Self.withResolvedDirectory(mode: mode, locator: locator) { dirURL in
          var isDir: ObjCBool = false
          guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
            isDir.boolValue
          else {
            return false
          }
          return NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dirURL.path)
        }
        if opened {
          result(nil)
        } else {
          result(
            FlutterError(
              code: "OPEN_FAILED",
              message: "无法在访达中打开备份目录",
              details: nil
            )
          )
        }
      } catch {
        result(
          FlutterError(
            code: "OPEN_FAILED",
            message: error.localizedDescription,
            details: nil
          )
        )
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
      options: [.withSecurityScope, .withoutUI],
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

  private static func extractBytes(_ raw: Any?) -> Data? {
    if let typed = raw as? FlutterStandardTypedData {
      return typed.data
    }
    if let data = raw as? Data {
      return data
    }
    return nil
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

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
