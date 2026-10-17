import AppKit
import SonicBloomCore
import SwiftUI

@MainActor
final class SonicBloomAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var enhancementMenuItem: NSMenuItem?
    private var bypassMenuItem: NSMenuItem?
    private var window: NSWindow?
    private var visualizerWindowController: SonicBloomVisualizerWindowController?
    private let viewModel = SonicBloomViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        RecoveryAgentAutostart.installBundledAgentIfAvailable()
        installRecoveryObservers()
        openControlPanel()
        viewModel.startIfAutoEnhanceEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        viewModel.stopBridgeImmediately()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SonicBloom")
        item.button?.title = " SonicBloom"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        statusMenu = menu
        refreshStatusMenu()
    }

    @objc private func openControlPanel() {
        if window == nil {
            let controller = SonicBloomHostingController(rootView: SonicBloomControlPanel(
                viewModel: viewModel,
                openVisualizer: { [weak self] in self?.openVisualizer() }
            ))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "SonicBloom"
            newWindow.setContentSize(SonicBloomWindowMetrics.defaultSize)
            newWindow.contentMinSize = SonicBloomWindowMetrics.minimumSize
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

    @objc private func openVisualizer() {
        if visualizerWindowController == nil {
            visualizerWindowController = SonicBloomVisualizerWindowController(viewModel: viewModel)
        }
        visualizerWindowController?.showVisualizer()
    }

    @objc private func toggleBypass() {
        viewModel.toggleRawCompare()
        refreshStatusMenu()
    }

    @objc private func toggleEnhancement() {
        viewModel.runPrimaryAction()
        refreshStatusMenu()
    }

    @objc private func selectPresetFromMenu(_ sender: NSMenuItem) {
        guard let presetName = sender.representedObject as? String,
              let preset = viewModel.presets.first(where: { $0.name == presetName }) else { return }
        viewModel.selectPreset(preset)
        refreshStatusMenu()
    }

    @objc private func repairAudioRoute() {
        viewModel.repairAudioPath()
        refreshStatusMenu()
    }

    @objc private func optimizeForVideoSync() {
        viewModel.optimizeLatencyForVideo()
        refreshStatusMenu()
    }

    @objc private func runAudioSelfTest() {
        viewModel.runAudioConfidenceCheck()
        refreshStatusMenu()
    }

    @objc private func copySupportBundle() {
        viewModel.copySupportBundleReport()
        refreshStatusMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func installRecoveryObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(recoverAfterWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func recoverAfterWake() {
        viewModel.recoverAfterSystemWake()
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        menu.addItem(disabledItem(viewModel.isBridgeRunning ? "Live: \(viewModel.selectedPreset.name)" : "Ready: \(viewModel.selectedPreset.name)"))
        menu.addItem(disabledItem(viewModel.selectedPreset.story))
        menu.addItem(disabledItem("Output: \(viewModel.routeState.selectedPhysicalOutputName ?? "No output")"))
        menu.addItem(disabledItem("Confidence: \(viewModel.audioConfidence.headline)"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Open SonicBloom", #selector(openControlPanel), "o"))
        menu.addItem(actionItem("Open Visualizer", #selector(openVisualizer), "i"))

        let enhancementItem = actionItem(viewModel.isBridgeRunning ? "Turn Off Enhancement" : viewModel.primaryActionTitle, #selector(toggleEnhancement), "e")
        enhancementItem.isEnabled = !viewModel.isTransitioning
        menu.addItem(enhancementItem)

        let presetItem = NSMenuItem(title: "Preset: \(viewModel.selectedPreset.name)", action: nil, keyEquivalent: "")
        presetItem.submenu = makePresetMenu()
        menu.addItem(presetItem)

        let bypassItem = actionItem("Compare Raw Audio", #selector(toggleBypass), "b")
        bypassItem.state = viewModel.isBypassed ? .on : .off
        bypassItem.isEnabled = viewModel.isBridgeRunning
        menu.addItem(bypassItem)

        menu.addItem(.separator())
        menu.addItem(actionItem("Run Audio Self-Test", #selector(runAudioSelfTest), "t"))
        menu.addItem(actionItem("Repair Audio Route", #selector(repairAudioRoute), "r"))
        menu.addItem(actionItem("Optimize For Video Sync", #selector(optimizeForVideoSync), "v"))
        menu.addItem(actionItem("Copy Support Bundle", #selector(copySupportBundle), "d"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", #selector(quit), "q"))

        enhancementMenuItem = enhancementItem
        bypassMenuItem = bypassItem
    }

    private func makePresetMenu() -> NSMenu {
        let menu = NSMenu()
        for preset in viewModel.presets {
            let item = actionItem(preset.name, #selector(selectPresetFromMenu(_:)))
            item.representedObject = preset.name
            item.state = preset.name == viewModel.selectedPreset.name ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func actionItem(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
