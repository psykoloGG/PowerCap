import AppKit
import SwiftUI

/// Connects the panel to the menu bar window that hosts it.
///
/// It reports when the panel opens and closes, based on whether its window is visible on
/// screen, and keeps the window exactly as tall as the content.
/// MenuBarExtra windows grow with their content but never shrink, so without this a row
/// that disappears leaves empty bands above and below the panel.
struct PanelWindowBridge: NSViewRepresentable {
    let contentHeight: CGFloat
    let onOpen: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> BridgeView {
        BridgeView()
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.onOpen = onOpen
        view.onClose = onClose
        view.contentHeight = contentHeight
    }

    final class BridgeView: NSView {
        var onOpen: (@MainActor () -> Void)?
        var onClose: (@MainActor () -> Void)?
        var contentHeight: CGFloat = 0 {
            didSet {
                if contentHeight != oldValue {
                    scheduleWindowFit()
                }
            }
        }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard let window else {
                return
            }

            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportVisibility()
                }
            })
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.reportVisibility()
                }
            }
            scheduleWindowFit()
        }

        private func reportVisibility() {
            guard let window else {
                return
            }
            if window.occlusionState.contains(.visible) {
                onOpen?()
            } else {
                onClose?()
            }
        }

        // Resizing during a SwiftUI update pass can re-enter layout, so wait for the next turn of the run loop.
        private func scheduleWindowFit() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.fitWindowToContent()
                }
            }
        }

        /// Matches the window height to the content while keeping its top edge under the menu bar.
        private func fitWindowToContent() {
            guard let window, contentHeight > 0 else {
                return
            }
            let contentRect = window.contentRect(forFrameRect: window.frame)
            guard abs(contentRect.height - contentHeight) > 0.5 else {
                return
            }
            let fittedContentRect = NSRect(x: contentRect.minX, y: contentRect.maxY - contentHeight, width: contentRect.width, height: contentHeight)
            window.setFrame(window.frameRect(forContentRect: fittedContentRect), display: true)
        }
    }
}
