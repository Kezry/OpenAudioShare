import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        createMainMenu()
        createWindow()
        createStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.saveSnapshot()
            }
        }
        if CommandLine.arguments.contains("--render") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.renderUI()
            }
        }
    }

    private func saveSnapshot() {
        guard let window, let view = window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error("snapshot: no bitmap rep")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.error("snapshot: no png data")
            return
        }
        let url = URL(fileURLWithPath: "/tmp/audioshare-ui.png")
        do {
            try data.write(to: url)
            Log.info("snapshot saved \(url.path) size=\(view.bounds.size)")
        } catch {
            Log.error("snapshot write failed: \(error)")
        }
        if let frameView = window.contentView?.superview,
           let frameRep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: frameRep)
            if let frameData = frameRep.representation(using: .png, properties: [:]) {
                try? frameData.write(to: URL(fileURLWithPath: "/tmp/audioshare-window.png"))
                Log.info("window snapshot \(frameView.bounds.size)")
            }
        }
    }

    private func renderUI() {
        let content = ZStack {
            Color(hex: 0xEDEFF2)
            MainView(model: model)
        }
        .frame(width: 500, height: 491)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            Log.error("render: failed")
            return
        }
        let url = URL(fileURLWithPath: "/tmp/audioshare-ui.png")
        do {
            try data.write(to: url)
            Log.info("render saved \(url.path) size=\(image.size)")
        } catch {
            Log.error("render write failed: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    private func createWindow() {
        let window = FluentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 463),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.fullScreenNone]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        let controller = NSHostingController(rootView: MainView(model: model))
        window.contentViewController = controller
        window.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: 500, height: 463)
        window.setContentSize(NSSize(width: 500, height: 463))
        window.center()
        self.window = window
        Log.info("window frame=\(window.frame) content=\(String(describing: window.contentView?.frame))")

        // Match the Windows app: the title bar belongs to the content.
        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Log.info("window settled frame=\(String(describing: self?.window.frame)) content=\(String(describing: self?.window.contentView?.frame)) visible=\(String(describing: self?.window.contentView?.isHidden)) alpha=\(String(describing: self?.window.contentView?.alphaValue))")
        }
    }

    private func createMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L10n.t("about"),
                                   action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: L10n.t("chooseAPK"),
                                   action: #selector(chooseAPK), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: L10n.t("permissionMenu"),
                                   action: #selector(openPermissions), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L10n.t("quit"),
                                   action: #selector(quit), keyEquivalent: "q"))
        for item in appMenu.items { item.target = self }
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: L10n.t("title"),
            .applicationVersion: "2.0.12",
            .credits: NSAttributedString(
                string: "Based on OpenAudioShare by Kezry / HeHang.\n" +
                        "macOS 版：Core Audio Tap + ADB + 兼容 Android 协议。",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseAPK() {
        model.chooseAPK()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "AudioShare")
            image?.isTemplate = true
            button.image = image
            button.toolTip = model.title
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.t("showWindow"),
                                action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menuConnectAll"),
                                action: #selector(connectAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("menuDisconnectAll"),
                                action: #selector(disconnectAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("menuSync"),
                                action: #selector(syncDevices), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("permissionMenu"),
                                action: #selector(openPermissions), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("quit"),
                                action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func connectAll() {
        model.connectAll()
    }

    @objc private func disconnectAll() {
        model.disconnectAll()
    }

    @objc private func syncDevices() {
        model.syncDevices(applyNow: true)
    }

    @objc private func openPermissions() {
        PermissionRequester.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}


final class FluentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
