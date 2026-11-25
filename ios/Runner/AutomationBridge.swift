import Flutter
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision

/// Unified iOS native MethodChannel bridge (`dev.tallyisle/automation`) for:
///  - `tallyisle://` cold & warm external deep links
///  - Open-In image/text files, Home Screen quick actions, and foreground AppIntents payloads
///  - Background AppIntents captured-event inbox persisted in `UserDefaults.standard`
///  - Offline image text recognition powered by Apple `Vision` (`VNRecognizeTextRequest`)
///
/// Runs entirely inside `Runner.app` with zero App Group entitlements or extension targets
/// so unsigned IPA sideloading (free Apple ID / TrollStore) works out of the box.
final class AutomationBridge: NSObject {
  static let shared = AutomationBridge()

  static let channelName = "dev.tallyisle/automation"
  static let capturedEventsDefaultsKey = "tallyisle_ios_captured_events"
  private static let statusUnsupportedLabel = "当前平台不支持"
  private static let maxStoredCapturedEvents = 100
  private static let maxQueuedSharedPayloads = 50
  private static let maxOpenInTextBytes = 65_536

  private static let supportedImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff",
  ]
  private static let supportedPlainTextExtensions: Set<String> = [
    "txt", "text",
  ]
  private static let shortcutTypeToAction: [String: String] = [
    "dev.tallyisle.shortcut.new_record": "new_record",
    "dev.tallyisle.shortcut.smart_bill": "smart_bill",
    "dev.tallyisle.shortcut.ocr_bill": "ocr_bill",
    "dev.tallyisle.shortcut.drafts": "drafts",
  ]

  private struct QueuedSharedPayload {
    let id: UUID
    let map: [String: Any]
  }

  private let stateLock = NSLock()
  private let capturedEventsLock = NSLock()

  private var channel: FlutterMethodChannel?
  private var pendingDeepLinkUri: String?
  private var pendingSharedPayloads: [QueuedSharedPayload] = []

  private override init() {
    super.init()
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let bind = {
      self.channel?.setMethodCallHandler(nil)
      let mc = FlutterMethodChannel(
        name: Self.channelName,
        binaryMessenger: messenger
      )
      mc.setMethodCallHandler { [weak self] call, result in
        self?.handleMethodCall(call, result: result)
      }
      self.channel = mc
    }
    if Thread.isMainThread {
      bind()
    } else {
      DispatchQueue.main.async(execute: bind)
    }
  }

  func attachIfNeeded(messenger: FlutterBinaryMessenger) {
    let bindIfNeeded = {
      if self.channel == nil {
        self.attach(messenger: messenger)
      }
    }
    if Thread.isMainThread {
      bindIfNeeded()
    } else {
      DispatchQueue.main.async(execute: bindIfNeeded)
    }
  }

  // MARK: - Scene / App Entry Points

  /// Processes incoming `UIOpenURLContext`s (`tallyisle://` deep links and Open-In image/text
  /// files) and returns any contexts that were not handled so `SceneDelegate` can forward them.
  @discardableResult
  func handleURLContexts(
    _ contexts: Set<UIOpenURLContext>,
    notifyFlutter: Bool = true
  ) -> Set<UIOpenURLContext> {
    var unhandled = Set<UIOpenURLContext>()
    var copiedImagePaths: [String] = []

    for context in contexts {
      let url = context.url
      if handleIncomingDeepLink(url, notifyFlutter: notifyFlutter) {
        continue
      }
      if url.isFileURL {
        switch inspectAndImportFileURL(url) {
        case .image(let tempPath):
          copiedImagePaths.append(tempPath)
          continue
        case .text(let content):
          enqueueSharedPayload(
            [
              "kind": "text",
              "text": content,
              "source": "open_in",
              "receivedAtMs": Self.currentTimeMillis(),
            ],
            notifyFlutter: notifyFlutter
          )
          continue
        case .unhandled:
          break
        }
      }
      unhandled.insert(context)
    }

    if !copiedImagePaths.isEmpty {
      enqueueSharedPayload(
        [
          "kind": "image",
          "imagePaths": copiedImagePaths,
          "source": "open_in",
          "receivedAtMs": Self.currentTimeMillis(),
        ],
        notifyFlutter: notifyFlutter
      )
    }

    return unhandled
  }

  /// Captures a `tallyisle://` URL (case-insensitive scheme), ignoring internal reminder routes
  /// (`reminder`, `reminder-open`) and rejecting legacy `yyjz://` links.
  @discardableResult
  func handleIncomingDeepLink(_ url: URL, notifyFlutter: Bool = true) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "tallyisle" else {
      return false
    }
    let host = url.host?.lowercased() ?? ""
    if host == "reminder" || host == "reminder-open" {
      return false
    }
    let uriText = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uriText.isEmpty else {
      return false
    }

    stateLock.lock()
    pendingDeepLinkUri = uriText
    stateLock.unlock()

    if notifyFlutter {
      DispatchQueue.main.async { [weak self] in
        guard let self = self, let activeChannel = self.channel else { return }
        self.stateLock.lock()
        let stillPending = (self.pendingDeepLinkUri == uriText)
        self.stateLock.unlock()
        guard stillPending else { return }

        activeChannel.invokeMethod("onDeepLink", arguments: uriText) { [weak self] response in
          guard let self = self else { return }
          if (response as? Bool) == true {
            self.stateLock.lock()
            if self.pendingDeepLinkUri == uriText {
              self.pendingDeepLinkUri = nil
            }
            self.stateLock.unlock()
          }
        }
      }
    }
    return true
  }

  /// Handles a Home Screen Quick Action (`UIApplicationShortcutItem`).
  @discardableResult
  func handleShortcutItem(
    _ shortcutItem: UIApplicationShortcutItem,
    notifyFlutter: Bool = true
  ) -> Bool {
    guard let action = Self.shortcutTypeToAction[shortcutItem.type] else {
      return false
    }
    enqueueSharedPayload(
      [
        "kind": "shortcut",
        "shortcutAction": action,
        "source": "shortcut",
        "receivedAtMs": Self.currentTimeMillis(),
      ],
      notifyFlutter: notifyFlutter
    )
    return true
  }

  // MARK: - Shared Payloads & Captured Events

  /// Enqueues a shared/shortcut/AppIntent foreground payload and pushes live to Flutter when ready.
  func enqueueSharedPayload(
    _ payload: [String: Any],
    notifyFlutter: Bool = true
  ) {
    let entry = QueuedSharedPayload(id: UUID(), map: payload)

    stateLock.lock()
    pendingSharedPayloads.append(entry)
    if pendingSharedPayloads.count > Self.maxQueuedSharedPayloads {
      pendingSharedPayloads.removeFirst(pendingSharedPayloads.count - Self.maxQueuedSharedPayloads)
    }
    stateLock.unlock()

    guard notifyFlutter else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, let activeChannel = self.channel else { return }

      self.stateLock.lock()
      guard let index = self.pendingSharedPayloads.firstIndex(where: { $0.id == entry.id }) else {
        self.stateLock.unlock()
        return
      }
      let removed = self.pendingSharedPayloads.remove(at: index)
      self.stateLock.unlock()

      activeChannel.invokeMethod("onSharedPayload", arguments: removed.map) { [weak self] response in
        guard let self = self else { return }
        if (response as? Bool) != true {
          self.stateLock.lock()
          self.pendingSharedPayloads.append(removed)
          if self.pendingSharedPayloads.count > Self.maxQueuedSharedPayloads {
            self.pendingSharedPayloads.removeFirst(
              self.pendingSharedPayloads.count - Self.maxQueuedSharedPayloads
            )
          }
          self.stateLock.unlock()
        }
      }
    }
  }

  /// Persists a captured bill event (e.g. from background `SilentQueueBillIntent`) into
  /// `UserDefaults.standard` synchronously before optionally attempting live delivery to Flutter.
  func enqueueCapturedEvent(
    packageName: String,
    rawText: String,
    capturedAtMs: Int64 = AutomationBridge.currentTimeMillis(),
    channel sourceChannel: String = "app_intent",
    notifyFlutter: Bool = true
  ) {
    let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }

    let trimmedPackage = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
    let eventMap: [String: Any] = [
      "packageName": trimmedPackage.isEmpty ? "Shortcuts" : trimmedPackage,
      "rawText": trimmedText,
      "capturedAtMs": capturedAtMs,
      "channel": sourceChannel,
    ]

    capturedEventsLock.lock()
    appendCapturedEventLocked(eventMap)
    capturedEventsLock.unlock()

    guard notifyFlutter else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, let activeChannel = self.channel else { return }

      self.capturedEventsLock.lock()
      let popped = self.removeMatchingCapturedEventLocked(eventMap)
      self.capturedEventsLock.unlock()
      guard popped else { return }

      activeChannel.invokeMethod("onCapturedEvent", arguments: eventMap) { [weak self] response in
        guard let self = self else { return }
        if (response as? Bool) != true {
          self.capturedEventsLock.lock()
          self.appendCapturedEventLocked(eventMap)
          self.capturedEventsLock.unlock()
        }
      }
    }
  }

  /// Dispatches a prompt action callback to Flutter if ever invoked natively.
  func dispatchPromptAction(_ action: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onPromptAction", arguments: action)
    }
  }

  // MARK: - MethodChannel Handler (16 Canonical Methods)

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "consumePendingDeepLink":
      stateLock.lock()
      let uri = pendingDeepLinkUri
      pendingDeepLinkUri = nil
      stateLock.unlock()
      result(uri)

    case "getAccessibilityStatus",
      "getNotificationListenerStatus",
      "getOverlayPermissionStatus":
      result([
        "supported": false,
        "enabled": false,
        "statusLabel": Self.statusUnsupportedLabel,
      ])

    case "openAccessibilitySettings",
      "openNotificationListenerSettings",
      "openOverlaySettings",
      "syncAndroidAutoBillConfig",
      "showAutoBillPrompt",
      "requestPinWidget":
      result(false)

    case "updateWidgetSnapshot",
      "getActiveWidgetCounts":
      result([
        "quick_add": 0,
        "month_summary": 0,
        "month_bar": 0,
        "smart_quick": 0,
      ])

    case "consumeCapturedEvents":
      capturedEventsLock.lock()
      let events = loadCapturedEventsLocked()
      if !events.isEmpty {
        UserDefaults.standard.removeObject(forKey: Self.capturedEventsDefaultsKey)
      }
      capturedEventsLock.unlock()
      result(events)

    case "consumePendingSharedPayloads":
      stateLock.lock()
      let payloads = pendingSharedPayloads.map { $0.map }
      pendingSharedPayloads.removeAll()
      stateLock.unlock()
      result(payloads)

    case "consumePendingPromptActions":
      result([[String: Any]]())

    case "recognizeImageOffline":
      recognizeImageOffline(call: call, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Offline Vision OCR

  private func recognizeImageOffline(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let data = Self.extractBytes(args["bytes"]),
      !data.isEmpty
    else {
      result(
        FlutterError(
          code: "OCR_FAILED",
          message: "缺少待识别的图片数据",
          details: nil
        )
      )
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      guard let image = UIImage(data: data) else {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "OCR_FAILED",
              message: "无法解析图片内容",
              details: nil
            )
          )
        }
        return
      }

      let cgOrientation = Self.cgImageOrientation(from: image.imageOrientation)
      let handler: VNImageRequestHandler
      if let cgImage = image.cgImage {
        handler = VNImageRequestHandler(
          cgImage: cgImage,
          orientation: cgOrientation,
          options: [:]
        )
      } else if let ciImage = image.ciImage {
        handler = VNImageRequestHandler(
          ciImage: ciImage,
          orientation: cgOrientation,
          options: [:]
        )
      } else {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "OCR_FAILED",
              message: "图片格式不受支持",
              details: nil
            )
          )
        }
        return
      }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
      request.usesLanguageCorrection = true

      do {
        try handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        let lines = observations
          .compactMap {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
          }
          .filter { !$0.isEmpty }
        let recognizedText = lines.joined(separator: "\n")
        DispatchQueue.main.async {
          result([
            "supported": true,
            "text": recognizedText,
          ])
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "OCR_FAILED",
              message: "离线识图失败：\(error.localizedDescription)",
              details: nil
            )
          )
        }
      }
    }
  }

  // MARK: - Open-In File Helpers

  private enum ImportedFileResult {
    case image(String)
    case text(String)
    case unhandled
  }

  private func inspectAndImportFileURL(_ url: URL) -> ImportedFileResult {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let rawExt = url.pathExtension.lowercased()
    let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    let extType = rawExt.isEmpty ? nil : UTType(filenameExtension: rawExt)
    let resolvedType = resourceType ?? extType

    let isImage =
      (resolvedType?.conforms(to: .image) == true)
      || Self.supportedImageExtensions.contains(rawExt)
    if isImage {
      let safeExt = Self.sanitizeExtension(rawExt, fallback: "jpg")
      let destURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally_shared_\(UUID().uuidString).\(safeExt)")
      do {
        try FileManager.default.copyItem(at: url, to: destURL)
        return .image(destURL.path)
      } catch {
        if let data = try? Data(contentsOf: url), !data.isEmpty {
          do {
            try data.write(to: destURL, options: .atomic)
            return .image(destURL.path)
          } catch {
            return .unhandled
          }
        }
        return .unhandled
      }
    }

    let isPlainText =
      (resolvedType == .plainText || resolvedType == .utf8PlainText)
      || Self.supportedPlainTextExtensions.contains(rawExt)
    if isPlainText {
      guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        return .unhandled
      }
      let bounded = data.count > Self.maxOpenInTextBytes
        ? data.prefix(Self.maxOpenInTextBytes)
        : data
      if let text = String(data: bounded, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      {
        return .text(text)
      }
    }

    return .unhandled
  }

  // MARK: - UserDefaults Captured Events Storage

  private func loadCapturedEventsLocked() -> [[String: Any]] {
    guard
      let raw = UserDefaults.standard.array(forKey: Self.capturedEventsDefaultsKey)
        as? [[String: Any]]
    else {
      return []
    }
    return raw
  }

  private func appendCapturedEventLocked(_ eventMap: [String: Any]) {
    var items = loadCapturedEventsLocked()
    items.append(eventMap)
    if items.count > Self.maxStoredCapturedEvents {
      items.removeFirst(items.count - Self.maxStoredCapturedEvents)
    }
    UserDefaults.standard.set(items, forKey: Self.capturedEventsDefaultsKey)
  }

  private func removeMatchingCapturedEventLocked(_ target: [String: Any]) -> Bool {
    var items = loadCapturedEventsLocked()
    let targetPkg = target["packageName"] as? String
    let targetText = target["rawText"] as? String
    let targetTs = (target["capturedAtMs"] as? NSNumber)?.int64Value
    let targetChannel = target["channel"] as? String

    guard
      let idx = items.firstIndex(where: { item in
        (item["packageName"] as? String) == targetPkg
          && (item["rawText"] as? String) == targetText
          && ((item["capturedAtMs"] as? NSNumber)?.int64Value) == targetTs
          && (item["channel"] as? String) == targetChannel
      })
    else {
      return false
    }

    items.remove(at: idx)
    if items.isEmpty {
      UserDefaults.standard.removeObject(forKey: Self.capturedEventsDefaultsKey)
    } else {
      UserDefaults.standard.set(items, forKey: Self.capturedEventsDefaultsKey)
    }
    return true
  }

  // MARK: - Utility Helpers

  static func currentTimeMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
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

  private static func sanitizeExtension(_ raw: String, fallback: String) -> String {
    let filtered = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    if filtered.isEmpty || filtered.count > 8 {
      return fallback
    }
    return filtered
  }

  private static func cgImageOrientation(
    from orientation: UIImage.Orientation
  ) -> CGImagePropertyOrientation {
    switch orientation {
    case .up:
      return .up
    case .down:
      return .down
    case .left:
      return .left
    case .right:
      return .right
    case .upMirrored:
      return .upMirrored
    case .downMirrored:
      return .downMirrored
    case .leftMirrored:
      return .leftMirrored
    case .rightMirrored:
      return .rightMirrored
    @unknown default:
      return .up
    }
  }
}
