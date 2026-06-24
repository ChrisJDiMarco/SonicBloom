import AppKit
import Foundation
import MetalKit
import SwiftUI

struct MetalWaveformSurface: NSViewRepresentable {
    var inputPeak: Float
    var outputPeak: Float
    var lowEnergy: Float
    var midEnergy: Float
    var highEnergy: Float
    var spectrumBands: [Float]
    var eqBandsDB: [Double]
    var isRunning: Bool
    var reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.948, green: 0.978, blue: 0.970, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = reduceMotion
        view.delegate = context.coordinator
        context.coordinator.configure(with: view)
        context.coordinator.update(
            inputPeak: inputPeak,
            outputPeak: outputPeak,
            lowEnergy: lowEnergy,
            midEnergy: midEnergy,
            highEnergy: highEnergy,
            spectrumBands: spectrumBands,
            eqBandsDB: eqBandsDB,
            isRunning: isRunning,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            inputPeak: inputPeak,
            outputPeak: outputPeak,
            lowEnergy: lowEnergy,
            midEnergy: midEnergy,
            highEnergy: highEnergy,
            spectrumBands: spectrumBands,
            eqBandsDB: eqBandsDB,
            isRunning: isRunning,
            reduceMotion: reduceMotion
        )

        let shouldAnimate = !reduceMotion
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = !shouldAnimate
        view.isPaused = !shouldAnimate
        if !shouldAnimate {
            view.draw()
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private struct Vertex {
            var position: SIMD4<Float>
            var color: SIMD4<Float>
        }

        private struct DrawRange {
            var primitive: MTLPrimitiveType
            var start: Int
            var count: Int
        }

        private struct Snapshot {
            var inputPeak: Float
            var outputPeak: Float
            var lowEnergy: Float
            var midEnergy: Float
            var highEnergy: Float
            var spectrumBands: [Float]
            var eqBands: [Float]
            var isRunning: Bool
            var reduceMotion: Bool
        }

        private let lock = NSLock()
        private var snapshot = Snapshot(
            inputPeak: 0.02,
            outputPeak: 0.02,
            lowEnergy: 0,
            midEnergy: 0,
            highEnergy: 0,
            spectrumBands: Array(repeating: 0, count: 31),
            eqBands: Array(repeating: 0, count: 31),
            isRunning: false,
            reduceMotion: false
        )
        private var smoothedInputPeak: Float = 0.02
        private var smoothedOutputPeak: Float = 0.02
        private var smoothedLowEnergy: Float = 0
        private var smoothedMidEnergy: Float = 0
        private var smoothedHighEnergy: Float = 0
        private var smoothedSpectrumBands = Array(repeating: Float(0), count: 31)
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var vertices: [Vertex] = []
        private var drawRanges: [DrawRange] = []
        private var startTime = CACurrentMediaTime()

        @MainActor
        func configure(with view: MTKView) {
            guard let device = view.device else { return }
            commandQueue = device.makeCommandQueue()

            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "waveform_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "waveform_fragment")
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
                vertexBuffer = device.makeBuffer(length: MemoryLayout<Vertex>.stride * 4_096, options: .storageModeShared)
                vertexBuffer?.label = "SonicBloom waveform vertices"
            } catch {
                assertionFailure("Metal waveform pipeline failed: \(error)")
            }
        }

        func update(
            inputPeak: Float,
            outputPeak: Float,
            lowEnergy: Float,
            midEnergy: Float,
            highEnergy: Float,
            spectrumBands: [Float],
            eqBandsDB: [Double],
            isRunning: Bool,
            reduceMotion: Bool
        ) {
            let sanitizedBands = eqBandsDB.prefix(31).map { Float(min(max($0, -12), 12)) }
            let sanitizedSpectrum = spectrumBands.prefix(31).map { min(max($0, 0), 1) }
            lock.lock()
            snapshot = Snapshot(
                inputPeak: min(max(inputPeak, 0.02), 1),
                outputPeak: min(max(outputPeak, 0.02), 1),
                lowEnergy: min(max(lowEnergy, 0), 1),
                midEnergy: min(max(midEnergy, 0), 1),
                highEnergy: min(max(highEnergy, 0), 1),
                spectrumBands: sanitizedSpectrum.isEmpty ? Array(repeating: 0, count: 31) : sanitizedSpectrum,
                eqBands: sanitizedBands.isEmpty ? Array(repeating: 0, count: 31) : sanitizedBands,
                isRunning: isRunning,
                reduceMotion: reduceMotion
            )
            lock.unlock()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let device = view.device,
                let drawable = view.currentDrawable,
                let renderPassDescriptor = view.currentRenderPassDescriptor,
                let commandBuffer = commandQueue?.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
                let pipelineState
            else { return }

            let state = smoothedSnapshot(from: currentSnapshot())
            let time = state.reduceMotion ? 0 : Float(CACurrentMediaTime() - startTime)
            buildGeometry(size: view.drawableSize, snapshot: state, time: time)
            guard !vertices.isEmpty else { return }

            let byteCount = MemoryLayout<Vertex>.stride * vertices.count
            if vertexBuffer == nil || (vertexBuffer?.length ?? 0) < byteCount {
                vertexBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
            }
            guard let vertexBuffer else { return }

            vertices.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    memcpy(vertexBuffer.contents(), baseAddress, byteCount)
                }
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            for range in drawRanges where range.count > 0 {
                encoder.drawPrimitives(type: range.primitive, vertexStart: range.start, vertexCount: range.count)
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func currentSnapshot() -> Snapshot {
            lock.lock()
            let value = snapshot
            lock.unlock()
            return value
        }

        private func smoothedSnapshot(from target: Snapshot) -> Snapshot {
            let alpha: Float = target.reduceMotion ? 1 : 0.14
            smoothedInputPeak += (target.inputPeak - smoothedInputPeak) * alpha
            smoothedOutputPeak += (target.outputPeak - smoothedOutputPeak) * alpha
            smoothedLowEnergy += (target.lowEnergy - smoothedLowEnergy) * alpha
            smoothedMidEnergy += (target.midEnergy - smoothedMidEnergy) * alpha
            smoothedHighEnergy += (target.highEnergy - smoothedHighEnergy) * alpha
            if smoothedSpectrumBands.count != target.spectrumBands.count {
                smoothedSpectrumBands = Array(repeating: 0, count: target.spectrumBands.count)
            }
            for index in target.spectrumBands.indices {
                smoothedSpectrumBands[index] += (target.spectrumBands[index] - smoothedSpectrumBands[index]) * alpha
            }
            return Snapshot(
                inputPeak: smoothedInputPeak,
                outputPeak: smoothedOutputPeak,
                lowEnergy: smoothedLowEnergy,
                midEnergy: smoothedMidEnergy,
                highEnergy: smoothedHighEnergy,
                spectrumBands: smoothedSpectrumBands,
                eqBands: target.eqBands,
                isRunning: target.isRunning,
                reduceMotion: target.reduceMotion
            )
        }

        private func buildGeometry(size: CGSize, snapshot: Snapshot, time: Float) {
            vertices.removeAll(keepingCapacity: true)
            drawRanges.removeAll(keepingCapacity: true)

            appendGrid()
            appendFilledSpectrum(snapshot: snapshot, time: time)
            appendBandHighlights(snapshot: snapshot)
            appendHarmonicRibbons(snapshot: snapshot, time: time)
            appendWaveLine(snapshot: snapshot, time: time)
            appendResponseLine(snapshot: snapshot)
        }

        private func appendGrid() {
            let color = SIMD4<Float>(0.31, 0.44, 0.42, 0.12)
            let start = vertices.count
            for index in 0...10 {
                let x = -1 + Float(index) * 0.2
                appendLine(from: SIMD2<Float>(x, -0.92), to: SIMD2<Float>(x, 0.92), color: color)
            }
            for index in 0...5 {
                let y = -0.92 + Float(index) * 0.368
                appendLine(from: SIMD2<Float>(-0.98, y), to: SIMD2<Float>(0.98, y), color: color)
            }
            appendLine(from: SIMD2<Float>(-0.98, 0.08), to: SIMD2<Float>(0.98, 0.08), color: SIMD4<Float>(0.00, 0.63, 0.32, 0.18))
            drawRanges.append(DrawRange(primitive: .line, start: start, count: vertices.count - start))
        }

        private func appendFilledSpectrum(snapshot: Snapshot, time: Float) {
            let start = vertices.count
            let samples = 320
            for index in 0...samples {
                let t = Float(index) / Float(samples)
                let x = -0.98 + t * 1.96
                let energy = spectrumEnergy(at: t, snapshot: snapshot, time: time)
                let y = spectrumY(energy)
                let alpha = 0.09 + energy * 0.30
                vertices.append(Vertex(position: SIMD4<Float>(x, -0.88, 0, 1), color: spectrumColor(t, alpha: 0.045)))
                vertices.append(Vertex(position: SIMD4<Float>(x, y, 0, 1), color: spectrumColor(t, alpha: alpha)))
            }
            drawRanges.append(DrawRange(primitive: .triangleStrip, start: start, count: vertices.count - start))
        }

        private func appendBandHighlights(snapshot: Snapshot) {
            let bands: [(Float, Float, SIMD4<Float>)] = [
                (0.18, bandLevel(snapshot.lowEnergy), SIMD4<Float>(0.00, 0.68, 0.66, 0.18)),
                (0.50, bandLevel(snapshot.midEnergy), SIMD4<Float>(0.02, 0.58, 0.27, 0.14)),
                (0.82, bandLevel(snapshot.highEnergy), SIMD4<Float>(0.86, 0.45, 0.04, 0.14))
            ]
            for (center, level, color) in bands where level > 0.02 {
                let halfWidth: Float = 0.045
                let x0 = -0.98 + (center - halfWidth) * 1.96
                let x1 = -0.98 + (center + halfWidth) * 1.96
                let top = spectrumY(level)
                let start = vertices.count
                vertices.append(Vertex(position: SIMD4<Float>(x0, -0.88, 0, 1), color: SIMD4<Float>(color.x, color.y, color.z, 0.03)))
                vertices.append(Vertex(position: SIMD4<Float>(x1, -0.88, 0, 1), color: SIMD4<Float>(color.x, color.y, color.z, 0.03)))
                vertices.append(Vertex(position: SIMD4<Float>(x0, top, 0, 1), color: color))
                vertices.append(Vertex(position: SIMD4<Float>(x1, top, 0, 1), color: color))
                drawRanges.append(DrawRange(primitive: .triangleStrip, start: start, count: 4))
            }
        }

        private func appendHarmonicRibbons(snapshot: Snapshot, time: Float) {
            let activity = snapshot.isRunning ? max(snapshot.outputPeak, snapshot.inputPeak, 0.04) : 0.02
            let ribbons: [(Float, Float, SIMD4<Float>)] = [
                (0.22, bandLevel(snapshot.lowEnergy), SIMD4<Float>(0.00, 0.63, 0.32, 0.34)),
                (0.52, bandLevel(snapshot.midEnergy), SIMD4<Float>(0.00, 0.50, 0.76, 0.30)),
                (0.78, bandLevel(snapshot.highEnergy), SIMD4<Float>(0.86, 0.25, 0.22, 0.24))
            ]
            for (center, level, color) in ribbons {
                let amplitude = max(level, activity * 0.18)
                appendPolyline(samples: 180, color: color) { t in
                    let x = -0.98 + t * 1.96
                    let bell = exp(-pow((t - center) * 5.0, 2.0))
                    let shimmer = sin(t * 28 + time * (1.4 + center)) * 0.018 * amplitude
                    let y = spectrumY(amplitude * bell * 0.72) + shimmer - 0.03
                    return SIMD2<Float>(x, min(max(y, -0.82), 0.72))
                }
            }
        }

        private func appendWaveLine(snapshot: Snapshot, time: Float) {
            let outputActivity = snapshot.isRunning ? max(snapshot.outputPeak, 0.04) : 0.02
            let inputActivity = snapshot.isRunning ? max(snapshot.inputPeak, 0.04) : 0.02
            appendPolyline(samples: 360, color: SIMD4<Float>(0.00, 0.50, 0.76, 0.88)) { t in
                let x = -0.98 + t * 1.96
                let energy = spectrumEnergy(at: t, snapshot: snapshot, time: time)
                let wave = sin(t * 112 + time * 3.7) * 0.034 * outputActivity
                let fine = sin(t * 287 + time * 6.2) * 0.010 * outputActivity
                return SIMD2<Float>(x, spectrumY(energy * 0.92) + wave + fine)
            }
            appendPolyline(samples: 300, color: SIMD4<Float>(0.90, 0.48, 0.03, 0.46)) { t in
                let x = -0.98 + t * 1.96
                let energy = spectrumEnergy(at: t, snapshot: snapshot, time: time) * (0.74 + inputActivity * 0.35)
                let wave = sin(t * 79 + time * 2.8) * 0.020 * inputActivity
                return SIMD2<Float>(x, spectrumY(energy) - 0.06 + wave)
            }
            appendPolyline(samples: 260, color: SIMD4<Float>(0.56, 0.36, 0.78, 0.36)) { t in
                let x = -0.98 + t * 1.96
                let air = bandLevel(snapshot.highEnergy)
                let wave = sin(t * 61 + time * 1.8) * 0.018 * air
                return SIMD2<Float>(x, spectrumY(air * exp(-pow((t - 0.82) * 3.6, 2.0))) - 0.18 + wave)
            }
        }

        private func appendResponseLine(snapshot: Snapshot) {
            let bands = snapshot.eqBands.isEmpty ? Array(repeating: Float(0), count: 31) : snapshot.eqBands
            for glow in 0..<3 {
                let alpha: Float = glow == 0 ? 0.84 : 0.18
                let yOffset = Float(glow - 1) * 0.012
                appendPolyline(samples: max(bands.count - 1, 1), color: SIMD4<Float>(0.00, 0.63, 0.32, alpha)) { t in
                    let rawIndex = t * Float(max(bands.count - 1, 1))
                    let lower = min(max(Int(rawIndex), 0), bands.count - 1)
                    let upper = min(lower + 1, bands.count - 1)
                    let mix = rawIndex - Float(lower)
                    let db = bands[lower] + (bands[upper] - bands[lower]) * mix
                    let x = -0.98 + t * 1.96
                    let y = 0.08 + db / 12 * 0.34 + sin(t * 18) * 0.025 + yOffset
                    return SIMD2<Float>(x, min(max(y, -0.72), 0.82))
                }
            }
        }

        private func appendPolyline(samples: Int, color: SIMD4<Float>, point: (Float) -> SIMD2<Float>) {
            let start = vertices.count
            for index in 0...samples {
                let t = Float(index) / Float(max(samples, 1))
                let p = point(t)
                vertices.append(Vertex(position: SIMD4<Float>(p.x, p.y, 0, 1), color: color))
            }
            drawRanges.append(DrawRange(primitive: .lineStrip, start: start, count: vertices.count - start))
        }

        private func spectrumEnergy(at t: Float, snapshot: Snapshot, time: Float) -> Float {
            let bands = snapshot.spectrumBands.isEmpty ? Array(repeating: Float(0), count: 31) : snapshot.spectrumBands
            let rawIndex = t * Float(max(bands.count - 1, 1))
            let lower = min(max(Int(rawIndex), 0), bands.count - 1)
            let upper = min(lower + 1, bands.count - 1)
            let mix = rawIndex - Float(lower)
            let measured = bands[lower] + (bands[upper] - bands[lower]) * mix
            let displayCeiling = max(bands.max() ?? 0, 0.000_6)
            let broadFallback = (
                bandLevel(snapshot.lowEnergy) * exp(-pow((t - 0.18) * 5.2, 2.0)) +
                bandLevel(snapshot.midEnergy) * exp(-pow((t - 0.52) * 3.0, 2.0)) +
                bandLevel(snapshot.highEnergy) * exp(-pow((t - 0.82) * 3.7, 2.0))
            ) * 0.12
            let activity = snapshot.isRunning ? max(snapshot.outputPeak, snapshot.inputPeak) : 0.02
            let activityGate = snapshot.isRunning ? min(max((activity - 0.018) / 0.18, 0), 1) : 0
            let floor: Float = snapshot.isRunning ? 0.025 : 0.006
            let activityFloor = activity * 0.05 + floor
            let normalizedShape = min(max(measured / displayCeiling, 0), 1)
            let readableShape = pow(normalizedShape, 0.58) * (0.06 + activityGate * 0.94)
            let absoluteEnergy = bandLevel(measured) * 0.42
            return min(max(max(readableShape, absoluteEnergy) + broadFallback + activityFloor, 0), 1)
        }

        private func bandLevel(_ value: Float) -> Float {
            min(max(pow(value * 2.8, 0.62), 0), 1)
        }

        private func spectrumY(_ energy: Float) -> Float {
            min(max(-0.86 + energy * 1.34, -0.86), 0.78)
        }

        private func appendLine(from: SIMD2<Float>, to: SIMD2<Float>, color: SIMD4<Float>) {
            vertices.append(Vertex(position: SIMD4<Float>(from.x, from.y, 0, 1), color: color))
            vertices.append(Vertex(position: SIMD4<Float>(to.x, to.y, 0, 1), color: color))
        }

        private func spectrumColor(_ t: Float, alpha: Float) -> SIMD4<Float> {
            if t < 0.38 {
                return SIMD4<Float>(0.00, 0.68, 0.66, alpha)
            }
            if t < 0.70 {
                return SIMD4<Float>(0.00, 0.63, 0.32, alpha)
            }
            if t < 0.86 {
                return SIMD4<Float>(0.90, 0.48, 0.03, alpha)
            }
            return SIMD4<Float>(0.56, 0.36, 0.78, alpha)
        }

        private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float4 position;
            float4 color;
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
        };

        vertex VertexOut waveform_vertex(const device VertexIn *vertices [[buffer(0)]],
                                         uint vertexID [[vertex_id]]) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position.xy, 0.0, 1.0);
            out.color = vertices[vertexID].color;
            return out;
        }

        fragment float4 waveform_fragment(VertexOut in [[stage_in]]) {
            return in.color;
        }
        """
    }
}
