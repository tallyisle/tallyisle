import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let minContentWidth: CGFloat = 420
  private static let minContentHeight: CGFloat = 600
  private static let defaultContentWidth: CGFloat = 1280
  private static let defaultContentHeight: CGFloat = 800
  private static let minTitleBarVisibleWidth: CGFloat = 120
  private static let minTitleBarVisibleHeight: CGFloat = 32

  private static let keyHasSavedFrame = "dev.tallyisle.windowState.hasSavedFrame"
  private static let keyFrameX = "dev.tallyisle.windowState.x"
  private static let keyFrameY = "dev.tallyisle.windowState.y"
  private static let keyFrameWidth = "dev.tallyisle.windowState.width"
  private static let keyFrameHeight = "dev.tallyisle.windowState.height"
  private static let keyIsZoomed = "dev.tallyisle.windowState.isZoomed"
  private static let keyIsFullScreen = "dev.tallyisle.windowState.isFullScreen"

  private var lastNormalFrame: NSRect = .zero
  private var isZoomedState: Bool = false
  private var isFullScreenState: Bool = false
  private var isTransitioningFullScreen: Bool = false
  private var fullScreenTransitionGeneration: Int = 0
  private var observerTokens: [NSObjectProtocol] = []

  deinit {
    for token in observerTokens {
      NotificationCenter.default.removeObserver(token)
    }
  }

  override func awakeFromNib() {
    self.isRestorable = false
    self.restorationClass = nil

    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.contentMinSize = NSSize(
      width: Self.minContentWidth,
      height: Self.minContentHeight
    )

    restoreSavedWindowGeometry()
    registerWindowStateObservers()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    let preferredLanguage = (Locale.preferredLanguages.first ?? "").lowercased()
    self.title = preferredLanguage.hasPrefix("zh") ? "帐屿" : "TallyIsle"
  }

  private func restoreSavedWindowGeometry() {
    let defaults = UserDefaults.standard
    let hasSavedFrame = defaults.bool(forKey: Self.keyHasSavedFrame)

    if hasSavedFrame {
      let rawX = CGFloat(defaults.double(forKey: Self.keyFrameX))
      let rawY = CGFloat(defaults.double(forKey: Self.keyFrameY))
      let rawWidth = CGFloat(defaults.double(forKey: Self.keyFrameWidth))
      let rawHeight = CGFloat(defaults.double(forKey: Self.keyFrameHeight))
      let savedZoomed = defaults.bool(forKey: Self.keyIsZoomed)
      let savedFullScreen = defaults.bool(forKey: Self.keyIsFullScreen)

      if rawWidth.isFinite && rawHeight.isFinite && rawX.isFinite && rawY.isFinite &&
        rawWidth > 0 && rawHeight > 0
      {
        let rawFrame = NSRect(x: rawX, y: rawY, width: rawWidth, height: rawHeight)
        let clampedFrame = clampFrameToScreens(rawFrame)
        self.setFrame(clampedFrame, display: false)
        self.lastNormalFrame = clampedFrame
        self.isZoomedState = savedZoomed && !savedFullScreen
        self.isFullScreenState = savedFullScreen

        if savedFullScreen {
          self.beginFullScreenTransition()
          DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.styleMask.contains(.fullScreen) {
              self.toggleFullScreen(nil)
            } else {
              self.fullScreenTransitionGeneration &+= 1
              self.isTransitioningFullScreen = false
            }
          }
        } else if savedZoomed && !self.isZoomed {
          self.zoom(nil)
        }
        return
      }
    }

    var defaultContent = NSSize(
      width: Self.defaultContentWidth,
      height: Self.defaultContentHeight
    )
    if let mainScreen = NSScreen.main ?? NSScreen.screens.first {
      let maxContent = self.contentRect(forFrameRect: mainScreen.visibleFrame).size
      defaultContent.width = max(
        Self.minContentWidth,
        min(defaultContent.width, maxContent.width)
      )
      defaultContent.height = max(
        Self.minContentHeight,
        min(defaultContent.height, maxContent.height)
      )
    }
    self.setContentSize(defaultContent)
    self.center()
    let clampedDefault = clampFrameToScreens(self.frame)
    if clampedDefault != self.frame {
      self.setFrame(clampedDefault, display: false)
    }
    self.lastNormalFrame = self.frame
    self.isZoomedState = false
    self.isFullScreenState = false
  }

  private func clampFrameToScreens(_ candidate: NSRect) -> NSRect {
    let minFrameSize = self.frameRect(
      forContentRect: NSRect(
        origin: .zero,
        size: NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
      )
    ).size

    var frame = candidate
    frame.size.width = max(frame.size.width, minFrameSize.width)
    frame.size.height = max(frame.size.height, minFrameSize.height)

    let screens = NSScreen.screens
    guard !screens.isEmpty else {
      return frame
    }

    var bestScreen: NSScreen?
    var bestArea: CGFloat = 0
    var nearestScreen: NSScreen?
    var nearestDistSq = CGFloat.greatestFiniteMagnitude
    var anyTitleBarVisible = false

    let minDragWidth = min(frame.width, Self.minTitleBarVisibleWidth)
    let minDragHeight = min(frame.height, Self.minTitleBarVisibleHeight)
    let titleBarRect = NSRect(
      x: frame.minX,
      y: frame.maxY - minDragHeight,
      width: frame.width,
      height: minDragHeight
    )

    for screen in screens {
      let visible = screen.visibleFrame
      let intersection = frame.intersection(visible)
      if !intersection.isNull && intersection.width > 0 && intersection.height > 0 {
        let area = intersection.width * intersection.height
        if area > bestArea {
          bestArea = area
          bestScreen = screen
        }
      }

      let titleIntersection = titleBarRect.intersection(visible)
      if !titleIntersection.isNull &&
        frame.maxY <= visible.maxY &&
        titleIntersection.width >= minDragWidth &&
        titleIntersection.height >= minDragHeight
      {
        anyTitleBarVisible = true
      }

      let dx = frame.midX - visible.midX
      let dy = frame.midY - visible.midY
      let distSq = dx * dx + dy * dy
      if distSq < nearestDistSq {
        nearestDistSq = distSq
        nearestScreen = screen
      }
    }

    let targetScreen = bestScreen ?? nearestScreen ?? NSScreen.main ?? screens[0]
    let visibleFrame = targetScreen.visibleFrame

    if visibleFrame.width > 0 && frame.width > visibleFrame.width {
      frame.size.width = visibleFrame.width >= minFrameSize.width
        ? visibleFrame.width
        : minFrameSize.width
    }
    if visibleFrame.height > 0 && frame.height > visibleFrame.height {
      frame.size.height = visibleFrame.height >= minFrameSize.height
        ? visibleFrame.height
        : minFrameSize.height
    }

    let clampedDragWidth = min(frame.width, Self.minTitleBarVisibleWidth)
    let clampedDragHeight = min(frame.height, Self.minTitleBarVisibleHeight)

    if !anyTitleBarVisible {
      let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
      let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
      frame.origin.x = max(visibleFrame.minX, min(frame.origin.x, maxX))
      frame.origin.y = max(visibleFrame.minY, min(frame.origin.y, maxY))
    } else {
      frame.origin.x = max(
        visibleFrame.minX + clampedDragWidth - frame.width,
        min(frame.origin.x, visibleFrame.maxX - clampedDragWidth)
      )
      frame.origin.y = max(
        visibleFrame.minY + clampedDragHeight - frame.height,
        min(frame.origin.y, visibleFrame.maxY - frame.height)
      )
    }

    if frame.maxY > visibleFrame.maxY {
      frame.origin.y = visibleFrame.maxY - frame.height
    }
    return frame
  }

  private func registerWindowStateObservers() {
    let center = NotificationCenter.default

    let windowEvents: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didMoveNotification,
    ]
    for name in windowEvents {
      observerTokens.append(
        center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
          self?.captureAndPersistWindowState()
        }
      )
    }

    observerTokens.append(
      center.addObserver(
        forName: NSWindow.willEnterFullScreenNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        self?.beginFullScreenTransition()
      }
    )
    observerTokens.append(
      center.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        guard let self = self else { return }
        self.fullScreenTransitionGeneration &+= 1
        self.isTransitioningFullScreen = false
        self.isFullScreenState = true
        self.isZoomedState = false
        self.persistWindowStateToDefaults()
      }
    )
    observerTokens.append(
      center.addObserver(
        forName: NSWindow.willExitFullScreenNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        self?.beginFullScreenTransition()
      }
    )
    observerTokens.append(
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        guard let self = self else { return }
        self.fullScreenTransitionGeneration &+= 1
        self.isTransitioningFullScreen = false
        self.isFullScreenState = false
        self.captureAndPersistWindowState()
      }
    )
    observerTokens.append(
      center.addObserver(
        forName: NSWindow.willCloseNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        self?.captureAndPersistWindowState()
      }
    )
    observerTokens.append(
      center.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.captureAndPersistWindowState()
      }
    )
  }

  private func beginFullScreenTransition() {
    self.isTransitioningFullScreen = true
    self.fullScreenTransitionGeneration &+= 1
    let expectedGeneration = self.fullScreenTransitionGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self else { return }
      guard self.isTransitioningFullScreen,
        self.fullScreenTransitionGeneration == expectedGeneration
      else {
        return
      }
      self.isTransitioningFullScreen = false
      self.captureAndPersistWindowState()
    }
  }

  private func captureAndPersistWindowState() {
    guard !self.isMiniaturized && !self.isTransitioningFullScreen else {
      persistWindowStateToDefaults()
      return
    }

    let fullScreen = self.styleMask.contains(.fullScreen)
    self.isFullScreenState = fullScreen
    self.isZoomedState = !fullScreen && self.isZoomed

    if !self.styleMask.contains(.fullScreen) && !self.isMiniaturized && !self.isZoomed {
      let contentSize = self.contentRect(forFrameRect: self.frame).size
      if contentSize.width >= Self.minContentWidth &&
        contentSize.height >= Self.minContentHeight
      {
        self.lastNormalFrame = self.frame
      }
    }

    persistWindowStateToDefaults()
  }

  private func persistWindowStateToDefaults() {
    guard self.lastNormalFrame.width > 0 && self.lastNormalFrame.height > 0 else {
      return
    }
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: Self.keyHasSavedFrame)
    defaults.set(Double(self.lastNormalFrame.origin.x), forKey: Self.keyFrameX)
    defaults.set(Double(self.lastNormalFrame.origin.y), forKey: Self.keyFrameY)
    defaults.set(Double(self.lastNormalFrame.size.width), forKey: Self.keyFrameWidth)
    defaults.set(Double(self.lastNormalFrame.size.height), forKey: Self.keyFrameHeight)
    defaults.set(self.isZoomedState, forKey: Self.keyIsZoomed)
    defaults.set(self.isFullScreenState, forKey: Self.keyIsFullScreen)
  }
}
