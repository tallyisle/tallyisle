#if canImport(AppIntents)
import AppIntents
import Foundation
import UserNotifications

/// Opens TallyIsle and feeds bill or screenshot OCR text into the Smart Bill confirmation flow.
@available(iOS 16.0, *)
struct SmartConfirmBillIntent: AppIntent {
  static var title: LocalizedStringResource = "智能识别账单（打开核对）"
  static var description = IntentDescription("打开帐屿并识别传入的账单或截屏文字，进入快捷核对入账面板。")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "账单或截屏文字", default: "")
  var billText: String

  init() {}

  init(billText: String) {
    self.billText = billText
  }

  func perform() async throws -> some IntentResult {
    let trimmed = billText.trimmingCharacters(in: .whitespacesAndNewlines)
    let nowMs = AutomationBridge.currentTimeMillis()
    await MainActor.run {
      if trimmed.isEmpty {
        AutomationBridge.shared.enqueueSharedPayload([
          "kind": "shortcut",
          "shortcutAction": "smart_bill",
          "source": "shortcut",
          "receivedAtMs": nowMs,
        ])
      } else {
        AutomationBridge.shared.enqueueSharedPayload([
          "kind": "text",
          "text": trimmed,
          "source": "shortcut",
          "receivedAtMs": nowMs,
        ])
      }
    }
    return .result()
  }
}

/// Silently queues bill or SMS text into TallyIsle's pending drafts inbox without opening the app.
@available(iOS 16.0, *)
struct SilentQueueBillIntent: AppIntent {
  static var title: LocalizedStringResource = "静默记入草稿箱（后台免打扰）"
  static var description = IntentDescription("在后台将账单或短信文字暂存至帐屿待确认草稿箱，无需跳转打开应用。")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "账单或短信文字")
  var billText: String

  init() {}

  init(billText: String) {
    self.billText = billText
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let trimmed = billText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .result(dialog: IntentDialog("未检测到有效账单文字"))
    }

    let nowMs = AutomationBridge.currentTimeMillis()
    AutomationBridge.shared.enqueueCapturedEvent(
      packageName: "Shortcuts",
      rawText: trimmed,
      capturedAtMs: nowMs,
      channel: "app_intent"
    )

    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .authorized
      || settings.authorizationStatus == .provisional
    {
      let content = UNMutableNotificationContent()
      content.title = "帐屿已收到待确认账单"
      content.body = String(trimmed.prefix(80))
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "tallyisle.appintent.\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      try? await center.add(request)
    }

    return .result(dialog: IntentDialog("已加入帐屿待确认草稿箱"))
  }
}

/// Opens TallyIsle directly onto the New Record editor.
@available(iOS 16.0, *)
struct QuickOpenRecordIntent: AppIntent {
  static var title: LocalizedStringResource = "打开帐屿记一笔"
  static var description = IntentDescription("快速打开帐屿并进入记一笔界面。")
  static var openAppWhenRun: Bool = true

  init() {}

  func perform() async throws -> some IntentResult {
    let nowMs = AutomationBridge.currentTimeMillis()
    await MainActor.run {
      AutomationBridge.shared.enqueueSharedPayload([
        "kind": "shortcut",
        "shortcutAction": "new_record",
        "source": "shortcut",
        "receivedAtMs": nowMs,
      ])
    }
    return .result()
  }
}

/// Exposes discoverable TallyIsle presets to Apple Shortcuts, Spotlight, and Siri.
@available(iOS 16.0, *)
struct TallyAppShortcutsProvider: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: QuickOpenRecordIntent(),
      phrases: [
        "用\(.applicationName)记一笔",
        "打开\(.applicationName)记账",
        "Record with \(.applicationName)",
      ],
      shortTitle: "记一笔",
      systemImageName: "plus.circle"
    )
    AppShortcut(
      intent: SmartConfirmBillIntent(),
      phrases: [
        "用\(.applicationName)智能识账",
        "用\(.applicationName)识别账单",
        "Smart bill in \(.applicationName)",
      ],
      shortTitle: "智能识账",
      systemImageName: "sparkles"
    )
    AppShortcut(
      intent: SilentQueueBillIntent(),
      phrases: [
        "用\(.applicationName)静默记账",
        "用\(.applicationName)加入草稿箱",
        "Queue bill in \(.applicationName)",
      ],
      shortTitle: "静默入草稿",
      systemImageName: "tray.and.arrow.down"
    )
  }
}
#endif
