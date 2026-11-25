import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      AutomationBridge.shared.attachIfNeeded(messenger: controller.binaryMessenger)
    }
    if !connectionOptions.urlContexts.isEmpty {
      _ = AutomationBridge.shared.handleURLContexts(
        connectionOptions.urlContexts,
        notifyFlutter: false
      )
    }
    if let shortcutItem = connectionOptions.shortcutItem {
      _ = AutomationBridge.shared.handleShortcutItem(
        shortcutItem,
        notifyFlutter: false
      )
    }
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    let unhandled = AutomationBridge.shared.handleURLContexts(
      URLContexts,
      notifyFlutter: true
    )
    if !unhandled.isEmpty {
      super.scene(scene, openURLContexts: unhandled)
    }
  }

  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    if AutomationBridge.shared.handleShortcutItem(
      shortcutItem,
      notifyFlutter: true
    ) {
      completionHandler(true)
      return
    }
    super.windowScene(
      windowScene,
      performActionFor: shortcutItem,
      completionHandler: completionHandler
    )
  }
}
