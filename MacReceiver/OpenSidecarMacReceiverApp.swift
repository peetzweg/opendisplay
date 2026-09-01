// OpenDisplay Receiver: the standalone "this Mac is a display" app (issues
// #82/#17). It is a separate bundle from the sender on purpose: the sender
// needs macOS 14 for its capture/virtual-display stack, while receiving only
// needs the decoder and a window, so this target keeps a much lower
// deployment floor and old Macs can serve as screens (issue #241).
//
// The receiver starts at launch and stays up for the app's lifetime; the
// window is just the control panel (name, status, HUD toggle). The video
// window itself is managed by ReceiverController.

import AppKit
import SwiftUI
import Sparkle

// Plain AppKit lifecycle rather than a SwiftUI `App`: a `WindowGroup` sizes
// its window itself (it opened at ~850×550 regardless of the content frame)
// and hands out File > New; the panel here is one fixed-size window built
// like the sender's control window (NSHostingView in an NSWindow).
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        // NSApplication.delegate is weak, and ARC may free a local after its
        // last use — an optimized build could drop the delegate before the
        // launch callbacks ever fire. run() never returns, so this pins it
        // for the app's lifetime.
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var panel: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        ReceiverController.shared.start()
        showPanel()
        NSApp.activate(ignoringOtherApps: true)
    }

    // Reopening (Dock click) with the panel closed brings it back; the
    // receiver itself never stopped.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }

    // Closing the panel is not quitting: a spare Mac sits there as a display
    // with nothing but the video window (or nothing at all) on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Quitting while being a display: tell the sender we're closing (it ends
    // the session instead of retrying a dead peer) before the process goes.
    // stop() calls back once the message is out or a second has passed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ReceiverController.shared.active else { return .terminateNow }
        ReceiverController.shared.stop {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func showPanel() {
        if panel == nil {
            let content = ReceiverContentView(controller: ReceiverController.shared,
                                              updater: updater)
            let hosting = NSHostingView(rootView: content)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: ReceiverContentView.size),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "OpenDisplay Receiver"
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ReceiverPanel")
            w.center()
            panel = w
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    /// The minimum a windowed app needs: an app menu with Quit, Edit for the
    /// name field's copy/paste and undo, and a Window menu for Close/Minimize.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OpenDisplay Receiver",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                        keyEquivalent: "").target = updater
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OpenDisplay Receiver",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenDisplay Receiver",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        return main
    }
}

struct ReceiverContentView: View {
    /// Fixed panel size; the window is built to it and is not resizable.
    static let size = CGSize(width: 440, height: 520)

    @ObservedObject var controller: ReceiverController
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay Receiver")
                        .font(.title3.bold())
                    Text("This Mac as an extra display for another Mac")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            Form {
                ReceiverSections(controller: controller)
            }
            .groupedFormStyle()

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(controller.connected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.connected ? "Receiving from a Mac" : "Waiting for a Mac to connect")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay Receiver log files in Finder")
                if let updater {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

extension View {
    /// `.formStyle(.grouped)` where it exists (macOS 13); the default form on
    /// macOS 12 is the same content in the older flat layout.
    @ViewBuilder
    func groupedFormStyle() -> some View {
        if #available(macOS 13, *) {
            formStyle(.grouped)
        } else {
            self
        }
    }
}
