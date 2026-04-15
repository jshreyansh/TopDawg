import AppKit
import SwiftUI

final class NotchWindowController: NSWindowController {
    private var targetDisplayID: CGDirectDisplayID?
    private var contentView: AnyView

    var notchWidth: CGFloat = 305
    var notchHeight: CGFloat = 52
    var earSize: CGFloat = 12
    var bottomCornerRadius: CGFloat = 16

    init(contentView: AnyView, displayID: CGDirectDisplayID? = nil) {
        self.contentView = contentView
        self.targetDisplayID = displayID

        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true

        super.init(window: window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        rebuildNotchView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func updateContentView(_ newContent: AnyView) {
        self.contentView = newContent
        rebuildNotchView()
    }

    func updateSize(width: CGFloat, height: CGFloat, earSize: CGFloat, bottomCornerRadius: CGFloat) {
        self.notchWidth = width
        self.notchHeight = height
        self.earSize = earSize
        self.bottomCornerRadius = bottomCornerRadius
        rebuildNotchView()
        positionAtScreenTop()
    }

    func setTargetDisplay(_ displayID: CGDirectDisplayID?) {
        targetDisplayID = displayID
        positionAtScreenTop()
    }

    private func rebuildNotchView() {
        guard let window = window else { return }

        let notchView = HStack(alignment: .top, spacing: 0) {
            NotchEarShape(isLeftSide: true)
                .fill(.black)
                .frame(width: earSize, height: earSize)

            ZStack {
                NotchLiquidShape(earRadius: 0, bottomCornerRadius: bottomCornerRadius)
                    .fill(.black)
                contentView
            }
            .frame(width: notchWidth, height: notchHeight)

            NotchEarShape(isLeftSide: false)
                .fill(.black)
                .frame(width: earSize, height: earSize)
        }

        window.contentViewController = NSHostingController(rootView: notchView)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        positionAtScreenTop()
    }

    func positionAtScreenTop() {
        guard let window = window else { return }

        let screen: NSScreen?
        if let targetID = targetDisplayID {
            screen = NSScreen.screens.first { $0.displayID == targetID } ?? NSScreen.main
        } else {
            screen = NSScreen.main ?? NSScreen.screens.first
        }

        guard let screen = screen else { return }

        let windowWidth = notchWidth + (earSize * 2)
        let windowHeight = notchHeight

        window.setContentSize(NSSize(width: windowWidth, height: windowHeight))

        let screenFrame = screen.frame
        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let y = screenFrame.maxY - windowHeight

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showNotchWindow() {
        positionAtScreenTop()
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func hideNotchWindow() {
        window?.orderOut(nil)
    }
}
