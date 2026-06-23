import AppKit
import SonicBloomCore
import SwiftUI

struct SonicBloomControlPanel: View {
    @ObservedObject var viewModel: SonicBloomViewModel
    @State private var tab = ConsoleTab.studio

    var body: some View {
        ZStack(alignment: .topLeading) {
            ConsoleBackdrop()
            HStack(alignment: .top, spacing: 18) {
                sidebar
                VStack(spacing: 14) {
                    HeroAnalyzer(viewModel: viewModel)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.settings.showAdvancedControls {
                        ConsoleTabBar(selection: $tab)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView(.vertical) {
                            tabContent
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.bottom, 10)
                        }
                        .scrollIndicators(.visible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                    } else {
                        SimpleModePanel(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1440, minHeight: 900, alignment: .topLeading)
        .background(SBColor.canvas)
        .foregroundStyle(SBColor.text)
        .tint(SBColor.green)
        .preferredColorScheme(.light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SonicLogo(isRunning: viewModel.isBridgeRunning)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SonicBloom")
                        .font(.system(size: 25, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text("Live Processor")
                        .font(.callout)
                        .foregroundStyle(SBColor.subtext)
                }
            }

            ProcessingCard(viewModel: viewModel)

            Button {
                viewModel.settings.showAdvancedControls.toggle()
            } label: {
                Label(viewModel.settings.showAdvancedControls ? "Simple View" : "Studio View", systemImage: viewModel.settings.showAdvancedControls ? "sparkles" : "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 9)
                    .foregroundStyle(SBColor.green)
                    .background(SBColor.green.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(SBColor.green.opacity(0.35), lineWidth: 1) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SonicPressButtonStyle())
            .help(viewModel.settings.showAdvancedControls ? "Switch to simple controls" : "Switch to studio controls")

            Text("PRESETS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SBColor.subtext)
                .padding(.top, 4)

            VStack(spacing: 5) {
                ForEach(viewModel.presets) { preset in
                    PresetButton(
                        preset: preset,
                        selected: preset.name == viewModel.selectedPreset.name
                    ) {
                        viewModel.selectPreset(preset)
                    }
                }
            }

            Spacer(minLength: 10)

            Button {
                viewModel.toggleRawCompare()
            } label: {
                Label(viewModel.isBypassed ? "Raw Audio" : "Compare Raw", systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(viewModel.isBypassed ? .white : SBColor.blue)
                    .background(viewModel.isBypassed ? SBColor.blue.opacity(0.82) : SBColor.blue.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(SBColor.blue.opacity(0.6), lineWidth: 1) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SonicPressButtonStyle())
            .disabled(!viewModel.isBridgeRunning || viewModel.isTransitioning)
            .opacity(viewModel.isBridgeRunning ? 1 : 0.5)
            .help("Toggle loudness-matched raw audio comparison")

            Button {
                viewModel.runPrimaryAction()
            } label: {
                PrimaryActionLabel(viewModel: viewModel)
            }
            .buttonStyle(SonicPressButtonStyle())
            .disabled(viewModel.isTransitioning)
            .opacity(viewModel.isTransitioning ? 0.72 : 1)
            .help(viewModel.isBridgeRunning ? "Restore Mac output and stop enhancement" : "Start enhancing Mac audio")
        }
        .padding(18)
        .frame(width: 276)
        .frame(maxHeight: .infinity)
        .consolePanel()
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .studio:
            StudioDesk(viewModel: viewModel)
        case .eq:
            EQWorkbench(viewModel: viewModel)
        case .routing:
            RoutingWorkbench(viewModel: viewModel)
        case .space:
            SpaceWorkbench(viewModel: viewModel)
        case .settings:
            SettingsWorkbench(viewModel: viewModel)
        }
    }
}

private enum ConsoleTab: String, CaseIterable, Identifiable {
    case studio = "STUDIO DESK"
    case eq = "EQ"
    case routing = "ROUTING"
    case space = "SPACE"
    case settings = "SETTINGS"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .studio: "building.columns"
        case .eq: "waveform.path.ecg"
        case .routing: "point.3.connected.trianglepath.dotted"
        case .space: "dot.radiowaves.left.and.right"
        case .settings: "gearshape.fill"
        }
    }
}

enum PerAppMixerLayout {
    static let sectionSpacing: CGFloat = 12
    static let panelHeight: CGFloat = 340
    static let routeActionTrayHeight: CGFloat = 58
    static let rowMinHeight: CGFloat = 54
    static let rowSpacing: CGFloat = 8
    static let listHeaderHeight: CGFloat = 28
    static let bottomScrollClearance: CGFloat = routeActionTrayHeight + sectionSpacing

    static func minimumPanelHeight(visibleRows: Int) -> CGFloat {
        let rows = max(visibleRows, 0)
        let rowGaps = max(rows - 1, 0)
        return listHeaderHeight
            + CGFloat(rows) * rowMinHeight
            + CGFloat(rowGaps) * rowSpacing
            + 36
    }
}

private struct SimpleModePanel: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ConsoleCard(title: "MAGIC MODE", icon: "sparkles", color: SBColor.green) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(viewModel.isBridgeRunning ? "Enhancing Mac Audio" : "Ready To Enhance")
                                    .font(.system(size: 28, weight: .black))
                                Text(viewModel.deviceProfileSummary)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(SBColor.subtext)
                            }
                            Spacer()
                            Button {
                                viewModel.runPrimaryAction()
                            } label: {
                                PrimaryActionLabel(viewModel: viewModel)
                                    .frame(width: 170)
                            }
                            .buttonStyle(SonicPressButtonStyle())
                            .disabled(viewModel.isTransitioning)
                            .opacity(viewModel.isTransitioning ? 0.72 : 1)
                        }

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("PRESET")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(SBColor.subtext)
                                Picker("Preset", selection: presetNameBinding) {
                                    ForEach(viewModel.presets) { preset in
                                        Text(preset.name).tag(preset.name)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            RoutePicker(label: "Output", value: viewModel.routeState.selectedPhysicalOutputName ?? "No output")
                        }

                        MiniSlider(title: "MAGIC INTENSITY", value: magicIntensityBinding, range: 0...1, color: SBColor.green)
                    }
                }

                ConsoleCard(title: "SAFE HEADROOM", icon: "shield.fill", color: SBColor.orange) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(String(format: "%.1f dB", viewModel.meterModel.meter.gainReductionDB))
                            .font(.system(size: 34, weight: .black, design: .monospaced))
                            .foregroundStyle(SBColor.orange)
                        Text("gain reduction")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SBColor.subtext)
                        HeadroomMeters(meterModel: viewModel.meterModel, compact: true)
                            .frame(height: 110)
                    }
                }
                .frame(width: 260)
            }

            HStack(spacing: 14) {
                MetricStack(title: "MODE", value: viewModel.settings.syncMode.rawValue, color: SBColor.green)
                MetricStack(title: "CONTENT", value: viewModel.smartContentProfile.rawValue.capitalized, color: SBColor.blue)
                MetricStack(title: "LATENCY", value: String(format: "%.1f ms", viewModel.routeState.estimatedLatencyMS), color: SBColor.orange)
                MetricStack(title: "CLIPPING", value: viewModel.trustSummary.clipping, color: SBColor.green)
            }
            .frame(height: 76)
            .consolePanel()

            Spacer(minLength: 0)
        }
    }

    private var presetNameBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedPreset.name },
            set: { name in
                if let preset = viewModel.presets.first(where: { $0.name == name }) {
                    viewModel.selectPreset(preset)
                }
            }
        )
    }

    private var magicIntensityBinding: Binding<Double> {
        Binding(
            get: { min(max(viewModel.selectedPreset.loudnessAmount / 0.56, 0), 1) },
            set: { value in
                let amount = min(max(value, 0), 1)
                viewModel.editSelectedPreset(viewModel.selectedPreset.with(
                    inputGainDB: amount * 4,
                    bassAmount: 0.08 + amount * 0.42,
                    widthAmount: 0.08 + amount * 0.24,
                    spatialAmount: 0.04 + amount * 0.32,
                    loudnessAmount: 0.08 + amount * 0.48,
                    fidelityAmount: 0.05 + amount * 0.24,
                    masteringAmount: 0.08 + amount * 0.34,
                    limiterCeilingDB: min(viewModel.selectedPreset.limiterCeilingDB, -1)
                ))
            }
        )
    }
}

private struct HeroAnalyzer: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(text: viewModel.isBridgeRunning ? "LIVE" : "READY", color: viewModel.isBridgeRunning ? SBColor.green : SBColor.subtext)
                    Text(viewModel.selectedPreset.name)
                        .font(.system(size: 46, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(outputLine)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SBColor.subtext)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(outputLine)
                }
                .layoutPriority(1)
                Spacer()
                HStack(spacing: 0) {
                    MetricStack(title: "CEILING", value: String(format: "%.1f dB", viewModel.selectedPreset.limiterCeilingDB), color: SBColor.blue)
                    Divider().overlay(SBColor.line).padding(.vertical, 10)
                    MetricStack(title: "SAMPLE RATE", value: sampleText, color: SBColor.green)
                    Divider().overlay(SBColor.line).padding(.vertical, 10)
                    MetricStack(title: "BUFFER", value: "\(viewModel.routeState.bufferSize)", color: SBColor.orange)
                }
                .frame(width: 330, height: 56)
                .consolePanel()
                LoudnessScope(meterModel: viewModel.meterModel)
                    .frame(width: 250, height: 90)
                HeadroomMeters(meterModel: viewModel.meterModel, compact: true)
                    .frame(width: 160, height: 90)
            }
            .frame(height: 98)

            SpectrumAnalyzer(
                meterModel: viewModel.meterModel,
                preset: viewModel.selectedPreset,
                isRunning: viewModel.isBridgeRunning,
                reduceMotion: viewModel.settings.reduceMotion
            )
            .frame(height: 174)

            SignalChain(viewModel: viewModel)
                .frame(height: 60)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .frame(height: 400)
        .consolePanel()
    }

    private var outputLine: String {
        if viewModel.isBridgeRunning {
            return "Enhancing all Mac audio -> \(viewModel.routeState.selectedPhysicalOutputName ?? "Output")"
        }
        return viewModel.routeState.selectedPhysicalOutputName.map { "Ready for \($0)" } ?? "No output device detected"
    }

    private var sampleText: String {
        String(format: "%.1f kHz", viewModel.routeState.sampleRate / 1000)
    }
}

private struct ConsoleTabBar: View {
    @Binding var selection: ConsoleTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ConsoleTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    selection = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selected ? SBColor.tabActive : Color.clear)
                        }
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(selected ? SBColor.green : .clear)
                                .frame(width: 34, height: 3)
                                .padding(.bottom, 2)
                        }
                        .foregroundStyle(selected ? SBColor.green : SBColor.subtext)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(SonicPressButtonStyle())
                .accessibilityLabel(tab.rawValue)
            }
        }
        .padding(4)
        .background(SBColor.panel)
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(SBColor.line.opacity(0.9), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: SBColor.shadow.opacity(0.65), radius: 7, x: 0, y: 3)
    }
}

private struct StudioDesk: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ToneEngine(viewModel: viewModel)
                    .frame(width: 300)
                EQConsole(viewModel: viewModel)
                StereoField(viewModel: viewModel)
                    .frame(width: 300)
            }
            .frame(height: 350)
        }
    }
}

private struct ToneEngine: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "TONE ENGINE", icon: "power", color: SBColor.green) {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    KnobControl(title: "INPUT TRIM", value: binding(\.inputGainDB), range: -12...12, display: "%.1f dB", color: SBColor.green)
                    KnobControl(title: "BASS BLOOM", value: binding(\.bassAmount), range: 0...1, display: percentDisplay, color: SBColor.yellow)
                    KnobControl(title: "LOUDNESS", value: binding(\.loudnessAmount), range: 0...1, display: percentDisplay, color: SBColor.red)
                }
                HStack(spacing: 16) {
                    KnobControl(title: "MASTERING", value: binding(\.masteringAmount), range: 0...1, display: percentDisplay, color: SBColor.orange)
                    KnobControl(title: "PRESENCE", value: binding(\.fidelityAmount), range: 0...1, display: percentDisplay, color: SBColor.blue)
                    KnobControl(title: "NIGHT", value: binding(\.nightModeAmount), range: 0...1, display: percentDisplay, color: SBColor.green)
                }
                Button {
                    viewModel.undoPresetChange()
                } label: {
                    Label("Undo Changes", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(viewModel.canUndoPresetChange ? SBColor.yellow.opacity(0.16) : SBColor.panel2)
                        .overlay { RoundedRectangle(cornerRadius: 7).stroke(viewModel.canUndoPresetChange ? SBColor.yellow.opacity(0.55) : SBColor.line, lineWidth: 1) }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(SonicPressButtonStyle())
                .disabled(!viewModel.canUndoPresetChange)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DSPPreset, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.selectedPreset[keyPath: keyPath] },
            set: { viewModel.editSelectedPreset(viewModel.selectedPreset.with(keyPath, $0)) }
        )
    }

    private func percentDisplay(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct EQConsole: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "EQ", icon: "power", color: SBColor.green) {
            VStack(spacing: 10) {
                EQResponseGraph(bands: viewModel.selectedPreset.eqBandsDB)
                    .frame(height: 120)
                    .overlay(alignment: .bottom) {
                        FrequencyLabels()
                    }
                HStack(spacing: 0) {
                    EQMiniKnob(title: "LOW SHELF", frequency: "80 Hz", value: bandBinding(6), color: SBColor.green)
                    EQMiniKnob(title: "LOW MID", frequency: "220 Hz", value: bandBinding(10), color: SBColor.yellow)
                    EQMiniKnob(title: "MID", frequency: "1.2 kHz", value: bandBinding(18), color: SBColor.blue)
                    EQMiniKnob(title: "HIGH MID", frequency: "3.5 kHz", value: bandBinding(23), color: SBColor.purple)
                    EQMiniKnob(title: "HIGH SHELF", frequency: "12 kHz", value: bandBinding(28), color: SBColor.red)
                }
            }
        }
    }

    private func bandBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { viewModel.selectedPreset.eqBandsDB[index] },
            set: { value in
                var bands = viewModel.selectedPreset.eqBandsDB
                bands[index] = value
                viewModel.editSelectedPreset(viewModel.selectedPreset.with(eqBandsDB: bands))
            }
        )
    }
}

private struct StereoField: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "STEREO FIELD", icon: "power", color: SBColor.green) {
            VStack(spacing: 12) {
                StereoVectorscope(meterModel: viewModel.meterModel, width: viewModel.selectedPreset.widthAmount, spatial: viewModel.selectedPreset.spatialAmount)
                    .frame(height: 132)
                MiniSlider(title: "STEREO WIDTH", value: binding(\.widthAmount), range: 0...1, color: SBColor.green)
                MiniSlider(title: "SPATIAL BLOOM", value: binding(\.spatialAmount), range: 0...1, color: SBColor.red)
                MiniSlider(title: "CROSSFEED", value: binding(\.crossfeedAmount), range: 0...1, color: SBColor.green)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DSPPreset, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.selectedPreset[keyPath: keyPath] },
            set: { viewModel.editSelectedPreset(viewModel.selectedPreset.with(keyPath, $0)) }
        )
    }
}

private struct RoutingMatrix: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "ROUTING", icon: "power", color: SBColor.yellow) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    RoutePicker(label: "Input Device", value: viewModel.routeState.bridgeInputDeviceName ?? "Mac Audio")
                    RoutePicker(label: "Processing", value: "SonicBloom Engine")
                    RoutePicker(label: "Output Device", value: viewModel.routeState.selectedPhysicalOutputName ?? "AudioBox USB")
                }
                Canvas { context, size in
                    let rows = [size.height * 0.28, size.height * 0.72]
                    let cols = stride(from: size.width * 0.08, through: size.width * 0.78, by: size.width * 0.23).map { $0 }
                    var path = Path()
                    path.move(to: CGPoint(x: cols[0], y: rows[0])); path.addLine(to: CGPoint(x: cols[1], y: rows[0])); path.addLine(to: CGPoint(x: cols[2], y: rows[1]))
                    path.move(to: CGPoint(x: cols[0], y: rows[1])); path.addLine(to: CGPoint(x: cols[1], y: rows[1])); path.addLine(to: CGPoint(x: cols[2], y: rows[0]))
                    path.move(to: CGPoint(x: cols[2], y: rows[0])); path.addLine(to: CGPoint(x: cols[3], y: rows[0]))
                    path.move(to: CGPoint(x: cols[2], y: rows[1])); path.addLine(to: CGPoint(x: cols[3], y: rows[1]))
                    context.stroke(path, with: .color(viewModel.isBridgeRunning ? SBColor.green : SBColor.subtext), lineWidth: 1.2)
                    for x in cols {
                        for y in rows {
                            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(SBColor.green.opacity(0.75)))
                            context.stroke(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(SBColor.text.opacity(0.7)), lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SafetyLimiter: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "SAFETY & LIMITER", icon: "power", color: SBColor.green) {
            HStack(spacing: 20) {
                KnobControl(title: "CEILING", value: binding(\.limiterCeilingDB), range: -8 ... -0.1, display: "%.1f dB", color: SBColor.blue)
                KnobControl(title: "LOOKAHEAD", value: binding(\.limiterLookaheadMS), range: 0.2...10, display: "%.1f ms", color: SBColor.blue)
                KnobControl(title: "RELEASE", value: binding(\.limiterReleaseMS), range: 20...300, display: "%.0f ms", color: SBColor.blue)
                VerticalScale(value: min(viewModel.meterModel.meter.gainReductionDB / 8, 1), color: SBColor.orange)
                    .frame(width: 42)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DSPPreset, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.selectedPreset[keyPath: keyPath] },
            set: { viewModel.editSelectedPreset(viewModel.selectedPreset.with(keyPath, $0)) }
        )
    }
}

private struct EQWorkbench: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        VStack(spacing: 8) {
            EQResponseGraph(bands: viewModel.selectedPreset.eqBandsDB)
                .frame(height: 210)
                .padding(16)
                .consolePanel()
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(0..<DSPPreset.bandCount, id: \.self) { index in
                        EQFader(index: index, value: bandBinding(index))
                    }
                }
                .padding(14)
            }
            .consolePanel()
        }
    }

    private func bandBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { viewModel.selectedPreset.eqBandsDB[index] },
            set: { value in
                var bands = viewModel.selectedPreset.eqBandsDB
                bands[index] = value
                viewModel.editSelectedPreset(viewModel.selectedPreset.with(eqBandsDB: bands))
            }
        )
    }
}

private struct RoutingWorkbench: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        VStack(spacing: PerAppMixerLayout.sectionSpacing) {
            SignalChain(viewModel: viewModel)
                .frame(height: 82)
                .padding(12)
                .consolePanel()
            HStack(spacing: 8) {
                RoutingMatrix(viewModel: viewModel)
                ConsoleCard(title: "SYSTEM OUTPUT", icon: "speaker.wave.3.fill", color: SBColor.blue) {
                    VStack(alignment: .leading, spacing: 12) {
                        RoutePicker(label: "Virtual Device", value: viewModel.routeState.bridgeInputDeviceName ?? "SonicBloom Output")
                        RoutePicker(label: "Physical Output", value: viewModel.routeState.selectedPhysicalOutputName ?? "No output")
                        RoutePicker(label: "Device Profile", value: viewModel.deviceProfileSummary)
                        RoutePicker(label: "Format", value: "\(viewModel.routeState.channels) ch / \(Int(viewModel.routeState.sampleRate)) Hz")
                        Toggle("Compare raw audio", isOn: $viewModel.isBypassed)
                            .toggleStyle(.switch)
                            .disabled(!viewModel.isBridgeRunning)
                    }
                }
            }
            PerAppMixer(viewModel: viewModel)
                .frame(height: PerAppMixerLayout.panelHeight)
            RouteActionTray(viewModel: viewModel)
        }
    }
}

private struct RouteActionTray: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        HStack(spacing: 10) {
            ConsoleAction(title: "Refresh Route", icon: "arrow.clockwise", color: SBColor.blue) { viewModel.refreshRoute() }
            ConsoleAction(title: viewModel.primaryActionTitle, icon: viewModel.primaryActionIcon, color: SBColor.green) { viewModel.runPrimaryAction() }
            ConsoleAction(title: "Use Current Output", icon: "checkmark.circle", color: SBColor.yellow) { viewModel.useCurrentOutputAsPreferred() }
        }
        .padding(8)
        .frame(height: PerAppMixerLayout.routeActionTrayHeight)
        .background(SBColor.panel)
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(SBColor.line.opacity(0.95), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: SBColor.shadow, radius: 7, x: 0, y: 3)
    }
}

private struct PerAppMixer: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "APP PROFILES", icon: "app.connected.to.app.below.fill", color: SBColor.green) {
            VStack(spacing: 8) {
                HStack {
                    Text(viewModel.settings.applyAppProfilesAutomatically ? "AUTO-APPLIES TO FRONTMOST APP" : "SAVED PROFILES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SBColor.subtext)
                    Spacer()
                    Text("\(viewModel.appMixerItems.count) apps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SBColor.subtext)
                    Button("Refresh") { viewModel.refreshAppMixerRules() }
                        .font(.caption.weight(.bold))
                        .buttonStyle(SonicPressButtonStyle())
                        .foregroundStyle(SBColor.blue)
                }
                if !viewModel.settings.applyAppProfilesAutomatically {
                    Text("Saved here only. Enable automatic apply in Settings when you want foreground-app profiles to affect live audio.")
                        .font(.caption)
                        .foregroundStyle(SBColor.subtext)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if viewModel.appMixerItems.isEmpty {
                    Text("No regular apps detected")
                        .font(.caption)
                        .foregroundStyle(SBColor.subtext)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: PerAppMixerLayout.rowSpacing) {
                            ForEach(viewModel.appMixerItems) { item in
                                PerAppRuleRow(
                                    item: item,
                                    presets: viewModel.presets,
                                    setGain: { viewModel.setAppRuleGain(item.rule, gainDB: $0) },
                                    toggleMute: { viewModel.toggleAppRuleMute(item.rule) },
                                    setPreset: { viewModel.setAppRulePreset(item.rule, presetName: $0) },
                                    setSyncMode: { viewModel.setAppRuleSyncMode(item.rule, syncMode: $0) }
                                )
                            }
                        }
                        .padding(.trailing, 4)
                        .padding(.bottom, PerAppMixerLayout.bottomScrollClearance)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct PerAppRuleRow: View {
    var item: AppMixerItem
    var presets: [DSPPreset]
    var setGain: (Double) -> Void
    var toggleMute: () -> Void
    var setPreset: (String?) -> Void
    var setSyncMode: (AudioSyncMode?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleMute) {
                Image(systemName: rule.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(rule.isMuted ? SBColor.orange : statusColor)
                    .frame(width: 24)
            }
            .buttonStyle(SonicPressButtonStyle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text(item.captureStatus.rawValue.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12))
                        .clipShape(Capsule())
                    if item.canCreateProcessTap {
                        Text("TAP")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(SBColor.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(SBColor.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(rule.bundleIdentifier)
                    .font(.caption2)
                    .foregroundStyle(SBColor.subtext)
                    .lineLimit(1)
            }
            .frame(width: 210, alignment: .leading)
            Slider(
                value: Binding(get: { rule.gainDB }, set: { value in setGain(value) }),
                in: -24...12
            )
            .tint(rule.gainDB >= 0 ? SBColor.green : SBColor.orange)
            Text(String(format: "%.1f dB", rule.gainDB))
                .font(.caption.monospacedDigit())
                .foregroundStyle(SBColor.subtext)
                .frame(width: 58, alignment: .trailing)
            Picker("Preset", selection: Binding(get: { rule.presetName ?? "" }, set: { setPreset($0.isEmpty ? nil : $0) })) {
                Text("Follow Main").tag("")
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.name)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("Sync", selection: Binding(get: { rule.syncMode }, set: { setSyncMode($0) })) {
                Text("Follow").tag(AudioSyncMode?.none)
                ForEach(AudioSyncMode.allCases) { mode in
                    Text(mode.rawValue).tag(Optional(mode))
                }
            }
            .labelsHidden()
            .frame(width: 105)
        }
        .padding(8)
        .frame(minHeight: PerAppMixerLayout.rowMinHeight)
        .background(SBColor.panel2)
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(rule.isMuted ? SBColor.orange.opacity(0.45) : SBColor.line, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var rule: AppAudioRule {
        item.rule
    }

    private var statusColor: Color {
        switch item.captureStatus {
        case .ready: SBColor.green
        case .waitingForOutput: SBColor.blue
        case .silent: SBColor.orange
        case .unavailable, .notRunning: SBColor.subtext
        }
    }
}

private struct SpaceWorkbench: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        HStack(spacing: 8) {
            StereoField(viewModel: viewModel)
                .frame(width: 330)
            ConsoleCard(title: "SPATIAL ENGINE", icon: "dot.radiowaves.left.and.right", color: SBColor.red) {
                VStack(spacing: 16) {
                    MiniSlider(title: "HRTF IMAGE", value: binding(\.hrtfAmount), range: 0...1, color: SBColor.red)
                    MiniSlider(title: "AMBIENCE", value: binding(\.ambienceAmount), range: 0...1, color: SBColor.blue)
                    MiniSlider(title: "STEREO WIDTH", value: binding(\.widthAmount), range: 0...1, color: SBColor.green)
                    MiniSlider(title: "SPATIAL BLOOM", value: binding(\.spatialAmount), range: 0...1, color: SBColor.red)
                    MiniSlider(title: "CROSSFEED", value: binding(\.crossfeedAmount), range: 0...1, color: SBColor.green)
                }
            }
            ConsoleCard(title: "ROOM PRESETS", icon: "sparkles", color: SBColor.yellow) {
                VStack(spacing: 10) {
                    PresetApplyButton(title: "Headphones", subtitle: "Open image, soft crossfeed") { viewModel.selectPreset(.headphones) }
                    PresetApplyButton(title: "Movies", subtitle: "Wide HRTF and room tail") { viewModel.selectPreset(.movies) }
                    PresetApplyButton(title: "Night", subtitle: "Compressed late-night dynamics") { viewModel.selectPreset(.nightMode) }
                }
            }
            .frame(width: 300)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DSPPreset, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.selectedPreset[keyPath: keyPath] },
            set: { viewModel.editSelectedPreset(viewModel.selectedPreset.with(keyPath, $0)) }
        )
    }
}

private struct SettingsWorkbench: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                SetupGuideCard(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
                ConsoleCard(title: "APP SETTINGS", icon: "gearshape.fill", color: SBColor.blue) {
                    VStack(alignment: .leading, spacing: 16) {
                        SyncModePicker(selection: settingsBinding(\.syncMode))
                        ToggleRow(title: "Auto-enhance on launch", subtitle: "Start processing when SonicBloom opens.", isOn: settingsBinding(\.autoEnhanceOnLaunch))
                        ToggleRow(title: "Smart preset matching", subtitle: "Suggest stable presets from content energy.", isOn: settingsBinding(\.smartPresetMatching))
                        ToggleRow(title: "Apply App Profiles Automatically", subtitle: "Use saved foreground-app profiles when that app is active.", isOn: settingsBinding(\.applyAppProfilesAutomatically))
                        ToggleRow(title: "Loudness-matched compare", subtitle: "Keep raw A/B checks at the enhanced level.", isOn: settingsBinding(\.loudnessMatchedCompare))
                        ToggleRow(title: "Advanced controls", subtitle: "Expose spatial, HRTF, and crossfeed controls.", isOn: settingsBinding(\.showAdvancedControls))
                        ToggleRow(title: "Reduce motion", subtitle: "Calm scopes and moving meters.", isOn: settingsBinding(\.reduceMotion))
                        MiniSlider(title: "WAVEFORM INTENSITY", value: settingsBinding(\.waveformIntensity), range: 0...1, color: SBColor.red)
                    }
                }
            }
            .frame(width: 340)

            CalibrationWizard(viewModel: viewModel)
                .frame(minWidth: 360, maxWidth: .infinity)
                .layoutPriority(1)

            VStack(spacing: 12) {
                TrustPanel(viewModel: viewModel)
                AudioUnitEffectsCard(viewModel: viewModel)
                ConsoleCard(title: "MAINTENANCE", icon: "wrench.and.screwdriver", color: SBColor.yellow) {
                    VStack(spacing: 10) {
                        Text(viewModel.updateStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SBColor.subtext)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ConsoleAction(title: viewModel.isCheckingForUpdates ? "Checking..." : "Check for Updates", icon: "arrow.down.circle", color: SBColor.blue) {
                            Task { await viewModel.checkForUpdates() }
                        }
                        if viewModel.verifiedUpdatePackageURL != nil {
                            ConsoleAction(title: "Open Installer", icon: "shippingbox", color: SBColor.green) { viewModel.openUpdateDownload() }
                        } else if viewModel.updateDownloadURL != nil {
                            ConsoleAction(title: viewModel.isDownloadingUpdate ? "Downloading..." : "Download & Verify", icon: "checkmark.shield", color: SBColor.green) {
                                Task { await viewModel.downloadVerifiedUpdate() }
                            }
                        }
                        ConsoleAction(title: "Install Driver", icon: "arrow.down.circle", color: SBColor.green) { viewModel.installVirtualDevice() }
                        ConsoleAction(title: "Uninstall Driver", icon: "trash", color: SBColor.red) { viewModel.uninstallVirtualDevice() }
                        ConsoleAction(title: "Refresh Route", icon: "arrow.clockwise", color: SBColor.blue) { viewModel.refreshRoute() }
                        ConsoleAction(title: "Reset Settings", icon: "arrow.uturn.backward", color: SBColor.yellow) { viewModel.resetSettings() }
                    }
                }
                SafetyLimiter(viewModel: viewModel)
                    .frame(height: 150)
            }
            .frame(width: 300)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func settingsBinding(_ keyPath: WritableKeyPath<SonicBloomSettings, Bool>) -> Binding<Bool> {
        Binding(get: { viewModel.settings[keyPath: keyPath] }, set: { viewModel.settings[keyPath: keyPath] = $0 })
    }

    private func settingsBinding(_ keyPath: WritableKeyPath<SonicBloomSettings, Double>) -> Binding<Double> {
        Binding(get: { viewModel.settings[keyPath: keyPath] }, set: { viewModel.settings[keyPath: keyPath] = $0 })
    }

    private func settingsBinding(_ keyPath: WritableKeyPath<SonicBloomSettings, AudioSyncMode>) -> Binding<AudioSyncMode> {
        Binding(get: { viewModel.settings[keyPath: keyPath] }, set: { viewModel.settings[keyPath: keyPath] = $0 })
    }
}

private struct SetupGuideCard: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "SETUP GUIDE", icon: "checklist", color: viewModel.isSetupGuideComplete ? SBColor.green : SBColor.orange) {
            VStack(spacing: 8) {
                ForEach(viewModel.setupGuideSteps) { step in
                    SetupGuideRow(step: step) {
                        viewModel.runSetupGuideAction(step.id)
                    }
                }
            }
        }
    }
}

private struct SetupGuideRow: View {
    var step: FirstRunSetupStep
    var action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: step.isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.isComplete ? SBColor.green : SBColor.subtext)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(step.detail)
                    .font(.caption2)
                    .foregroundStyle(SBColor.subtext)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if !step.isComplete {
                Button(step.actionTitle, action: action)
                    .font(.caption.weight(.bold))
                    .buttonStyle(SonicPressButtonStyle())
                    .foregroundStyle(SBColor.blue)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(step.isComplete ? SBColor.green.opacity(0.08) : SBColor.panel2)
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(step.isComplete ? SBColor.green.opacity(0.32) : SBColor.line, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct CalibrationWizard: View {
    @ObservedObject var viewModel: SonicBloomViewModel
    @State private var tuning = CalibrationTuning()

    var body: some View {
        ConsoleCard(title: "CALIBRATION WIZARD", icon: "wand.and.stars", color: SBColor.green) {
            VStack(alignment: .leading, spacing: 10) {
                RoutePicker(label: "Output", value: viewModel.routeState.selectedPhysicalOutputName ?? "No output")
                if let matchedProfile = viewModel.matchedOutputProfile {
                    MatchedProfileRow(profile: matchedProfile) {
                        viewModel.applyHeadphoneProfile(matchedProfile)
                    }
                }
                Text("OUTPUT TYPE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SBColor.subtext)
                Picker("Output Type", selection: outputKindBinding) {
                    ForEach(CalibrationOutputKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    ConsoleAction(title: "Smart Start", icon: "sparkles", color: SBColor.green) { tuning = viewModel.suggestedCalibrationTuning }
                    ConsoleAction(title: "Play Tone", icon: "waveform", color: SBColor.blue) { viewModel.playCalibrationSound(.tone) }
                    ConsoleAction(title: "Play Noise", icon: "speaker.wave.2", color: SBColor.orange) { viewModel.playCalibrationSound(.noise) }
                }
                ConsoleAction(title: "Import AutoEQ Profile", icon: "square.and.arrow.down", color: SBColor.blue) {
                    viewModel.importAutoEQProfileFromPanel()
                }

                MiniSlider(title: "BASS RESPONSE", value: tuningBinding(\.bassPreference), range: 0...1, color: SBColor.yellow)
                MiniSlider(title: "CLARITY", value: tuningBinding(\.clarityPreference), range: 0...1, color: SBColor.blue)
                MiniSlider(title: "SPACE", value: tuningBinding(\.spatialPreference), range: 0...1, color: SBColor.green)
                MiniSlider(title: "LOUDNESS", value: tuningBinding(\.loudnessPreference), range: 0...1, color: SBColor.red)

                HStack(spacing: 8) {
                    ConsoleAction(title: "Save To Output", icon: "checkmark.circle", color: SBColor.green) { viewModel.applyCalibration(tuning) }
                    ConsoleAction(title: "Reset", icon: "arrow.uturn.backward", color: SBColor.yellow) { tuning = CalibrationTuning(outputKind: tuning.outputKind) }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(viewModel.availableHeadphoneProfiles) { profile in
                        Button {
                            viewModel.applyHeadphoneProfile(profile)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                Text(profile.manufacturer)
                                    .font(.caption2)
                                    .foregroundStyle(SBColor.subtext)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(SBColor.panel2)
                            .overlay { RoundedRectangle(cornerRadius: 7).stroke(SBColor.line, lineWidth: 1) }
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(SonicPressButtonStyle())
                    }
                }
            }
        }
        .onAppear {
            tuning = viewModel.suggestedCalibrationTuning
        }
    }

    private var outputKindBinding: Binding<CalibrationOutputKind> {
        Binding(get: { tuning.outputKind }, set: { tuning.outputKind = $0 })
    }

    private func tuningBinding(_ keyPath: WritableKeyPath<CalibrationTuning, Double>) -> Binding<Double> {
        Binding(
            get: { tuning[keyPath: keyPath] },
            set: { tuning[keyPath: keyPath] = min(max($0, 0), 1) }
        )
    }
}

private struct MatchedProfileRow: View {
    var profile: HeadphoneProfile
    var apply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MATCHED PROFILE")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(SBColor.green)
                Text("\(profile.manufacturer) \(profile.name)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(SBColor.green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SBColor.green.opacity(0.10))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(SBColor.green.opacity(0.28), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TrustPanel: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        ConsoleCard(title: "TRUST & HEALTH", icon: "checkmark.shield", color: SBColor.green) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.trustSummary.headline)
                        .font(.headline.weight(.black))
                    TrustSummaryRow(value: viewModel.trustSummary.clipping, color: SBColor.green)
                    TrustSummaryRow(value: viewModel.trustSummary.route, color: viewModel.routeState.isProcessingAvailable ? SBColor.green : SBColor.orange)
                    TrustSummaryRow(value: viewModel.trustSummary.cpu, color: viewModel.cpuUsagePercent > 15 ? SBColor.orange : SBColor.blue)
                }
                .padding(.bottom, 5)
                ForEach(viewModel.trustDiagnostics) { item in
                    TrustDiagnosticRow(item: item)
                }
            }
        }
    }
}

private struct AudioUnitEffectsCard: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    private var addableEffects: [AudioUnitEffectDescriptor] {
        let selectedIDs = Set(viewModel.profile.audioUnitEffects.map(\.id))
        return viewModel.availableAudioUnitEffects.filter { !selectedIDs.contains($0.id) }
    }

    var body: some View {
        ConsoleCard(title: "AUDIO UNITS", icon: "puzzlepiece.extension", color: SBColor.blue) {
            VStack(spacing: 8) {
                if viewModel.profile.audioUnitEffects.isEmpty {
                    Text("No pro effects inserted.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SBColor.subtext)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(SBColor.panel2)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    ForEach(viewModel.profile.audioUnitEffects) { slot in
                        AudioUnitEffectRow(slot: slot, viewModel: viewModel)
                    }
                }

                HStack(spacing: 8) {
                    Menu {
                        if addableEffects.isEmpty {
                            Text("No available effects")
                        } else {
                            ForEach(Array(addableEffects.prefix(20))) { effect in
                                Button(effect.name) { viewModel.addAudioUnitEffect(effect) }
                            }
                        }
                    } label: {
                        Label("Add Effect", systemImage: "plus.circle")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .menuStyle(.button)

                    Button {
                        viewModel.refreshAudioUnitEffects()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(SonicPressButtonStyle())
                }
            }
        }
    }
}

private struct AudioUnitEffectRow: View {
    var slot: AudioUnitEffectSlot
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.setAudioUnitEffectEnabled(slot.id, !slot.isEnabled)
            } label: {
                Image(systemName: slot.isEnabled ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(slot.isEnabled ? SBColor.green : SBColor.subtext)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SonicPressButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.effect.name)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(slot.effect.manufacturerName)
                    .font(.caption2)
                    .foregroundStyle(SBColor.subtext)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                viewModel.removeAudioUnitEffect(slot.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(SBColor.subtext)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SonicPressButtonStyle())
        }
        .padding(8)
        .background(slot.isEnabled ? SBColor.blue.opacity(0.10) : SBColor.panel2)
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(slot.isEnabled ? SBColor.blue.opacity(0.32) : SBColor.line, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct TrustSummaryRow: View {
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.10))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.28), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct TrustDiagnosticRow: View {
    var item: TrustDiagnostic

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SBColor.subtext)
                .frame(width: 60, alignment: .leading)
            Text(item.value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.10))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.32), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch item.tint {
        case .green: SBColor.green
        case .blue: SBColor.blue
        case .orange: SBColor.orange
        }
    }
}

private struct SyncModePicker: View {
    @Binding var selection: AudioSyncMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sync Mode")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(modeHint)
                    .font(.caption)
                    .foregroundStyle(SBColor.subtext)
            }
            Picker("Sync Mode", selection: $selection) {
                ForEach(AudioSyncMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .accessibilityLabel("Sync Mode")
    }

    private var modeHint: String {
        switch selection {
        case .auto: "smart"
        case .music: "full sound"
        case .video: "A/V sync"
        case .gaming: "lowest latency"
        }
    }
}

private struct ProcessingCard: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle()
                    .fill(viewModel.isBridgeRunning ? SBColor.green : SBColor.orange)
                    .frame(width: 11, height: 11)
                Text(viewModel.isBridgeRunning ? "PROCESSING ACTIVE" : "READY")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(viewModel.isBridgeRunning ? SBColor.green : SBColor.orange)
            }
            Label(routeText, systemImage: "record.circle")
                .font(.caption)
                .foregroundStyle(SBColor.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(routeText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((viewModel.isBridgeRunning ? SBColor.green : SBColor.orange).opacity(0.13))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke((viewModel.isBridgeRunning ? SBColor.green : SBColor.orange).opacity(0.55), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var routeText: String {
        "\(viewModel.routeState.bridgeInputDeviceName ?? "Output") -> \(viewModel.routeState.selectedPhysicalOutputName ?? "No output")"
    }
}

private struct PrimaryActionLabel: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .tint(viewModel.isBridgeRunning ? SBColor.orange : .white)
                Text("WORKING")
            } else {
                Image(systemName: viewModel.primaryActionIcon)
                Text(viewModel.isBridgeRunning ? "TURN OFF" : "ENHANCE")
            }
        }
        .font(.system(size: 14, weight: .bold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .foregroundStyle(viewModel.isBridgeRunning ? SBColor.orange : .white)
        .background(viewModel.isBridgeRunning ? SBColor.orange.opacity(0.22) : SBColor.green.opacity(0.84))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(viewModel.isBridgeRunning ? SBColor.orange : SBColor.green, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PresetButton: View {
    var preset: DSPPreset
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 24)
                    .foregroundStyle(selected ? SBColor.green : SBColor.subtext)
                Text(preset.name)
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(SBColor.green)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SBColor.green.opacity(0.22) : .clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(SBColor.green)
                        .frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SonicPressButtonStyle())
        .help("Use \(preset.name)")
    }

    private var icon: String {
        switch preset.name {
        case "Deep Bass": "speaker.wave.3.fill"
        case "Spoken Voice": "mic.fill"
        case "Tiny Speakers": "hifispeaker.fill"
        case "AirPods", "Headphones": "headphones"
        case "Movies": "film"
        case "Night Mode": "moon.fill"
        case "Manual": "line.3.horizontal.decrease"
        default: "waveform"
        }
    }
}

private struct SignalChain: View {
    @ObservedObject var viewModel: SonicBloomViewModel

    var body: some View {
        HStack(spacing: 10) {
            ChainNode(title: "INPUT", value: "Mac Audio", icon: "waveform", color: SBColor.green)
            ChainArrow(color: SBColor.green)
            ChainNode(title: "SONICBLOOM ENGINE", value: viewModel.selectedPreset.name, icon: "waveform.path", color: SBColor.blue)
            ChainArrow(color: SBColor.orange)
            ChainNode(title: "OUTPUT", value: viewModel.routeState.selectedPhysicalOutputName ?? "AudioBox USB", icon: "waveform", color: SBColor.orange)
        }
    }
}

private struct ChainNode: View {
    var title: String
    var value: String
    var icon: String
    var color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(value)
                    .font(.callout)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.10))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.45), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChainArrow: View {
    var color: Color

    var body: some View {
        Image(systemName: "arrow.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 30)
    }
}

private struct SpectrumAnalyzer: View {
    @ObservedObject var meterModel: SonicBloomMeterModel
    var preset: DSPPreset
    var isRunning: Bool
    var reduceMotion: Bool

    var body: some View {
        ZStack {
            MetalWaveformSurface(
                inputPeak: meterModel.meter.inputPeak,
                outputPeak: meterModel.meter.outputPeak,
                lowEnergy: meterModel.meter.lowEnergy,
                midEnergy: meterModel.meter.midEnergy,
                highEnergy: meterModel.meter.highEnergy,
                spectrumBands: meterModel.meter.spectrumBands,
                eqBandsDB: preset.eqBandsDB,
                isRunning: isRunning,
                reduceMotion: reduceMotion
            )
            .allowsHitTesting(false)
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 17) {
                        ForEach(["0", "-12", "-24", "-36", "-48", "-60"], id: \.self) { label in
                            Text(label)
                        }
                    }
                    Spacer()
                }
                Spacer()
                HStack {
                    ForEach(["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"], id: \.self) { label in
                        Text(label)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(SBColor.subtext.opacity(0.78))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(SBColor.scope)
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(SBColor.line.opacity(0.85), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LoudnessScope: View {
    @ObservedObject var meterModel: SonicBloomMeterModel

    var body: some View {
        ConsoleCard(title: "LOUDNESS", icon: nil, color: SBColor.green) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LUFS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SBColor.subtext)
                    Text(String(format: "%.1f", -18 + meterModel.meter.outputPeak * 10))
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(SBColor.green)
                }
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 0.0, through: Double(size.width), by: 7.0) {
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(grid, with: .color(SBColor.green.opacity(0.13)), lineWidth: 0.5)
                    var line = Path()
                    for i in 0...90 {
                        let t = CGFloat(i) / 90
                        let y = size.height * 0.48 + sin(t * 36 + CGFloat(meterModel.meter.inputPeak * 12)) * 4
                        if i == 0 { line.move(to: CGPoint(x: 0, y: y)) } else { line.addLine(to: CGPoint(x: t * size.width, y: y)) }
                    }
                    context.stroke(line, with: .color(SBColor.green), lineWidth: 1.4)
                }
            }
        }
    }
}

private struct HeadroomMeters: View {
    @ObservedObject var meterModel: SonicBloomMeterModel
    var compact: Bool

    var body: some View {
        ConsoleCard(title: "HEADROOM", icon: nil, color: SBColor.orange) {
            if compact {
                HStack(spacing: 10) {
                    Text(String(format: "%.1f dB", meterModel.meter.gainReductionDB))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(SBColor.orange)
                    Text("GR")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SBColor.subtext)
                    VerticalScale(value: min(meterModel.meter.outputPeak, 1), color: SBColor.green)
                        .frame(height: 46)
                }
            } else {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(format: "%.1f dB", meterModel.meter.gainReductionDB))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(SBColor.orange)
                        Text("GR")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(SBColor.subtext)
                    }
                    HStack(spacing: 20) {
                        VerticalScale(value: min(meterModel.meter.inputPeak, 1), color: SBColor.green)
                        VerticalScale(value: min(meterModel.meter.outputPeak, 1), color: SBColor.green)
                    }
                    HStack(spacing: 24) {
                        Text("L")
                        Text("R")
                    }
                    .font(.caption2)
                    .foregroundStyle(SBColor.subtext)
                }
            }
        }
    }
}

private struct VerticalScale: View {
    var value: Float
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(SBColor.panel2)
                VStack(spacing: 2) {
                    ForEach(0..<22, id: \.self) { index in
                        Rectangle()
                            .fill(segmentColor(index))
                            .opacity(segmentActive(index) ? 1 : 0.18)
                    }
                }
                .padding(3)
            }
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(SBColor.line, lineWidth: 1) }
            .frame(width: 17, height: height)
        }
        .frame(width: 18)
    }

    private func segmentActive(_ index: Int) -> Bool {
        let active = Int((min(max(value, 0), 1) * 22).rounded())
        return 21 - index < active
    }

    private func segmentColor(_ index: Int) -> Color {
        if index < 4 { return SBColor.red }
        if index < 9 { return SBColor.orange }
        return color
    }
}

private struct KnobControl: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var display: String
    var color: Color
    @State private var dragStart: Double?
    @State private var isHovering = false
    @State private var isDragging = false

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String, color: Color) {
        self.title = title
        self._value = value
        self.range = range
        self.display = display
        self.color = color
    }

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, display: @escaping (Double) -> String, color: Color) {
        self.title = title
        self._value = value
        self.range = range
        self.display = "__custom__"
        self.customDisplay = display
        self.color = color
    }

    private var customDisplay: ((Double) -> String)? = nil

    var body: some View {
        VStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
            }
            CircularKnob(value: normalized, color: color, isActive: isHovering || isDragging)
                .frame(width: 66, height: 66)
                .accessibilityLabel(title.isEmpty ? "EQ gain" : title)
                .accessibilityValue(label)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(SBColor.subtext)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .highPriorityGesture(knobDragGesture)
    }

    private var normalized: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func setNormalized(_ normalized: Double) {
        let clamped = min(max(normalized, 0), 1)
        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
    }

    private var label: String {
        if let customDisplay { return customDisplay(value) }
        return String(format: display, value)
    }

    private var knobDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { gesture in
                let start = dragStart ?? normalized
                dragStart = start
                isDragging = true
                setNormalized(start - gesture.translation.height / 140 + gesture.translation.width / 280)
            }
            .onEnded { _ in
                dragStart = nil
                isDragging = false
            }
    }
}

private struct CircularKnob: View {
    var value: Double
    var color: Color
    var isActive = false

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5)
            for tick in 0...10 {
                let tickAngle = CGFloat(Angle.degrees(-135 + Double(tick) / 10 * 270).radians)
                let outer = CGPoint(x: size.width / 2 + cos(tickAngle) * rect.width * 0.52, y: size.height / 2 + sin(tickAngle) * rect.height * 0.52)
                let inner = CGPoint(x: size.width / 2 + cos(tickAngle) * rect.width * 0.44, y: size.height / 2 + sin(tickAngle) * rect.height * 0.44)
                var tickPath = Path()
                tickPath.move(to: inner)
                tickPath.addLine(to: outer)
                context.stroke(tickPath, with: .color(SBColor.subtext.opacity(tick % 5 == 0 ? 0.75 : 0.34)), lineWidth: tick % 5 == 0 ? 1.2 : 0.7)
            }
            context.stroke(Path(ellipseIn: rect), with: .color(SBColor.line), lineWidth: 3)
            let angle = Angle.degrees(-135 + min(max(value, 0), 1) * 270)
            var arc = Path()
            arc.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: rect.width / 2, startAngle: .degrees(135), endAngle: angle, clockwise: false)
            context.stroke(arc, with: .color(color), lineWidth: 4)
            context.fill(Path(ellipseIn: rect.insetBy(dx: 11, dy: 11)), with: .color(SBColor.panel))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 11, dy: 11)), with: .color(SBColor.line.opacity(0.9)), lineWidth: 1)
            let pointer = CGPoint(
                x: size.width / 2 + cos(CGFloat(angle.radians)) * rect.width * 0.32,
                y: size.height / 2 + sin(CGFloat(angle.radians)) * rect.height * 0.32
            )
            var line = Path()
            line.move(to: CGPoint(x: size.width / 2, y: size.height / 2))
            line.addLine(to: pointer)
            context.stroke(line, with: .color(SBColor.text), lineWidth: 2)
        }
        .background(SBColor.panel2)
        .clipShape(Circle())
        .overlay { Circle().stroke(color.opacity(isActive ? 0.35 : 0.0), lineWidth: 2) }
        .scaleEffect(isActive ? 1.035 : 1)
        .shadow(color: color.opacity(isActive ? 0.18 : 0.06), radius: isActive ? 7 : 2, x: 0, y: isActive ? 3 : 1)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

private struct EQMiniKnob: View {
    var title: String
    var frequency: String
    @Binding var value: Double
    var color: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(frequency)
                .font(.caption2)
            KnobControl(title: "", value: $value, range: -12...12, display: "%.1f dB", color: color)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { Divider().overlay(SBColor.line) }
    }
}

private struct MiniSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(SBColor.subtext)
            }
            Slider(value: $value, in: range)
                .tint(color)
        }
    }
}

private struct EQResponseGraph: View {
    var bands: [Double]

    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: 0.0, through: Double(size.width), by: 45.0) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, through: Double(size.height), by: 24.0) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(SBColor.line.opacity(0.45)), lineWidth: 0.7)
            let midY = size.height * 0.5
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: midY)); zero.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(zero, with: .color(SBColor.subtext.opacity(0.5)), lineWidth: 1)

            var curve = Path()
            for index in 0..<max(bands.count, 1) {
                let x = CGFloat(index) / CGFloat(max(bands.count - 1, 1)) * size.width
                let db = CGFloat(min(max(index < bands.count ? bands[index] : 0, -12), 12))
                let y = midY - db / 12 * size.height * 0.38
                if index == 0 { curve.move(to: CGPoint(x: x, y: y)) } else { curve.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(curve, with: .color(SBColor.green), lineWidth: 2)
            for index in stride(from: 0, to: bands.count, by: 6) {
                let x = CGFloat(index) / CGFloat(max(bands.count - 1, 1)) * size.width
                let db = CGFloat(min(max(bands[index], -12), 12))
                let y = midY - db / 12 * size.height * 0.38
                context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(SBColor.green))
            }
        }
        .background(SBColor.scope)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct FrequencyLabels: View {
    var body: some View {
        HStack {
            ForEach(["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"], id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(SBColor.subtext)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }
}

private struct EQFader: View {
    var index: Int
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 7) {
            Text(String(format: "%.1f", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SBColor.subtext)
            Slider(value: $value, in: -12...12)
                .rotationEffect(.degrees(-90))
                .tint(value >= 0 ? SBColor.green : SBColor.orange)
                .frame(width: 132, height: 28)
            Text(freq)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SBColor.subtext)
                .frame(width: 34)
        }
        .frame(width: 38, height: 190)
    }

    private var freq: String {
        let labels = ["20", "25", "31", "40", "50", "63", "80", "100", "125", "160", "200", "250", "315", "400", "500", "630", "800", "1k", "1.2k", "1.6k", "2k", "2.5k", "3.1k", "4k", "5k", "6.3k", "8k", "10k", "12k", "16k", "20k"]
        return labels[index]
    }
}

private struct StereoVectorscope: View {
    @ObservedObject var meterModel: SonicBloomMeterModel
    var width: Double
    var spatial: Double

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.42
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(SBColor.line), lineWidth: 1)
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - radius, y: center.y)); cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - radius)); cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(cross, with: .color(SBColor.line.opacity(0.8)), lineWidth: 0.8)
                let output = CGFloat(min(max(meterModel.meter.outputPeak, 0.04), 1))
                for i in 0..<160 {
                    let t = CGFloat(i) / 160
                    let angle = t * .pi * 2
                    let r = radius * CGFloat(0.12 + output * 0.8) * CGFloat((sin(t * 31 + CGFloat(width) * 3) + 1) * 0.5)
                    let x = center.x + cos(angle) * r * CGFloat(0.38 + width)
                    let y = center.y + sin(angle) * r * CGFloat(0.3 + spatial)
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(SBColor.green.opacity(0.64)))
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(SBColor.yellow))
            }
            HStack {
                Text("L")
                Spacer()
                Text("R")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(SBColor.subtext)
            .padding(.horizontal, 8)
        }
        .background(SBColor.scope)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ConsoleCard<Content: View>: View {
    var title: String
    var icon: String?
    var color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consolePanel(accent: color.opacity(0.35))
    }
}

private struct MetricStack: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SBColor.subtext)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.16))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SonicLogo: View {
    var isRunning: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill((isRunning ? SBColor.green : SBColor.blue).opacity(0.16))
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(isRunning ? SBColor.green : SBColor.blue)
        }
    }
}

private struct RoutePicker: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(SBColor.subtext)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SBColor.panel2)
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(SBColor.line, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct ConsoleAction: View {
    var title: String
    var icon: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    ZStack {
                        SBColor.panel2
                        color.opacity(0.14)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.55), lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SonicPressButtonStyle())
    }
}

private struct PresetApplyButton: View {
    var title: String
    var subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SBColor.subtext)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SBColor.panel2)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(SBColor.line, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SonicPressButtonStyle())
    }
}

private struct ToggleRow: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SBColor.subtext)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct ConsoleBackdrop: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: 0.0, through: Double(size.width), by: 44.0) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, through: Double(size.height), by: 44.0) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(SBColor.line.opacity(0.07)), lineWidth: 0.6)
        }
        .background(SBColor.canvas)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct SonicPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private extension View {
    func consolePanel(accent: Color = SBColor.line) -> some View {
        background(SBColor.panel)
            .overlay { PanelTexture(accent: accent).allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: SBColor.shadow, radius: 9, x: 0, y: 4)
    }
}

private struct PanelTexture: View {
    var accent: Color

    var body: some View {
        ZStack {
            Canvas { context, size in
                var lines = Path()
                for y in stride(from: 6.0, through: Double(size.height), by: 9.0) {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(lines, with: .color(SBColor.text.opacity(0.014)), lineWidth: 0.6)
            }
            RoundedRectangle(cornerRadius: 12)
                .stroke(SBColor.text.opacity(0.035), lineWidth: 1)
                .padding(2)
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.48), lineWidth: 1)
        }
    }
}

private enum SBColor {
    static let canvas = Color(light: ns(0.945, 0.962, 0.956), dark: ns(0.01, 0.025, 0.028))
    static let panel = Color(light: ns(0.992, 0.997, 0.994), dark: ns(0.025, 0.055, 0.058))
    static let panel2 = Color(light: ns(0.935, 0.957, 0.95), dark: ns(0.045, 0.075, 0.078))
    static let tabActive = Color(light: ns(0.88, 0.935, 0.91), dark: ns(0.12, 0.14, 0.13))
    static let scope = Color(light: ns(0.955, 0.98, 0.972), dark: ns(0.015, 0.04, 0.043))
    static let text = Color(light: ns(0.04, 0.06, 0.07), dark: ns(0.88, 0.90, 0.88))
    static let subtext = Color(light: ns(0.35, 0.41, 0.42), dark: ns(0.62, 0.66, 0.66))
    static let line = Color(light: ns(0.76, 0.82, 0.805), dark: ns(0.17, 0.24, 0.25))
    static let green = Color(light: ns(0.02, 0.58, 0.27), dark: ns(0.19, 0.95, 0.39))
    static let blue = Color(light: ns(0.02, 0.45, 0.70), dark: ns(0.15, 0.78, 0.98))
    static let orange = Color(light: ns(0.86, 0.45, 0.04), dark: ns(1.00, 0.58, 0.08))
    static let yellow = Color(light: ns(0.78, 0.62, 0.05), dark: ns(0.92, 0.95, 0.18))
    static let red = Color(light: ns(0.82, 0.22, 0.20), dark: ns(1.00, 0.32, 0.34))
    static let purple = Color(light: ns(0.56, 0.36, 0.78), dark: ns(0.78, 0.56, 0.98))
    static let shadow = Color(light: .black.withAlphaComponent(0.08), dark: .black.withAlphaComponent(0.45))
}

private func ns(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
