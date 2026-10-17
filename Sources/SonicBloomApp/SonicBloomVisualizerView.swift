import AppKit
import SonicBloomCore
import SwiftUI

struct SonicBloomVisualizerView: View {
    @ObservedObject var viewModel: SonicBloomViewModel
    @ObservedObject var windowState: SonicBloomVisualizerWindowState
    var close: () -> Void
    var minimize: () -> Void
    var toggleFullScreen: () -> Void
    var escape: () -> Void

    @State private var deck: VisualizerPresetDeck
    @State private var renderTime: TimeInterval
    @State private var controlsVisible = true
    @State private var lastPointerActivityAt: TimeInterval
    @State private var bottomControlHelp: String?
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private let fullScreenControlsIdleSeconds: TimeInterval = 2.4

    init(
        viewModel: SonicBloomViewModel,
        windowState: SonicBloomVisualizerWindowState,
        close: @escaping () -> Void,
        minimize: @escaping () -> Void,
        toggleFullScreen: @escaping () -> Void,
        escape: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.windowState = windowState
        self.close = close
        self.minimize = minimize
        self.toggleFullScreen = toggleFullScreen
        self.escape = escape
        let startTime = Date().timeIntervalSinceReferenceDate
        let visualizerSettings = viewModel.settings.visualizerSettings
        _deck = State(initialValue: VisualizerPresetDeck(
            presets: VisualizerPresetLibrary.bundledPresets(),
            selectedPresetID: visualizerSettings.selectedPresetID,
            autoCycleEnabled: visualizerSettings.autoCycleEnabled,
            cycleSeconds: visualizerSettings.cycleSeconds,
            startTime: startTime
        ))
        _renderTime = State(initialValue: startTime)
        _lastPointerActivityAt = State(initialValue: startTime)
    }

    var body: some View {
        ZStack {
            MetalVisualizerSurface(
                meter: viewModel.meterModel.meter,
                sourcePreset: deck.sourcePreset(at: renderTime),
                targetPreset: deck.currentPreset,
                comboPreset: deck.comboPreset(at: renderTime),
                transitionProgress: deck.transitionProgress(at: renderTime),
                comboProgress: deck.comboProgress(at: renderTime),
                visualizerSettings: viewModel.settings.visualizerSettings,
                reduceMotion: viewModel.settings.reduceMotion,
                renderSeed: deck.renderSeed,
                isRenderingEnabled: windowState.isRenderingEnabled
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                handleSurfaceTap()
            }

            VisualizerKeyCaptureView { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)

            VisualizerMouseActivityView {
                registerPointerActivity()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .onHover { hovering in
            if hovering {
                registerPointerActivity()
            }
        }
        .onChange(of: windowState.isFullScreen) { _ in
            restoreInteractiveOverlay()
        }
        .onChange(of: windowState.interactionResetToken) { _ in
            restoreInteractiveOverlay()
        }
        .onReceive(tick) { date in
            guard windowState.isRenderingEnabled else { return }
            let time = date.timeIntervalSinceReferenceDate
            deck.syncSettings(
                autoCycleEnabled: viewModel.settings.visualizerSettings.autoCycleEnabled,
                cycleSeconds: viewModel.settings.visualizerSettings.cycleSeconds
            )
            deck.update(at: time)
            renderTime = time
            updateControlVisibility(at: time)
            persistCurrentPresetIfNeeded()
        }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    VisualizerWindowControlButton(systemImage: "xmark", tint: Color(red: 1.0, green: 0.33, blue: 0.36), help: "Close visualizer") {
                        close()
                    }
                    VisualizerWindowControlButton(systemImage: "minus", tint: Color(red: 1.0, green: 0.78, blue: 0.16), help: "Minimize visualizer") {
                        minimize()
                    }
                    VisualizerWindowControlButton(systemImage: "arrow.up.left.and.arrow.down.right", tint: Color(red: 0.22, green: 0.82, blue: 0.34), help: "Toggle fullscreen") {
                        toggleFullScreen()
                    }
                }
                .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presetTitle)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    Text(viewModel.isBridgeRunning ? "LIVE VISUALIZER" : "READY VISUALIZER")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(viewModel.isBridgeRunning ? Color.green.opacity(0.86) : Color.white.opacity(0.56))
                }
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 3)

                Spacer()

                VisualizerIconButton(systemImage: "arrow.left", help: "Previous preset") {
                    deck.previous(at: renderTime)
                    persistCurrentPresetIfNeeded()
                }
                VisualizerIconButton(systemImage: "shuffle", help: "Random preset") {
                    deck.random(at: renderTime)
                    persistCurrentPresetIfNeeded()
                }
                VisualizerIconButton(systemImage: "arrow.counterclockwise", help: "Reset visual seed") {
                    deck.resetSeed()
                }
                VisualizerIconButton(systemImage: deck.isLocked ? "lock.fill" : "lock.open", isActive: deck.isLocked, help: deck.isLocked ? "Unlock preset" : "Lock preset") {
                    deck.toggleLock()
                }
                VisualizerIconButton(systemImage: viewModel.settings.visualizerSettings.autoCycleEnabled ? "repeat.circle.fill" : "repeat.circle", isActive: viewModel.settings.visualizerSettings.autoCycleEnabled, help: "Auto-cycle presets") {
                    updateVisualizerSettings { settings in
                        settings.autoCycleEnabled.toggle()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.black.opacity(0.28))

            Spacer()

            bottomControls
                .padding(.bottom, 18)
        }
    }

    private var bottomControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                VisualizerControlSlider(
                    systemImage: "dial.medium",
                    value: Binding(
                        get: { viewModel.settings.visualizerSettings.intensity },
                        set: { value in updateVisualizerSettings { $0.intensity = min(max(value, 0), 1) } }
                    ),
                    range: 0...1,
                    help: "Intensity - overall visual energy, motion, and brightness",
                    onHoverHelp: setBottomControlHelp
                )
                VisualizerControlSlider(
                    systemImage: "circle.grid.cross",
                    value: Binding(
                        get: { viewModel.settings.visualizerSettings.detailDensity },
                        set: { value in updateVisualizerSettings { $0.detailDensity = min(max(value, 0), 1) } }
                    ),
                    range: 0...1,
                    help: "Detail density - more particles, folds, and spectrum geometry",
                    onHoverHelp: setBottomControlHelp
                )
                VisualizerControlSlider(
                    systemImage: "sparkles",
                    value: Binding(
                        get: { viewModel.settings.visualizerSettings.bloomStrength },
                        set: { value in updateVisualizerSettings { $0.bloomStrength = min(max(value, 0), 1) } }
                    ),
                    range: 0...1,
                    help: "Bloom strength - glow, halos, and light trails",
                    onHoverHelp: setBottomControlHelp
                )
                VisualizerControlSlider(
                    systemImage: "timer",
                    value: Binding(
                        get: { min(max(viewModel.settings.visualizerSettings.cycleSeconds, 8), 120) },
                        set: { value in updateVisualizerSettings { $0.cycleSeconds = min(max(value, 8), 300) } }
                    ),
                    range: 8...120,
                    help: "Auto-cycle seconds - time between major preset changes",
                    onHoverHelp: setBottomControlHelp
                )

                HStack(spacing: 6) {
                    VisualizerIconButton(
                        systemImage: "gauge.with.dots.needle.33percent",
                        isActive: viewModel.settings.visualizerSettings.quality == .performance,
                        help: "Performance quality - lighter GPU load",
                        onHoverHelp: setBottomControlHelp
                    ) {
                        updateVisualizerSettings { $0.quality = .performance }
                    }
                    VisualizerIconButton(
                        systemImage: "gauge.with.dots.needle.50percent",
                        isActive: viewModel.settings.visualizerSettings.quality == .adaptive,
                        help: "Adaptive quality - balances detail and frame rate",
                        onHoverHelp: setBottomControlHelp
                    ) {
                        updateVisualizerSettings { $0.quality = .adaptive }
                    }
                    VisualizerIconButton(
                        systemImage: "gauge.with.dots.needle.67percent",
                        isActive: viewModel.settings.visualizerSettings.quality == .cinematic,
                        help: "Cinematic quality - richer visuals when the GPU can handle it",
                        onHoverHelp: setBottomControlHelp
                    ) {
                        updateVisualizerSettings { $0.quality = .cinematic }
                    }
                    VisualizerIconButton(
                        systemImage: viewModel.settings.visualizerSettings.flashLimitEnabled ? "bolt.slash.fill" : "bolt.fill",
                        isActive: viewModel.settings.visualizerSettings.flashLimitEnabled,
                        help: "Flash limit - caps rapid brightness spikes",
                        onHoverHelp: setBottomControlHelp
                    ) {
                        updateVisualizerSettings { $0.flashLimitEnabled.toggle() }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.30))
        }
        .overlay(alignment: .top) {
            if let bottomControlHelp {
                VisualizerHoverLabel(text: bottomControlHelp)
                    .offset(y: -42)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            escape()
            return true
        case 123:
            deck.previous(at: renderTime)
            persistCurrentPresetIfNeeded()
            return true
        case 124:
            deck.next(at: renderTime)
            persistCurrentPresetIfNeeded()
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            toggleFullScreen()
            return true
        case " ":
            deck.random(at: renderTime)
            persistCurrentPresetIfNeeded()
            return true
        case "l":
            deck.toggleLock()
            return true
        case "r":
            deck.resetSeed()
            return true
        default:
            return false
        }
    }

    private var presetTitle: String {
        if let combo = deck.comboPreset(at: renderTime), deck.comboProgress(at: renderTime) > 0.08 {
            return "\(deck.currentPreset.name) + \(combo.name)"
        }
        return deck.currentPreset.name
    }

    private func persistCurrentPresetIfNeeded() {
        guard viewModel.settings.visualizerSettings.selectedPresetID != deck.currentPreset.id else { return }
        updateVisualizerSettings { settings in
            settings.selectedPresetID = deck.currentPreset.id
        }
    }

    private func updateVisualizerSettings(_ update: (inout VisualizerSettings) -> Void) {
        var settings = viewModel.settings
        update(&settings.visualizerSettings)
        viewModel.settings = settings
    }

    private func setBottomControlHelp(_ help: String, _ isHovering: Bool) {
        withAnimation(.easeInOut(duration: 0.12)) {
            if isHovering {
                bottomControlHelp = help
            } else if bottomControlHelp == help {
                bottomControlHelp = nil
            }
        }
    }

    private func handleSurfaceTap() {
        let wasVisible = controlsVisible
        registerPointerActivity()
        guard wasVisible else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            controlsVisible.toggle()
        }
    }

    private func registerPointerActivity() {
        lastPointerActivityAt = Date().timeIntervalSinceReferenceDate
        guard windowState.isFullScreen else {
            if !controlsVisible {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible = true
                }
            }
            return
        }
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.18)) {
                controlsVisible = true
            }
        }
    }

    private func restoreInteractiveOverlay() {
        lastPointerActivityAt = Date().timeIntervalSinceReferenceDate
        NSCursor.setHiddenUntilMouseMoves(false)
        withAnimation(.easeInOut(duration: 0.18)) {
            controlsVisible = true
        }
    }

    private func updateControlVisibility(at time: TimeInterval) {
        guard windowState.isFullScreen else {
            if !controlsVisible {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible = true
                }
            }
            return
        }
        guard controlsVisible, time - lastPointerActivityAt >= fullScreenControlsIdleSeconds else { return }
        withAnimation(.easeInOut(duration: 0.42)) {
            controlsVisible = false
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

private struct VisualizerIconButton: View {
    var systemImage: String
    var isActive = false
    var help: String
    var onHoverHelp: ((String, Bool) -> Void)?
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 30)
                .foregroundStyle(isActive ? Color.black : Color.white)
                .background(isActive ? Color.white.opacity(0.90) : Color.black.opacity(0.34))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isActive ? 0.48 : 0.20), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            isHovering = hovering
            onHoverHelp?(help, hovering)
        }
        .overlay(alignment: .top) {
            if isHovering, onHoverHelp == nil {
                VisualizerHoverLabel(text: help)
                    .offset(y: -36)
            }
        }
        .zIndex(isHovering ? 20 : 0)
    }
}

private struct VisualizerWindowControlButton: View {
    var systemImage: String
    var tint: Color
    var help: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .black))
                .frame(width: 26, height: 26)
                .foregroundStyle(isHovering ? Color.black.opacity(0.82) : Color.black.opacity(0.0))
                .background(tint)
                .clipShape(Circle())
                .shadow(color: tint.opacity(isHovering ? 0.42 : 0.20), radius: isHovering ? 10 : 4)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
        .overlay(alignment: .top) {
            if isHovering {
                VisualizerHoverLabel(text: help)
                    .offset(x: 52, y: -34)
            }
        }
        .zIndex(isHovering ? 30 : 0)
    }
}

private struct VisualizerControlSlider: View {
    var systemImage: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var help: String
    var onHoverHelp: ((String, Bool) -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 16)
                .foregroundStyle(Color.white.opacity(0.76))
            Slider(value: $value, in: range)
                .tint(.white)
                .frame(width: 112)
        }
        .help(help)
        .accessibilityLabel(help)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            onHoverHelp?(help, hovering)
        }
        .overlay(alignment: .top) {
            if isHovering, onHoverHelp == nil {
                VisualizerHoverLabel(text: help)
                    .offset(y: -35)
            }
        }
        .zIndex(isHovering ? 20 : 0)
    }
}

private struct VisualizerHoverLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.black.opacity(0.76))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
    }
}

private struct VisualizerMouseActivityView: NSViewRepresentable {
    var onActivity: () -> Void

    func makeNSView(context: Context) -> MouseActivityNSView {
        let view = MouseActivityNSView()
        view.onActivity = onActivity
        return view
    }

    func updateNSView(_ view: MouseActivityNSView, context: Context) {
        view.onActivity = onActivity
    }

    final class MouseActivityNSView: NSView {
        var onActivity: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .mouseMoved,
                    .leftMouseDown,
                    .rightMouseDown,
                    .otherMouseDown,
                    .leftMouseDragged,
                    .rightMouseDragged,
                    .otherMouseDragged,
                    .scrollWheel
                ]
            ) { [weak self] event in
                guard let self else { return event }
                if event.window === self.window {
                    onActivity?()
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

private struct VisualizerKeyCaptureView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }

    final class KeyCaptureNSView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
