import AppKit
import Foundation
@preconcurrency import MetalKit
import SonicBloomCore
import SwiftUI

struct MetalVisualizerSurface: NSViewRepresentable {
    var meter: DSPMeter
    var sourcePreset: VisualizerPreset?
    var targetPreset: VisualizerPreset
    var comboPreset: VisualizerPreset?
    var transitionProgress: Double
    var comboProgress: Double
    var visualizerSettings: VisualizerSettings
    var reduceMotion: Bool
    var renderSeed: UInt32
    var isRenderingEnabled: Bool

    private var targetFramesPerSecond: Int {
        if reduceMotion { return 24 }
        switch visualizerSettings.quality {
        case .performance: return 30
        case .adaptive: return 40
        case .cinematic: return 60
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.preferredFramesPerSecond = targetFramesPerSecond
        view.enableSetNeedsDisplay = false
        view.isPaused = !isRenderingEnabled
        view.delegate = context.coordinator
        context.coordinator.configure(with: view)
        context.coordinator.update(
            meter: meter,
            sourcePreset: sourcePreset,
            targetPreset: targetPreset,
            comboPreset: comboPreset,
            transitionProgress: transitionProgress,
            comboProgress: comboProgress,
            visualizerSettings: visualizerSettings,
            reduceMotion: reduceMotion,
            renderSeed: renderSeed,
            isRenderingEnabled: isRenderingEnabled
        )
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = targetFramesPerSecond
        if view.delegate == nil {
            view.delegate = context.coordinator
            context.coordinator.configure(with: view)
        }
        view.isPaused = !isRenderingEnabled
        context.coordinator.update(
            meter: meter,
            sourcePreset: sourcePreset,
            targetPreset: targetPreset,
            comboPreset: comboPreset,
            transitionProgress: transitionProgress,
            comboProgress: comboProgress,
            visualizerSettings: visualizerSettings,
            reduceMotion: reduceMotion,
            renderSeed: renderSeed,
            isRenderingEnabled: isRenderingEnabled
        )
        if isRenderingEnabled {
            view.draw()
        }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private struct Snapshot {
            var audio: VisualizerAudioFrame
            var sourcePreset: VisualizerPreset?
            var targetPreset: VisualizerPreset
            var comboPreset: VisualizerPreset?
            var transitionProgress: Double
            var comboProgress: Double
            var visualizerSettings: VisualizerSettings
            var reduceMotion: Bool
            var renderSeed: UInt32
        }

        private let lock = NSLock()
        private let analyzer = VisualizerAudioAnalyzer()
        private var engine: MetalVisualizerEngine?
        private var snapshot = Snapshot(
            audio: .silence,
            sourcePreset: nil,
            targetPreset: VisualizerPresetLibrary.fallbackPresets[0],
            comboPreset: nil,
            transitionProgress: 1,
            comboProgress: 0,
            visualizerSettings: .default,
            reduceMotion: false,
            renderSeed: 0
        )

        @MainActor
        func configure(with view: MTKView) {
            guard let device = view.device else { return }
            do {
                engine = try MetalVisualizerEngine(device: device, pixelFormat: view.colorPixelFormat)
            } catch {
                assertionFailure("Metal visualizer pipeline failed: \(error)")
            }
        }

        func update(
            meter: DSPMeter,
            sourcePreset: VisualizerPreset?,
            targetPreset: VisualizerPreset,
            comboPreset: VisualizerPreset?,
            transitionProgress: Double,
            comboProgress: Double,
            visualizerSettings: VisualizerSettings,
            reduceMotion: Bool,
            renderSeed: UInt32,
            isRenderingEnabled: Bool
        ) {
            guard isRenderingEnabled else { return }
            let audio = analyzer.ingest(meter)
            lock.lock()
            snapshot = Snapshot(
                audio: audio,
                sourcePreset: sourcePreset,
                targetPreset: targetPreset,
                comboPreset: comboPreset,
                transitionProgress: transitionProgress,
                comboProgress: comboProgress,
                visualizerSettings: visualizerSettings,
                reduceMotion: reduceMotion,
                renderSeed: renderSeed
            )
            lock.unlock()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let engine,
                let drawable = view.currentDrawable,
                let renderPassDescriptor = view.currentRenderPassDescriptor
            else { return }
            let value = currentSnapshot()
            engine.draw(
                drawable: drawable,
                renderPassDescriptor: renderPassDescriptor,
                drawableSize: view.drawableSize,
                state: VisualizerRenderState(
                    audio: value.audio,
                    sourcePreset: value.sourcePreset,
                    targetPreset: value.targetPreset,
                    comboPreset: value.comboPreset,
                    transitionProgress: value.transitionProgress,
                    comboProgress: value.comboProgress,
                    settings: value.visualizerSettings,
                    reduceMotion: value.reduceMotion,
                    renderSeed: value.renderSeed
                )
            )
        }

        private func currentSnapshot() -> Snapshot {
            lock.lock()
            let value = snapshot
            lock.unlock()
            return value
        }
    }
}
