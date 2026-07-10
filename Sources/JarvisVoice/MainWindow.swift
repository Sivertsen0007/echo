import Cocoa
import SwiftUI

/// Owns the single Echo main window. We stay LSUIElement (no Dock icon) and
/// only show the window on demand via the menubar "Open Echo" item.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show() {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = NSHostingController(rootView: EchoMainView())
        let w = NSWindow(contentViewController: root)
        w.setContentSize(NSSize(width: 1100, height: 700))
        w.minSize = NSSize(width: 900, height: 560)
        w.title = "Echo"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep window controller alive so re-opening is instant; just let it
        // be deallocated implicitly when the user quits.
    }
}
