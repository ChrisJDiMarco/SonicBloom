import AppKit
import SonicBloomCore
import SwiftUI

@MainActor
final class SonicBloomAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var enhancementMenuItem: NSMenuItem?
    private var bypassMenuItem: NSMenuItem?
    private var window: NSWindow?
    private let viewModel = SonicBloomViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        openControlPanel()
        viewModel.startIfAutoEnhanceEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stopBridgeImmediately()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SonicBloom")
        item.button?.title = " SonicBloom"

        let menu = NSMenu()
        menu.delegate = self
        let enhancementItem = NSMenuItem(title: "Enhance Mac Audio", action: #selector(toggleEnhancement), keyEquivalent: "e")
        let bypassItem = NSMenuItem(title: "Compare Raw Audio", action: #selector(toggleBypass), keyEquivalent: "b")
        menu.addItem(NSMenuItem(title: "Open SonicBloom", action: #selector(openControlPanel), keyEquivalent: "o"))
        menu.addItem(enhancementItem)
        menu.addItem(bypassItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        enhancementMenuItem = enhancementItem
        bypassMenuItem = bypassItem
        refreshStatusMenu()
    }

    @objc private func openControlPanel() {
        if window == nil {
            let controller = SonicBloomHostingController(rootView: SonicBloomControlPanel(viewModel: viewModel))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "SonicBloom"
            newWindow.setContentSize(NSSize(width: 1500, height: 1020))
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.titlebarAppearsTransparent = false
            newWindow.toolbarStyle = .unifiedCompact
            newWindow.backgroundColor = .windowBackgroundColor
            newWindow.isMovableByWindowBackground = false
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleBypass() {
        viewModel.isBypassed.toggle()
        refreshStatusMenu()
    }

    @objc private func toggleEnhancement() {
        viewModel.runPrimaryAction()
        refreshStatusMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshStatusMenu() {
        enhancementMenuItem?.title = viewModel.isBridgeRunning ? "Turn Off Enhancement" : viewModel.primaryActionTitle
        enhancementMenuItem?.isEnabled = !viewModel.isTransitioning
        bypassMenuItem?.state = viewModel.isBypassed ? .on : .off
        bypassMenuItem?.isEnabled = viewModel.isBridgeRunning
    }
}

private final class SonicBloomHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = NonWindowDraggingHostingView(rootView: rootView)
    }
}

private final class NonWindowDraggingHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

extension SonicBloomAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusMenu()
    }
}
