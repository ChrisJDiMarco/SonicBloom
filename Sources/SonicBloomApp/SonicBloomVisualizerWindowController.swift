import AppKit
import SwiftUI

@MainActor
final class SonicBloomVisualizerWindowState: ObservableObject {
    @Published var isRenderingEnabled = false
    @Published var isFullScreen = false
    @Published var interactionResetToken = 0

    func resetInteractionState() {
        interactionResetToken &+= 1
    }
}

@MainActor
final class SonicBloomVisualizerWindowController: NSWindowController {
    private let viewModel: SonicBloomViewModel
    private let windowState = SonicBloomVisualizerWindowState()

    init(viewModel: SonicBloomViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SonicBloom Visualizer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentMinSize = NSSize(width: 720, height: 405)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.contentViewController = NSHostingController(
            rootView: SonicBloomVisualizerView(
                viewModel: viewModel,
                windowState: windowState,
                close: { [weak self] in self?.window?.close() },
                minimize: { [weak self] in self?.window?.miniaturize(nil) },
                toggleFullScreen: { [weak self] in self?.toggleFullScreenMode() },
                escape: { [weak self] in self?.handleEscape() }
            )
        )
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showVisualizer() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        windowState.isRenderingEnabled = true
        windowState.isFullScreen = window.styleMask.contains(.fullScreen)
        windowState.resetInteractionState()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleFullScreenMode() {
        guard let window else { return }
        window.toggleFullScreen(nil)
    }

    private func handleEscape() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.close()
        }
    }
}

extension SonicBloomVisualizerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        windowState.isRenderingEnabled = false
        windowState.isFullScreen = false
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        windowState.isFullScreen = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        windowState.isFullScreen = true
        windowState.resetInteractionState()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        windowState.isFullScreen = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        windowState.isFullScreen = false
        windowState.isRenderingEnabled = true
        windowState.resetInteractionState()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
