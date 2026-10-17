import Foundation
import Metal
import QuartzCore
import SonicBloomCore

struct VisualizerRenderState {
    var audio: VisualizerAudioFrame
    var sourcePreset: VisualizerPreset?
    var targetPreset: VisualizerPreset
    var comboPreset: VisualizerPreset?
    var transitionProgress: Double
    var comboProgress: Double
    var settings: VisualizerSettings
    var reduceMotion: Bool
    var renderSeed: UInt32
}

private struct VisualizerUniforms {
    var time: Float
    var aspect: Float
    var intensity: Float
    var transition: Float

    var reduceMotion: Float
    var flashLimit: Float
    var priming: Float
    var seed: Float

    var beat: Float
    var beatPhase: Float
    var spectralFlux: Float
    var onset: Float

    var low: Float
    var mid: Float
    var high: Float
    var outputPeak: Float

    var palette0: SIMD4<Float>
    var palette1: SIMD4<Float>
    var palette2: SIMD4<Float>
    var palette3: SIMD4<Float>

    var moduleA: SIMD4<Float>
    var moduleB: SIMD4<Float>
    var generator: SIMD4<Float>
    var generatorB: SIMD4<Float>
    var morphA: SIMD4<Float>
    var morphB: SIMD4<Float>
    var controls: SIMD4<Float>
    var combo: SIMD4<Float>
    var reactive: SIMD4<Float>
    var phraseA: SIMD4<Float>
    var phraseB: SIMD4<Float>
    var sceneA: SIMD4<Float>
    var sceneB: SIMD4<Float>
    var equationA: SIMD4<Float>
    var equationB: SIMD4<Float>
    var sourceSignature: SIMD4<Float>
    var targetSignature: SIMD4<Float>
}

final class MetalVisualizerEngine {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pixelFormat: MTLPixelFormat
    private let warpPipeline: MTLRenderPipelineState
    private let generatorPipeline: MTLRenderPipelineState
    private let finalPipeline: MTLRenderPipelineState
    private var feedbackTextures: [MTLTexture] = []
    private var feedbackWidth = 0
    private var feedbackHeight = 0
    private var readIndex = 0
    private var frameIndex: UInt32 = 0
    private var bandBuffer: MTLBuffer?
    private let startTime = CACurrentMediaTime()

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        guard let queue = device.makeCommandQueue() else {
            throw VisualizerEngineError.commandQueueUnavailable
        }
        commandQueue = queue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        warpPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: pixelFormat,
            fragmentFunctionName: "visualizer_warp",
            blending: false
        )
        generatorPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: pixelFormat,
            fragmentFunctionName: "visualizer_generate",
            blending: true
        )
        finalPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pixelFormat: pixelFormat,
            fragmentFunctionName: "visualizer_final",
            blending: false
        )
    }

    func draw(
        drawable: any MTLDrawable,
        renderPassDescriptor descriptor: MTLRenderPassDescriptor,
        drawableSize: CGSize,
        state: VisualizerRenderState
    ) {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        encodeFrame(
            commandBuffer: commandBuffer,
            finalDescriptor: descriptor,
            size: drawableSize,
            state: state
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func renderOffscreen(size: CGSize, state: VisualizerRenderState) -> [UInt8]? {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard
            let target = device.makeTexture(descriptor: descriptor),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        encodeFrame(
            commandBuffer: commandBuffer,
            finalDescriptor: pass,
            size: CGSize(width: width, height: height),
            state: state
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        target.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return bytes
    }

    private func encodeFrame(
        commandBuffer: MTLCommandBuffer,
        finalDescriptor: MTLRenderPassDescriptor,
        size: CGSize,
        state: VisualizerRenderState
    ) {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        ensureFeedbackTextures(width: width, height: height)
        guard feedbackTextures.count == 2 else { return }

        updateBandBuffer(with: state.audio)
        let writeIndex = 1 - readIndex
        var uniforms = makeUniforms(size: CGSize(width: width, height: height), state: state, priming: frameIndex == 0)

        let warpPass = MTLRenderPassDescriptor()
        warpPass.colorAttachments[0].texture = feedbackTextures[writeIndex]
        warpPass.colorAttachments[0].loadAction = .clear
        warpPass.colorAttachments[0].storeAction = .store
        warpPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: warpPass) {
            encoder.setRenderPipelineState(warpPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
            encoder.setFragmentTexture(feedbackTextures[readIndex], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        let generatorPass = MTLRenderPassDescriptor()
        generatorPass.colorAttachments[0].texture = feedbackTextures[writeIndex]
        generatorPass.colorAttachments[0].loadAction = .load
        generatorPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: generatorPass) {
            encoder.setRenderPipelineState(generatorPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
            if let bandBuffer {
                encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 1)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        if feedbackTextures[writeIndex].mipmapLevelCount > 1,
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.generateMipmaps(for: feedbackTextures[writeIndex])
            blitEncoder.endEncoding()
        }

        finalDescriptor.colorAttachments[0].loadAction = .clear
        finalDescriptor.colorAttachments[0].storeAction = .store
        finalDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalDescriptor) {
            encoder.setRenderPipelineState(finalPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
            encoder.setFragmentTexture(feedbackTextures[writeIndex], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        readIndex = writeIndex
        frameIndex &+= 1
    }

    private func ensureFeedbackTextures(width: Int, height: Int) {
        guard width != feedbackWidth || height != feedbackHeight || feedbackTextures.count != 2 else { return }
        feedbackWidth = width
        feedbackHeight = height
        readIndex = 0
        frameIndex = 0

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        feedbackTextures = (0..<2).compactMap { index in
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = "SonicBloom visualizer feedback \(index)"
            return texture
        }
    }

    private func updateBandBuffer(with audio: VisualizerAudioFrame) {
        let bandCount = 32
        let count = bandCount * 2
        let length = MemoryLayout<Float>.stride * count
        if bandBuffer == nil || bandBuffer?.length != length {
            bandBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            bandBuffer?.label = "SonicBloom visualizer bands"
        }
        guard let bandBuffer else { return }
        let values = bandBuffer.contents().bindMemory(to: Float.self, capacity: count)
        for index in 0..<bandCount {
            values[index] = index < audio.bands.count ? audio.bands[index] : 0
            values[index + bandCount] = index < audio.bandDeltas.count ? max(audio.bandDeltas[index], 0) : 0
        }
    }

    private func makeUniforms(size: CGSize, state: VisualizerRenderState, priming: Bool) -> VisualizerUniforms {
        let source = state.sourcePreset ?? state.targetPreset
        let target = state.targetPreset
        let progress = Float(smoothstep(state.transitionProgress))
        let audio = state.audio
        let megapixels = Float(max(size.width * size.height, 1) / 1_000_000)
        let qualityScale: Float = {
            switch state.settings.quality {
            case .adaptive:
                return min(max(1.08 - max(0, megapixels - 1.0) * 0.10, 0.78), 1.08)
            case .performance: return 0.76
            case .cinematic: return 1.18
            }
        }()
        let motionScale: Float = state.reduceMotion ? 0.16 : 1
        let detailScale = Float(0.42 + state.settings.detailDensity * 0.52)
        let meterPeak = max(audio.outputPeak, audio.inputPeak)
        let audibleEnergy = min(audio.lowEnvelope * 0.42 + audio.midEnvelope * 0.32 + audio.highEnvelope * 0.26 + meterPeak * 0.44, 1)
        let transientEnergy = min(audio.onset * 0.78 + audio.spectralFlux * 0.55 + audio.beatConfidence * 0.50, 1)
        let audioLift = min(audibleEnergy * 0.55 + transientEnergy * 0.75, 1.25)
        let intensity = Float(state.settings.intensity) * qualityScale * (0.98 + audioLift * 0.18)
        let time = state.reduceMotion ? Float(0) : Float(CACurrentMediaTime() - startTime)
        let sourceReactive = source.reactiveParameters
        let targetReactive = target.reactiveParameters
        let warp = blend(
            sourceReactive.warp.value(from: audio),
            targetReactive.warp.value(from: audio),
            progress
        )
        let zoom = blend(
            sourceReactive.zoom.value(from: audio),
            targetReactive.zoom.value(from: audio),
            progress
        )
        let bloom = blend(
            sourceReactive.bloom.value(from: audio),
            targetReactive.bloom.value(from: audio),
            progress
        )
        let rotation = blend(
            sourceReactive.rotation.value(from: audio),
            targetReactive.rotation.value(from: audio),
            progress
        )
        let comboPreset = state.comboPreset ?? target
        let comboEnvelope = Float(smoothstep(state.comboProgress))
        let comboAudioLift = min(audio.spectralFlux * 0.09 + audio.beatConfidence * 0.05 + audio.onset * 0.06, 0.18)
        let comboStrength = state.comboPreset == nil ? 0 : min(comboEnvelope * (0.22 + Float(state.settings.detailDensity) * 0.11 + comboAudioLift), 0.42)
        let comboReactive = comboPreset.reactiveParameters
        let moduleA = SIMD4<Float>(
            blend(Float(source.modules.warp), Float(target.modules.warp), progress),
            blend(Float(source.modules.ribbons), Float(target.modules.ribbons), progress),
            blend(Float(source.modules.radialSpectrum), Float(target.modules.radialSpectrum), progress),
            blend(Float(source.modules.particles), Float(target.modules.particles), progress)
        )
        let moduleB = SIMD4<Float>(
            blend(Float(source.modules.bloom), Float(target.modules.bloom), progress),
            blend(Float(source.modules.waveform), Float(target.modules.waveform), progress),
            blend(Float(source.generators.symmetry), Float(target.generators.symmetry), progress),
            blend(Float(source.generators.tunnelDepth), Float(target.generators.tunnelDepth), progress)
        )
        let generator = SIMD4<Float>(
            blend(Float(source.generators.particleCount), Float(target.generators.particleCount), progress) * qualityScale * (0.50 + detailScale * 0.18),
            min(blend(Float(source.generators.radialComplexity), Float(target.generators.radialComplexity), progress) * (0.72 + detailScale * 0.16), 1.0),
            min(blend(Float(source.generators.ribbonCount), Float(target.generators.ribbonCount), progress) * (0.72 + detailScale * 0.16), 6),
            motionScale
        )
        let generatorB = SIMD4<Float>(
            blend(Float(source.generators.folds), Float(target.generators.folds), progress),
            blend(Float(source.generators.cellular), Float(target.generators.cellular), progress),
            blend(Float(source.generators.nebula), Float(target.generators.nebula), progress),
            blend(Float(source.generators.interference), Float(target.generators.interference), progress)
        )
        let morphA = SIMD4<Float>(
            blend(Float(source.morph.rate), Float(target.morph.rate), progress),
            blend(Float(source.morph.chaos), Float(target.morph.chaos), progress),
            blend(Float(source.morph.geometry), Float(target.morph.geometry), progress),
            blend(Float(source.morph.sceneBlend), Float(target.morph.sceneBlend), progress)
        )
        let morphB = SIMD4<Float>(
            blend(Float(source.morph.colorDrift), Float(target.morph.colorDrift), progress),
            blend(Float(source.morph.feedbackEcho), Float(target.morph.feedbackEcho), progress),
            blend(Float(source.morph.prism), Float(target.morph.prism), progress),
            blend(Float(source.morph.waveComplexity), Float(target.morph.waveComplexity), progress)
        )
        let phraseSeed = stableSeed("\(target.id):\(state.renderSeed)")
        let phraseClock = time * (0.12 + Float(target.morph.rate) * 0.48) * motionScale + phraseSeed * 6.28318531
        let phraseA = SIMD4<Float>(
            pulse(phraseClock + audio.beatPhase * audio.beatConfidence * 1.7),
            pulse(phraseClock * 0.63 + Float(target.generators.symmetry) * 3.1),
            pulse(phraseClock * 1.31 + Float(target.morph.chaos) * 2.4 + audio.spectralFlux),
            pulse(phraseClock * 0.41 + progress * 3.14159265 + comboStrength)
        )
        let phraseB = SIMD4<Float>(
            phraseSeed,
            stableSeed(source.id),
            stableSeed(comboPreset.id),
            pulse(phraseClock * 0.29 + audio.onset * 2.0 + audio.lowEnvelope)
        )
        let sceneCycleSeconds = max(Float(6.5), Float(target.transitionDuration) * (1.05 + Float(target.morph.sceneBlend) * 0.70))
        let scenePosition = Double((time * motionScale) / sceneCycleSeconds + phraseSeed * 23.0 + comboStrength * 0.33)
        let sceneStep = Int(floor(scenePosition))
        let sceneFraction = Float(scenePosition - floor(scenePosition))
        let sceneCrossfade = Float(smoothstep(Double(min(max((sceneFraction - 0.66) / 0.24, 0), 1))))
        let sceneSelectorA = stableSeed("\(target.id):\(state.renderSeed):scene:\(sceneStep)")
        let sceneSelectorB = stableSeed("\(target.id):\(state.renderSeed):scene:\(sceneStep + 1)")
        let sceneClock = time * (0.10 + Float(target.morph.rate) * 0.36) * motionScale + sceneSelectorA * 6.28318531
        let sceneA = SIMD4<Float>(
            sceneSelectorA,
            sceneSelectorB,
            sceneCrossfade,
            sceneFraction
        )
        let sceneB = SIMD4<Float>(
            pulse(sceneClock * 0.41 + audio.lowEnvelope * 1.7 + audio.beatConfidence),
            pulse(sceneClock * 0.67 + audio.midEnvelope * 1.3 + audio.spectralFlux),
            pulse(sceneClock * 0.89 + audio.highEnvelope * 1.1 + audio.onset),
            min(max(audio.onset * 0.60 + audio.spectralFlux * 0.34 + audio.beatConfidence * 0.24 + comboStrength * 0.55, 0), 1)
        )
        let equationCycleSeconds = max(Float(3.8), sceneCycleSeconds * (0.34 + Float(target.morph.chaos) * 0.18))
        let equationTimePosition = Double((time * motionScale) / equationCycleSeconds)
        let equationSeedOffset = Double(phraseSeed * 41.0)
        let equationRenderOffset = Double(state.renderSeed % 997) * 0.001
        let equationPosition = equationTimePosition + equationSeedOffset + equationRenderOffset
        let equationStep = Int(floor(equationPosition))
        let equationFraction = Float(equationPosition - floor(equationPosition))
        let equationCrossfade = Float(smoothstep(Double(min(max((equationFraction - 0.50) / 0.38, 0), 1))))
        let equationSelectorA = stableSeed("\(target.id):\(state.renderSeed):equation:\(equationStep)")
        let equationSelectorB = stableSeed("\(target.id):\(state.renderSeed):equation:\(equationStep + 1)")
        let equationClock = time * (0.18 + Float(target.morph.rate) * 0.52) * motionScale + equationSelectorA * 6.28318531
        let equationA = SIMD4<Float>(
            equationSelectorA,
            equationSelectorB,
            equationCrossfade,
            equationFraction
        )
        let equationB = SIMD4<Float>(
            pulse(equationClock * 0.53 + audio.lowEnvelope * 2.1 + audio.beatPhase),
            pulse(equationClock * 0.71 + audio.midEnvelope * 1.7 + audio.spectralFlux * 1.3),
            pulse(equationClock * 0.97 + audio.highEnvelope * 1.5 + audio.onset * 1.4),
            min(max(audio.spectralFlux * 0.48 + audio.onset * 0.52 + audio.outputPeak * 0.18 + comboStrength * 0.45, 0), 1)
        )
        let sourceSignature = SIMD4<Float>(
            stableSeed(source.id),
            stableSeed("\(source.id):modules"),
            stableSeed("\(source.id):scene"),
            stableSeed("\(source.id):equation")
        )
        let targetSignature = SIMD4<Float>(
            stableSeed(target.id),
            stableSeed("\(target.id):modules"),
            stableSeed("\(target.id):scene"),
            stableSeed("\(target.id):equation")
        )

        return VisualizerUniforms(
            time: time,
            aspect: Float(max(size.width, 1) / max(size.height, 1)),
            intensity: intensity,
            transition: progress,
            reduceMotion: state.reduceMotion ? 1 : 0,
            flashLimit: state.settings.flashLimitEnabled ? 1 : 0,
            priming: priming ? 1 : 0,
            seed: Float(state.renderSeed % 65_535) / 65_535,
            beat: audio.beatConfidence,
            beatPhase: audio.beatPhase,
            spectralFlux: audio.spectralFlux,
            onset: audio.onset,
            low: audio.lowEnvelope,
            mid: audio.midEnvelope,
            high: audio.highEnvelope,
            outputPeak: meterPeak,
            palette0: blend(blend(source.palette.background.simd, target.palette.background.simd, progress), comboPreset.palette.background.simd, comboStrength * 0.14),
            palette1: blend(blend(source.palette.primary.simd, target.palette.primary.simd, progress), comboPreset.palette.primary.simd, comboStrength * 0.28),
            palette2: blend(blend(source.palette.secondary.simd, target.palette.secondary.simd, progress), comboPreset.palette.secondary.simd, comboStrength * 0.32),
            palette3: blend(blend(source.palette.accent.simd, target.palette.accent.simd, progress), comboPreset.palette.accent.simd, comboStrength * 0.36),
            moduleA: blend(moduleA, SIMD4<Float>(
                Float(comboPreset.modules.warp),
                Float(comboPreset.modules.ribbons),
                Float(comboPreset.modules.radialSpectrum),
                Float(comboPreset.modules.particles)
            ), comboStrength * 0.44),
            moduleB: blend(moduleB, SIMD4<Float>(
                Float(comboPreset.modules.bloom),
                Float(comboPreset.modules.waveform),
                Float(comboPreset.generators.symmetry),
                Float(comboPreset.generators.tunnelDepth)
            ), comboStrength * 0.40),
            generator: blend(generator, SIMD4<Float>(
                Float(comboPreset.generators.particleCount) * qualityScale * (0.50 + detailScale * 0.18),
                min(Float(comboPreset.generators.radialComplexity) * (0.72 + detailScale * 0.16), 1.0),
                min(Float(comboPreset.generators.ribbonCount) * (0.72 + detailScale * 0.16), 6),
                motionScale
            ), comboStrength * 0.34),
            generatorB: blend(generatorB, SIMD4<Float>(
                Float(comboPreset.generators.folds),
                Float(comboPreset.generators.cellular),
                Float(comboPreset.generators.nebula),
                Float(comboPreset.generators.interference)
            ), comboStrength * 0.42),
            morphA: blend(morphA, SIMD4<Float>(
                Float(comboPreset.morph.rate),
                Float(comboPreset.morph.chaos),
                Float(comboPreset.morph.geometry),
                Float(comboPreset.morph.sceneBlend)
            ), comboStrength * 0.38),
            morphB: blend(morphB, SIMD4<Float>(
                Float(comboPreset.morph.colorDrift),
                Float(comboPreset.morph.feedbackEcho),
                Float(comboPreset.morph.prism),
                Float(comboPreset.morph.waveComplexity)
            ), comboStrength * 0.42),
            controls: SIMD4<Float>(
                Float(state.settings.detailDensity),
                Float(state.settings.bloomStrength),
                Float(min(max(state.settings.cycleSeconds / 300, 0), 1)),
                qualityScale
            ),
            combo: SIMD4<Float>(
                comboStrength,
                comboEnvelope,
                stableSeed(comboPreset.id),
                state.comboPreset == nil ? 0 : 1
            ),
            reactive: SIMD4<Float>(
                blend(warp, comboReactive.warp.value(from: audio), comboStrength * 0.32) * motionScale * (1 + audioLift * 1.05),
                blend(zoom, comboReactive.zoom.value(from: audio), comboStrength * 0.30) * motionScale * (1 + audioLift * 0.70),
                blend(bloom, comboReactive.bloom.value(from: audio), comboStrength * 0.34) * (1 + audioLift * 0.60),
                blend(rotation, comboReactive.rotation.value(from: audio), comboStrength * 0.34) * motionScale * (1 + audioLift * 0.85)
            ),
            phraseA: phraseA,
            phraseB: phraseB,
            sceneA: sceneA,
            sceneB: sceneB,
            equationA: equationA,
            equationB: equationB,
            sourceSignature: sourceSignature,
            targetSignature: targetSignature
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        pixelFormat: MTLPixelFormat,
        fragmentFunctionName: String,
        blending: Bool
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "visualizer_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunctionName)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = blending
        if blending {
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func blend(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private func blend(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }

    private func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func pulse(_ value: Float) -> Float {
        let t: Float = 0.5 + 0.5 * Float(sin(Double(value)))
        return t * t * (3 - 2 * t)
    }

    private func stableSeed(_ text: String) -> Float {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Float(hash % 65_535) / 65_535
    }

    enum VisualizerEngineError: Error {
        case commandQueueUnavailable
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct VisualizerUniforms {
        float time;
        float aspect;
        float intensity;
        float transition;

        float reduceMotion;
        float flashLimit;
        float priming;
        float seed;

        float beat;
        float beatPhase;
        float spectralFlux;
        float onset;

        float low;
        float mid;
        float high;
        float outputPeak;

        float4 palette0;
        float4 palette1;
        float4 palette2;
        float4 palette3;

        float4 moduleA;
        float4 moduleB;
        float4 generator;
        float4 generatorB;
        float4 morphA;
        float4 morphB;
        float4 controls;
        float4 combo;
        float4 reactive;
        float4 phraseA;
        float4 phraseB;
        float4 sceneA;
        float4 sceneB;
        float4 equationA;
        float4 equationB;
        float4 sourceSignature;
        float4 targetSignature;
    };

    vertex VertexOut visualizer_vertex(uint vertexID [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = positions[vertexID] * 0.5 + 0.5;
        return out;
    }

    float hash11(float n) {
        return fract(sin(n) * 43758.5453123);
    }

    float angleDistance(float a, float b) {
        float d = fmod(a - b + 9.42477796, 6.28318531) - 3.14159265;
        return abs(d);
    }

    float bandAt(float position, constant float *bands) {
        float scaled = clamp(position, 0.0, 1.0) * 30.0;
        int lower = int(floor(scaled));
        int upper = min(lower + 1, 30);
        float mixValue = scaled - float(lower);
        return mix(bands[lower], bands[upper], mixValue);
    }

    float bandDeltaAt(float position, constant float *bands) {
        float scaled = clamp(position, 0.0, 1.0) * 30.0;
        int lower = int(floor(scaled));
        int upper = min(lower + 1, 30);
        float mixValue = scaled - float(lower);
        return mix(bands[32 + lower], bands[32 + upper], mixValue);
    }

    float2 rotate2(float2 p, float a) {
        float c = cos(a);
        float s = sin(a);
        return float2(p.x * c - p.y * s, p.x * s + p.y * c);
    }

    float hash21(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
    }

    float noise2(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float fbm(float2 p) {
        float value = 0.0;
        float amp = 0.5;
        float2 shift = float2(19.17, 7.31);
        for (int i = 0; i < 5; ++i) {
            value += amp * noise2(p);
            p = rotate2(p * 2.03 + shift, 0.58);
            amp *= 0.5;
        }
        return value;
    }

    float voronoi(float2 p) {
        float2 cell = floor(p);
        float2 local = fract(p);
        float best = 8.0;
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                float2 offset = float2(float(x), float(y));
                float2 randomPoint = float2(
                    hash21(cell + offset),
                    hash21(cell + offset + 17.13)
                );
                randomPoint = 0.5 + 0.5 * sin(6.28318531 * randomPoint);
                float2 diff = offset + randomPoint - local;
                best = min(best, dot(diff, diff));
            }
        }
        return sqrt(best);
    }

    float2 kaleido(float2 p, float amount) {
        float folds = mix(2.0, 11.0, clamp(amount, 0.0, 1.0));
        float sector = 6.28318531 / folds;
        float a = atan2(p.y, p.x);
        float r = length(p);
        a = fmod(a + sector * 0.5 + 18.8495559, sector) - sector * 0.5;
        return float2(cos(abs(a)), sin(abs(a))) * r;
    }

    float lineField(float value, float width) {
        return exp(-abs(value) / max(width, 0.0001));
    }

    float butterchurnSmoothWave(float position, constant float *bands) {
        float stepSize = 1.0 / 31.0;
        float c1 = -0.15;
        float c2 = 1.15;
        float c3 = 1.15;
        float c4 = -0.15;
        float invSum = 1.0 / (c1 + c2 + c3 + c4);
        return max(0.0,
            (bandAt(position - stepSize, bands) * c1
                + bandAt(position, bands) * c2
                + bandAt(position + stepSize, bands) * c3
                + bandAt(position + stepSize * 2.0, bands) * c4) * invSum
        );
    }

    float softCycle(float value) {
        float pulse = 0.5 + 0.5 * sin(value);
        return pulse * pulse * (3.0 - 2.0 * pulse);
    }

    float morphClock(constant VisualizerUniforms &u, float multiplier) {
        return u.time * (0.035 + u.morphA.x * 0.145) * multiplier
            + u.seed * 6.28318531
            + u.beatPhase * u.beat * (0.25 + u.morphA.y * 0.45);
    }

    float circular01Distance(float a, float b) {
        return abs(fract(a - b + 0.5) - 0.5) * 2.0;
    }

    float sceneFamilyGate(float selector, float family, float width) {
        return smoothstep(width, 0.0, circular01Distance(selector, family));
    }

    float sceneBlendGate(constant VisualizerUniforms &u, float family) {
        float incoming = sceneFamilyGate(u.sceneA.x, family, 0.22);
        float outgoing = sceneFamilyGate(u.sceneA.y, family, 0.22);
        return clamp(mix(incoming, outgoing, u.sceneA.z), 0.0, 1.0);
    }

    float equationBlendGate(constant VisualizerUniforms &u, float family) {
        float incoming = sceneFamilyGate(u.equationA.x, family, 0.20);
        float outgoing = sceneFamilyGate(u.equationA.y, family, 0.20);
        return clamp(mix(incoming, outgoing, u.equationA.z), 0.0, 1.0);
    }

    float equationClock(constant VisualizerUniforms &u, float multiplier) {
        return morphClock(u, multiplier)
            + u.equationA.x * 12.5663706
            + u.equationA.w * (0.9 + u.morphA.y * 1.6)
            + dot(u.equationB.xyz, float3(0.31, 0.43, 0.57));
    }

    float4 compositionDirector(float2 p, constant VisualizerUniforms &u) {
        float clock = equationClock(u, 0.34);
        float radius = length(p);
        float angle = atan2(p.y, p.x);
        float2 focus = float2(
            cos(clock * 0.37 + u.sceneA.x * 6.28318531),
            sin(clock * 0.29 + u.equationA.y * 6.28318531)
        ) * float2(max(u.aspect, 0.001), 1.0) * (0.10 + u.morphA.w * 0.22);
        float focusWindow = 1.0 - smoothstep(0.18 + u.low * 0.04, 0.64 + u.morphA.w * 0.16, length(p - focus));
        float leadingLine = smoothstep(0.86, 0.16, abs(sin(angle * (1.0 + u.moduleB.z * 4.0) + radius * (2.5 + u.generator.y * 4.0) - clock)));
        float calmPocket = 1.0 - smoothstep(0.34, 0.88, u.outputPeak + u.spectralFlux * 0.55 + u.onset * 0.35);
        float focalEnergy = clamp(max(focusWindow, leadingLine * 0.58) + u.beat * 0.10, 0.0, 1.0);
        float density = clamp(0.58 + u.controls.x * 0.20 + u.onset * 0.10 + u.beat * 0.08 - u.combo.x * 0.10 - calmPocket * 0.08, 0.42, 0.92);
        float background = (0.82 + calmPocket * 0.16 + (1.0 - focalEnergy) * 0.08) * (0.92 + smoothstep(1.10, 0.18, radius) * 0.12);
        float foreground = 0.74 + focalEnergy * 0.34 + u.onset * 0.08;
        float negative = 0.72 + focalEnergy * 0.25 + calmPocket * 0.10;
        return float4(background, foreground, density, negative);
    }

    float butterchurnBlendPattern(float2 p, constant VisualizerUniforms &u) {
        float2 normalized = p / float2(max(u.aspect, 0.001), 1.0);
        float blendSeed = fract(u.sourceSignature.x * 1.31 + u.targetSignature.x * 2.17 + u.seed * 0.23);
        float ang = blendSeed * 6.28318531 + u.sceneA.x * 3.14159265;
        float2 direction = float2(cos(ang), sin(ang));
        float diagonal = dot(normalized, direction) * 0.70710678 + 0.5;
        float radial = length(normalized) * 1.41421356;
        radial = mix(radial, 1.0 - radial, step(0.5, fract(blendSeed * 9.17 + u.sceneA.y)));
        float plasma = fbm(normalized * (1.7 + u.morphA.y * 3.2) + float2(blendSeed * 17.0, u.time * 0.030));
        float rings = 0.5 + 0.5 * sin(length(p) * (5.0 + u.generatorB.x * 9.0) - atan2(p.y, p.x) * (1.0 + u.moduleB.z * 4.0) + ang);
        float mode = fract(blendSeed * 3.19 + u.sceneA.x * 2.7 + u.equationA.x * 1.3);
        float mask = mix(diagonal, radial, smoothstep(0.18, 0.44, mode));
        mask = mix(mask, plasma, smoothstep(0.46, 0.72, mode));
        mask = mix(mask, rings, smoothstep(0.74, 0.96, mode) * (0.35 + u.morphA.z * 0.35));
        float blendBand = 0.07 + hash11(blendSeed * 41.0 + u.sceneA.y * 29.0) * 0.18;
        return clamp((mask - blendBand * 0.5) / max(1.0 - blendBand, 0.001), 0.0, 1.0);
    }

    float sdBox(float2 p, float2 size) {
        float2 d = abs(p) - size;
        return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0);
    }

    float sdDiamond(float2 p, float radius) {
        p = abs(p);
        return (p.x + p.y - radius) * 0.70710678;
    }

    float superShapeRadius(float theta, float morph, float audio) {
        float m = mix(3.0, 10.0, morph);
        float n1 = 0.35 + audio * 1.20;
        float n2 = 0.65 + morph * 1.70;
        float n3 = 0.75 + (1.0 - morph) * 1.40;
        float a = pow(abs(cos(m * theta * 0.25)), n2);
        float b = pow(abs(sin(m * theta * 0.25)), n3);
        return pow(max(a + b, 0.0001), -1.0 / n1);
    }

    float2 flowField(float2 p, float time, float chaos) {
        float n0 = fbm(p * (1.8 + chaos * 4.0) + float2(time * 0.13, -time * 0.09));
        float n1 = fbm(rotate2(p, 1.57079633) * (2.1 + chaos * 3.2) - float2(time * 0.07, time * 0.11));
        return float2(n0 - 0.5, n1 - 0.5);
    }

    float2 curlFlowField(float2 p, float time, float chaos) {
        float e = 0.055;
        float scale = 1.2 + chaos * 3.6;
        float2 drift = float2(time * 0.10, -time * 0.08);
        float top = fbm(p * scale + float2(0.0, e) + drift);
        float bottom = fbm(p * scale - float2(0.0, e) + drift);
        float right = fbm(p * scale + float2(e, 0.0) - drift.yx);
        float left = fbm(p * scale - float2(e, 0.0) - drift.yx);
        float2 curl = float2(top - bottom, left - right) / (2.0 * e);
        return curl / (1.0 + length(curl));
    }

    float2 moebiusFold(float2 p, float amount, float phase) {
        float2 c = float2(cos(phase), sin(phase * 0.73 + 1.7)) * (0.12 + amount * 0.34);
        float2 q = p + c;
        float denom = max(dot(q, q), 0.075);
        float2 inv = float2(q.x, -q.y) / denom - c * 0.62;
        return mix(p, inv, amount * 0.46);
    }

    float logPolarLine(float2 p, float radialScale, float angularScale, float phase) {
        float radius = length(p) + 0.035;
        float angle = atan2(p.y, p.x);
        float v = sin(log(radius) * radialScale + angle * angularScale + phase);
        return lineField(v, 0.10);
    }

    float fractalTrap(float2 p, float seed, float amount) {
        float2 z = p;
        float trap = 0.0;
        float scale = 1.0 + amount * 1.8;
        for (int i = 0; i < 6; ++i) {
            z = abs(z);
            z = rotate2(z, 0.35 + seed * 1.7 + float(i) * 0.23);
            float denom = max(dot(z, z), 0.045);
            z = z / denom - float2(0.62 + amount * 0.36, 0.42 - amount * 0.18);
            trap += exp(-abs(length(z) - (0.58 + float(i) * 0.035)) * (3.6 + amount * 8.0)) / (float(i) + 1.0);
            z *= scale;
        }
        return clamp(trap * 0.36, 0.0, 1.0);
    }

    float sdSegment(float2 p, float2 a, float2 b) {
        float2 pa = p - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
        return length(pa - ba * h);
    }

    float spatialTransitionMask(float2 p, constant VisualizerUniforms &u) {
        float mask = butterchurnBlendPattern(p, u);
        float shimmer = fbm(p * (2.2 + u.morphA.y * 2.0) + float2(u.time * 0.018, u.seed * 13.0));
        return clamp(mix(mask, shimmer, u.combo.x * 0.16), 0.0, 1.0);
    }

    float butterchurnSnapGate(constant VisualizerUniforms &u) {
        return step(0.5, u.transition);
    }

    float butterchurnSnapValue(float sourceValue, float targetValue, constant VisualizerUniforms &u) {
        return mix(sourceValue, targetValue, butterchurnSnapGate(u));
    }

    float butterchurnMorphMask(float2 p, constant VisualizerUniforms &u) {
        float mask = spatialTransitionMask(p, u);
        float band = 0.055 + hash11(u.sourceSignature.x * 31.0 + u.targetSignature.x * 47.0 + u.seed * 13.0) * 0.15;
        return smoothstep(mask - band, mask + band, u.transition);
    }

    float butterchurnMorphEdge(float2 p, constant VisualizerUniforms &u) {
        float mask = spatialTransitionMask(p, u);
        float progressGate = smoothstep(0.02, 0.22, u.transition) * (1.0 - smoothstep(0.78, 0.98, u.transition));
        return exp(-abs(mask - u.transition) * (13.0 + u.morphA.y * 22.0)) * progressGate;
    }

    float motionVectorGlyph(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float2 normalized = p / float2(max(u.aspect, 0.001), 1.0);
        float2 gridScale = float2(6.0 + u.moduleB.z * 5.0, 4.5 + u.generator.y * 4.0);
        float2 grid = normalized * gridScale + 0.5;
        float2 cell = floor(grid);
        float2 local = fract(grid) - 0.5;
        float h = hash21(cell + u.seed * 31.0);
        float b = bandAt(h, bands);
        float d = bandDeltaAt(fract(h + 0.23), bands);
        float angle = h * 6.28318531 + u.time * (0.08 + b * 0.18) * u.generator.w + u.reactive.w * 0.35;
        float2 direction = float2(cos(angle), sin(angle));
        float lengthScale = 0.12 + b * 0.22 + u.onset * 0.08;
        float width = 0.016 + u.high * 0.012 + d * 0.006;
        float mark = exp(-sdSegment(local, -direction * lengthScale, direction * lengthScale) / max(width, 0.001));
        float head = exp(-length(local - direction * lengthScale) / (0.032 + u.onset * 0.018));
        float cellFade = smoothstep(0.62, 0.18, length(local));
        return (mark * 0.72 + head * 0.36) * cellFade * (0.22 + b * 0.62 + d * 0.78);
    }

    float customWaveLoopField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float normAngle = fract(angle / 6.28318531 + 0.5 + u.beatPhase * 0.03);
        float b = bandAt(normAngle, bands);
        float d = bandDeltaAt(fract(normAngle + 0.11), bands);
        float family = softCycle(morphClock(u, 0.31) + u.seed * 4.0);
        float harmonic = sin(angle * (3.0 + floor(u.generatorB.x * 8.0)) + u.time * (0.18 + u.morphB.w * 0.35));
        float targetRadius = 0.24 + u.moduleB.z * 0.08 + b * 0.22 + harmonic * (0.024 + u.morphB.w * 0.045);
        float contour = exp(-abs(radius - targetRadius) * (27.0 + u.high * 25.0));
        float lissajous = sin(p.x * (5.0 + u.morphB.w * 12.0) + u.time * 0.46)
            + cos(p.y * (4.0 + u.generator.y * 10.0) - u.time * 0.37 + u.seed * 3.0);
        float lissaLine = lineField(lissajous, 0.105 + u.mid * 0.055);
        float rose = sin(angle * (2.0 + u.morphA.z * 9.0) + radius * (8.0 + u.generator.y * 10.0) - u.time * (0.35 + u.morphA.x));
        float roseLine = lineField(rose, 0.13 + u.low * 0.05);
        return mix(contour, mix(lissaLine, roseLine, family), 0.42 + u.morphA.z * 0.38) * (0.18 + b * 0.54 + d * 0.84);
    }

    float classicWaveformModes(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float normX = clamp((p.x / max(u.aspect, 0.001)) + 0.5, 0.0, 1.0);
        float snapEquation = butterchurnSnapValue(u.sourceSignature.w, u.targetSignature.w, u);
        float selector = fract(snapEquation * 5.0 + floor(morphClock(u, 0.18)) * 0.137 + u.equationA.y * 0.41);
        float bX = butterchurnSmoothWave(normX, bands);
        float dX = bandDeltaAt(normX, bands);
        float bA = butterchurnSmoothWave(fract(angle / 6.28318531 + 0.5), bands);
        float circular = exp(-abs(radius - (0.22 + bA * 0.28 + sin(angle * (4.0 + u.morphB.w * 8.0) + u.time * 0.34) * 0.024)) * (24.0 + u.high * 24.0));
        float radial = exp(-abs(radius - (0.28 + bA * 0.24 + u.mid * 0.04)) * (30.0 + u.mid * 18.0));
        float xY = exp(-abs(p.y - (bX - 0.42) * (0.55 + u.morphB.w * 0.24) - sin(normX * 48.0 + u.time * 0.41) * 0.018) * (23.0 + u.outputPeak * 24.0));
        float trebXY = xY * (0.52 + u.high * u.high * 0.75);
        float mystery = u.phraseA.y * 2.0 - 1.0;
        float momentum = 0.45 + 0.50 * (mystery * 0.5 + 0.5);
        float momentumLine = exp(-abs(p.y - ((bX - 0.42) * (0.48 + momentum * 0.28) + sin(normX * 11.0 + u.time * 0.23) * 0.035)) * (24.0 + dX * 34.0));
        float rotating = exp(-abs(dot(rotate2(p, u.time * 0.19 + u.seed * 6.28318531), normalize(float2(0.8, 0.6))) - (bX - 0.5) * 0.32) * (22.0 + dX * 28.0));
        float lineAngle = 1.57079633 * mystery + u.phraseB.x * 1.2;
        float2 lineP = rotate2(p, -lineAngle);
        float lineNorm = clamp(lineP.x / max(u.aspect, 0.001) + 0.5, 0.0, 1.0);
        float lineBand = butterchurnSmoothWave(lineNorm, bands) - 0.42;
        float angledSingle = exp(-abs(lineP.y - lineBand * 0.34) * (27.0 + u.outputPeak * 24.0));
        float sep = pow(u.phraseA.y * 0.5 + 0.5, 2.0) * (0.08 + u.morphB.w * 0.13);
        float angledDouble = exp(-abs(abs(lineP.y - lineBand * 0.24) - sep) * (30.0 + u.high * 24.0));
        float dotChain = 0.0;
        for (int i = 0; i < 24; ++i) {
            float fi = float(i);
            float t = fi / 23.0;
            float band = butterchurnSmoothWave(t, bands);
            float phi = t * 6.28318531 + u.time * (0.08 + u.morphA.x * 0.30) + u.seed * 2.0;
            float2 pos = float2(cos(phi), sin(phi * (1.0 + u.morphA.z * 0.20))) * (0.16 + band * 0.38);
            pos.x *= u.aspect;
            dotChain += exp(-length(p - pos) / (0.010 + band * 0.012 + u.onset * 0.010)) * (0.12 + band * 0.45 + bandDeltaAt(t, bands) * 0.85);
        }
        float lineBlend =
            circular * sceneFamilyGate(selector, 0.06, 0.11)
            + radial * sceneFamilyGate(selector, 0.18, 0.11)
            + xY * sceneFamilyGate(selector, 0.30, 0.11)
            + trebXY * sceneFamilyGate(selector, 0.42, 0.11)
            + momentumLine * sceneFamilyGate(selector, 0.54, 0.11)
            + rotating * sceneFamilyGate(selector, 0.66, 0.11)
            + angledSingle * sceneFamilyGate(selector, 0.78, 0.11)
            + angledDouble * sceneFamilyGate(selector, 0.90, 0.11)
            + dotChain * sceneFamilyGate(selector, fract(0.02 + u.phraseB.y * 0.25), 0.08) * 0.42;
        return lineBlend * (0.22 + u.moduleB.y * 0.62 + u.morphB.w * 0.22);
    }

    float4 milkdropWaveStackField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float normX = clamp(p.x / max(u.aspect, 0.001) + 0.5, 0.0, 1.0);
        float normAngle = fract(angle / 6.28318531 + 0.5);
        float clock = equationClock(u, 1.08);
        float selector = fract(u.equationA.x * 8.0 + u.phraseB.x * 3.0);
        float bass = bandAt(normAngle, bands);
        float treble = bandAt(fract(normAngle + 0.31), bands);
        float transient = bandDeltaAt(fract(normAngle + 0.13), bands);
        float horizontalTarget = (bandAt(normX, bands) - 0.42) * (0.46 + u.morphB.w * 0.32)
            + sin(normX * (18.0 + u.generator.y * 34.0) + clock) * (0.018 + u.high * 0.040);
        float horizontal = exp(-abs(p.y - horizontalTarget) * (28.0 + u.outputPeak * 30.0));
        float polarTarget = 0.20 + bass * 0.26
            + sin(angle * (3.0 + floor(u.generatorB.x * 9.0)) - clock * 0.72) * (0.020 + u.morphA.z * 0.052);
        float polar = exp(-abs(radius - polarTarget) * (30.0 + u.high * 24.0));
        float2 lissa = float2(
            sin(clock * 0.73 + normX * 6.28318531),
            sin(clock * 0.51 + normX * (9.0 + u.morphB.w * 10.0))
        ) * (0.18 + treble * 0.20 + u.low * 0.05);
        lissa.x *= u.aspect;
        float lissajous = exp(-length(p - lissa) / (0.013 + treble * 0.018 + transient * 0.010));
        float rosette = lineField(
            sin(angle * (5.0 + floor(selector * 8.0)) + radius * (12.0 + u.generator.y * 12.0) - clock * 1.28),
            0.10 + u.mid * 0.045
        );
        float stackA = mix(horizontal, polar, smoothstep(0.10, 0.42, selector));
        float stackB = mix(lissajous, rosette, smoothstep(0.55, 0.90, selector));
        float mixValue = smoothstep(0.30, 0.70, u.equationA.w);
        float line = mix(stackA, stackB, mixValue);
        float dots = pow(max(line, 0.0), 2.6) * (0.55 + transient * 1.30 + u.onset * 0.45);
        float ghost = exp(-abs(radius - polarTarget * (1.20 + u.equationB.y * 0.34)) * (13.0 + u.mid * 11.0));
        return float4(line, dots, ghost, selector) * (0.18 + bass * 0.56 + transient * 0.84);
    }

    float regularPolygonDistance(float2 p, float sides, float radius, float rotation) {
        float angle = atan2(p.y, p.x) + rotation;
        float sector = 6.28318531 / max(sides, 3.0);
        float folded = cos(floor(0.5 + angle / sector) * sector - angle) * length(p);
        return folded - radius;
    }

    float4 customShapeActorField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float4 accum = float4(0.0);
        float clock = morphClock(u, 0.44);
        float numInst = 4.0 + floor(u.generatorB.z * 4.0 + u.phraseA.z * 2.0);
        for (int i = 0; i < 8; ++i) {
            if (float(i) >= numInst) { continue; }
            float fi = float(i) + 1.0;
            float h = hash11(fi * 19.37 + u.seed * 31.0);
            float orbit = clock * (0.28 + h * 0.72) + fi * 1.57079633 + u.beatPhase * u.beat * 0.55;
            float2 center = float2(cos(orbit), sin(orbit * (0.72 + h * 0.36) + fi)) * (0.10 + h * 0.30 + u.low * 0.035);
            center.x *= u.aspect;
            float2 q = rotate2(p - center, orbit * (0.35 + u.morphA.z * 0.45));
            float b = bandAt(fract(h + fi * 0.137), bands);
            float d = bandDeltaAt(fract(h + fi * 0.173), bands);
            float sides = 3.0 + floor(hash11(fi * 7.1 + u.seed * 9.0) * 9.0);
            float radius = 0.040 + h * 0.082 + b * 0.045 + d * 0.032;
            float poly = regularPolygonDistance(q, sides, radius, h * 6.28318531);
            float border = exp(-abs(poly) * (52.0 + u.high * 42.0));
            float fill = smoothstep(0.025, -0.020, poly);
            float texZoom = 0.75 + h * 1.80 + u.morphB.y * 0.70;
            float texAng = orbit + h * 6.28318531 + u.phraseB.y * 3.14159265;
            float2 texP = rotate2(q, texAng) / max(texZoom, 0.08);
            float texFill = fill * smoothstep(0.30, 0.84, fbm(texP * (13.0 + sides * 1.4) + float2(clock * 0.18, h * 12.0)));
            float thickoutline = smoothstep(0.62, 0.96, h + u.morphA.z * 0.20);
            border = mix(border, max(border, exp(-abs(poly) * (22.0 + u.high * 18.0))), thickoutline * 0.45);
            float additiveSpark = exp(-length(q) / max(0.006, radius * (0.18 + d * 0.26))) * (0.14 + d * 0.60);
            float gate = 0.45 + 0.55 * softCycle(clock * (0.52 + h * 0.40) + fi);
            accum.x += fill * gate * (0.08 + b * 0.30);
            accum.y += border * gate * (0.18 + b * 0.42 + d * 0.52);
            accum.z += texFill * gate * (0.10 + u.morphA.y * 0.28);
            accum.w += additiveSpark * gate * (0.05 + u.onset * 0.20);
        }
        return clamp(accum, float4(0.0), float4(2.2));
    }

    float borderGlow(float2 uv, constant VisualizerUniforms &u) {
        float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
        float outer = exp(-edge * (42.0 + u.controls.x * 30.0));
        float innerDistance = abs(edge - (0.018 + u.morphB.y * 0.024 + u.beat * 0.006));
        float inner = exp(-innerDistance * (95.0 + u.high * 80.0));
        return (outer * 0.38 + inner * 0.62) * (0.18 + u.morphB.y * 0.42 + u.onset * 0.32);
    }

    float darkenCenterAmount(float2 center, constant VisualizerUniforms &u) {
        float radius = length(center);
        return exp(-radius * radius * (3.8 + u.morphA.y * 3.2)) * (0.55 + u.moduleA.z * 0.30) * (1.0 - u.beat * 0.20);
    }

    float2 echoUV(float2 uv, constant VisualizerUniforms &u, float orientation) {
        float2 q = (uv - 0.5) * float2(u.aspect, 1.0);
        float snapScene = butterchurnSnapValue(u.sourceSignature.z, u.targetSignature.z, u);
        float echo_orientation = floor(fract(snapScene * 3.7 + orientation * 0.159) * 4.0);
        float orient_x = mix(1.0, -1.0, fmod(echo_orientation, 2.0));
        float orient_y = mix(1.0, -1.0, step(2.0, echo_orientation));
        q = rotate2(q, orientation);
        float echo_zoom = 1.0 + u.morphB.y * 0.10 + u.moduleB.w * 0.030 + u.low * 0.015;
        q = q * (1.0 / echo_zoom) * float2(orient_x, orient_y);
        q = rotate2(q, -orientation * 0.62);
        return q / float2(max(u.aspect, 0.001), 1.0) + 0.5;
    }

    float2 milkdropVideoEchoUV(float2 uv, constant VisualizerUniforms &u) {
        float2 q = (uv - 0.5) * float2(u.aspect, 1.0);
        float selector = fract(u.equationA.y * 4.0 + u.phraseA.w);
        q = rotate2(q, floor(selector * 4.0) * 1.57079633 + equationClock(u, 0.18) * 0.08);
        q *= 1.0 / (1.015 + u.morphB.y * 0.060 + u.low * 0.018);
        if (selector > 0.50) {
            q.x *= -1.0;
        }
        if (selector > 0.75) {
            q.y *= -1.0;
        }
        q += float2(u.equationB.x - 0.5, u.equationB.y - 0.5) * 0.030 * u.morphA.y;
        return q / float2(max(u.aspect, 0.001), 1.0) + 0.5;
    }

    float3 solarizeGrade(float3 color, float amount) {
        float3 solar = color * (1.0 - color) * 4.0;
        return mix(color, solar, clamp(amount, 0.0, 1.0));
    }

    float3 butterchurnCompositeFlags(float3 color, float3 hueShaderColor, constant VisualizerUniforms &u, float whiteWash) {
        float snapEquation = butterchurnSnapValue(u.sourceSignature.w, u.targetSignature.w, u);
        float flagSelector = fract(snapEquation * 5.0 + u.equationA.x * 2.31 + u.equationA.y * 3.17 + u.phraseA.w * 1.13);
        float fShader = smoothstep(0.20, 0.94, u.morphB.x) * (0.12 + u.combo.x * 0.10 + u.sceneB.z * 0.06);
        float gammaAdj = 0.92 + u.equationB.x * 0.18 + u.morphB.x * 0.08 - whiteWash * 0.06;
        color = pow(max(color, float3(0.0)), float3(1.0 / max(gammaAdj, 0.25)));
        color *= mix(float3(1.0), hueShaderColor, fShader);

        float brightenFlag = sceneFamilyGate(flagSelector, 0.12, 0.14);
        float darkenFlag = sceneFamilyGate(flagSelector, 0.38, 0.14);
        float solarizeFlag = sceneFamilyGate(flagSelector, 0.64, 0.14);
        float invertFlag = sceneFamilyGate(flagSelector, 0.88, 0.12);
        color = mix(color, sqrt(max(color, float3(0.0))), brightenFlag * (0.035 + u.high * 0.035 + u.onset * 0.020));
        color = mix(color, color * color, darkenFlag * (0.030 + u.low * 0.040));
        color = solarizeGrade(color, solarizeFlag * (0.020 + u.morphA.y * 0.035 + u.beat * 0.015));
        color = mix(color, float3(1.0) - color, invertFlag * (0.018 + u.morphB.z * 0.030));
        return max(color, float3(0.0));
    }

    float hash31(float3 p) {
        return fract(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453123);
    }

    float noise3(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        float n000 = hash31(i + float3(0.0, 0.0, 0.0));
        float n100 = hash31(i + float3(1.0, 0.0, 0.0));
        float n010 = hash31(i + float3(0.0, 1.0, 0.0));
        float n110 = hash31(i + float3(1.0, 1.0, 0.0));
        float n001 = hash31(i + float3(0.0, 0.0, 1.0));
        float n101 = hash31(i + float3(1.0, 0.0, 1.0));
        float n011 = hash31(i + float3(0.0, 1.0, 1.0));
        float n111 = hash31(i + float3(1.0, 1.0, 1.0));
        float nx00 = mix(n000, n100, u.x);
        float nx10 = mix(n010, n110, u.x);
        float nx01 = mix(n001, n101, u.x);
        float nx11 = mix(n011, n111, u.x);
        return mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
    }

    float fbm3(float3 p) {
        float value = 0.0;
        float amp = 0.5;
        for (int i = 0; i < 5; ++i) {
            value += amp * noise3(p);
            p = p * 2.02 + float3(17.1, 9.2, 5.7);
            amp *= 0.5;
        }
        return value;
    }

    float3 hueShader(float2 uv, constant VisualizerUniforms &u) {
        float clock = u.time * (0.22 + u.morphB.x * 0.55) + u.phraseB.x * 6.28318531;
        float3 h00 = 0.58 + 0.34 * sin(float3(clock * 0.73 + 3.0, clock * 0.59 + 1.0, clock * 0.67 + 6.0));
        float3 h10 = 0.58 + 0.34 * sin(float3(clock * 0.91 + 8.0, clock * 0.47 + 4.0, clock * 0.62 + 2.0));
        float3 h01 = 0.58 + 0.34 * sin(float3(clock * 0.52 + 11.0, clock * 0.86 + 7.0, clock * 0.43 + 5.0));
        float3 h11 = 0.58 + 0.34 * sin(float3(clock * 0.68 + 13.0, clock * 0.74 + 10.0, clock * 0.57 + 9.0));
        h00 = 0.45 + 0.55 * h00 / max(max(h00.r, h00.g), max(h00.b, 0.001));
        h10 = 0.45 + 0.55 * h10 / max(max(h10.r, h10.g), max(h10.b, 0.001));
        h01 = 0.45 + 0.55 * h01 / max(max(h01.r, h01.g), max(h01.b, 0.001));
        h11 = 0.45 + 0.55 * h11 / max(max(h11.r, h11.g), max(h11.b, 0.001));
        float2 w = smoothstep(float2(0.0), float2(1.0), uv);
        return mix(mix(h01, h11, w.x), mix(h00, h10, w.x), w.y);
    }

    float3 proceduralTextureBank(float2 p, constant VisualizerUniforms &u) {
        float clock = morphClock(u, 0.74);
        float2 texP = rotate2(p, u.phraseA.y * 3.14159265) * (1.4 + u.generator.y * 4.2);
        float clouds = fbm3(float3(texP * (1.2 + u.morphA.y * 2.0), clock * 0.07 + u.phraseB.x * 4.0));
        float marble = 0.5 + 0.5 * sin(texP.x * (5.0 + u.morphB.w * 7.0) + fbm(texP * 2.7) * 4.0 + clock);
        float weave = abs(sin(texP.x * (10.0 + u.moduleB.z * 16.0) + clock * 0.30) * sin(texP.y * (9.0 + u.generatorB.x * 12.0) - clock * 0.24));
        float grain = hash21(floor(texP * (22.0 + u.controls.x * 42.0)) + floor(clock * 0.8));
        float fluid = smoothstep(0.20, 0.84, clouds * 0.56 + marble * 0.30 + weave * 0.14);
        float3 cloudColor = mix(u.palette0.rgb, u.palette2.rgb, clouds);
        float3 marbleColor = mix(u.palette1.rgb, u.palette3.rgb, marble);
        float3 weaveColor = mix(u.palette2.rgb, u.palette3.rgb, pow(weave, 4.0));
        float3 tex = mix(cloudColor, marbleColor, u.phraseA.x);
        tex = mix(tex, weaveColor, u.phraseA.z * 0.55);
        tex += u.palette3.rgb * (grain - 0.5) * 0.08 * u.controls.x;
        return tex * (0.22 + fluid * 0.78);
    }

    float4 liquidGlassField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float clock = equationClock(u, 0.56);
        float2 curl = curlFlowField(p + u.equationA.xy * 0.37, clock, u.morphA.y);
        float2 q = p * (1.35 + u.generatorB.z * 2.1 + u.controls.x * 0.45)
            + curl * (0.24 + u.low * 0.20 + u.equationB.w * 0.14);
        q = rotate2(q, u.phraseB.x * 6.28318531 + clock * 0.045);
        float angle = atan2(p.y, p.x);
        float band = bandAt(fract(angle / 6.28318531 + 0.5 + u.equationB.x * 0.13), bands);
        float delta = bandDeltaAt(fract(length(p) * 0.72 + u.equationB.y * 0.21), bands);
        float n = fbm(q * (1.8 + u.morphA.y * 2.4) + curl * 0.8);
        float waveA = sin(q.x * (4.0 + u.generator.y * 7.0) + n * 4.2 - clock * 0.72);
        float waveB = sin(rotate2(q, 1.04719755).y * (5.0 + u.moduleB.z * 8.0) - n * 3.3 + clock * 0.51);
        float caustic = pow(max(0.0, 1.0 - abs(waveA) * 0.62 - abs(waveB) * 0.46), 3.1);
        float vein = lineField(sin(dot(q, normalize(float2(0.72, 0.42))) * (7.0 + u.generatorB.w * 9.0) + n * 5.0 + clock), 0.09 + u.mid * 0.050);
        float openWater = 0.62 + 0.38 * smoothstep(0.16, 0.86, abs(sin(angle * (1.0 + u.moduleB.z * 3.0) + clock * 0.10)));
        float shadow = smoothstep(0.46, 0.88, n) * (0.10 + u.morphB.y * 0.16 + u.low * 0.08);
        float energy = 0.16 + band * 0.45 + delta * 0.82 + u.outputPeak * 0.10;
        return float4(caustic * energy * openWater, vein * energy * openWater, shadow, n);
    }

    float reactionDiffusionField(float2 p, constant VisualizerUniforms &u) {
        float clock = morphClock(u, 0.58);
        float2 q = p * (2.8 + u.generator.y * 5.4 + u.morphA.y * 3.0);
        float a = fbm(q + float2(clock * 0.13, -clock * 0.07));
        float b = fbm(rotate2(q, 1.57079633) * 1.23 - float2(clock * 0.05, clock * 0.11));
        float laplace = abs(a - b);
        float cells = voronoi(q * (1.2 + u.generatorB.y * 2.6) + float2(u.phraseB.x * 12.0, clock * 0.09));
        float inhibitor = smoothstep(0.18, 0.72, cells + laplace * 0.65);
        float activator = smoothstep(0.20, 0.85, a * (1.0 - b) + u.low * 0.10 + u.onset * 0.08);
        return clamp(activator * (1.0 - inhibitor * 0.72) + lineField(laplace - 0.18, 0.055) * 0.35, 0.0, 1.0);
    }

    float metaballField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float clock = morphClock(u, 0.36);
        float field = 0.0;
        for (int i = 0; i < 6; ++i) {
            float fi = float(i) + 1.0;
            float h = hash11(fi * 3.71 + u.phraseB.z * 13.0);
            float2 c = float2(cos(clock * (0.22 + h * 0.32) + fi * 1.7), sin(clock * (0.17 + h * 0.25) + fi * 2.1)) * (0.12 + 0.36 * h);
            c.x *= u.aspect;
            float b = bandAt(fract(h + fi * 0.131), bands);
            float d = bandDeltaAt(fract(h + fi * 0.197), bands);
            float r = 0.030 + b * 0.070 + d * 0.055 + u.beat * 0.015;
            field += (r * r) / max(dot(p - c, p - c), 0.002);
        }
        return smoothstep(0.72, 1.55, field) * (0.5 + 0.5 * smoothstep(1.55, 3.3, field));
    }

    float2 mirrorTileFold(float2 p, constant VisualizerUniforms &u, float amount) {
        float scale = 1.0 + floor(2.0 + amount * 4.0 + u.phraseA.y * 3.0);
        float2 q = rotate2(p, morphClock(u, 0.12) + amount * 1.7);
        q /= float2(max(u.aspect, 0.001), 1.0);
        q = q * scale + float2(u.time * 0.018, -u.time * 0.014) * u.generator.w;
        float2 mirrored = abs(fract(q + 0.5) - 0.5) * 2.0 - 0.5;
        mirrored /= scale;
        mirrored *= float2(u.aspect, 1.0);
        return rotate2(mirrored, -morphClock(u, 0.07));
    }

    float recursiveTileField(float2 p, constant VisualizerUniforms &u) {
        float clock = morphClock(u, 0.50);
        float2 q = p;
        float accum = 0.0;
        float amp = 0.55;
        for (int i = 0; i < 4; ++i) {
            float fi = float(i) + 1.0;
            q = mirrorTileFold(q * (1.12 + fi * 0.12), u, fract(u.seed + fi * 0.173 + u.phraseA.y));
            float r = length(q) + 0.001;
            float a = atan2(q.y, q.x);
            float checker = sin(q.x * (12.0 + u.generator.y * 18.0 + fi * 4.0) + clock * (0.4 + fi * 0.11))
                * cos(q.y * (10.0 + u.moduleB.z * 17.0 + fi * 3.0) - clock * (0.32 + fi * 0.09));
            float mandala = sin(a * (3.0 + u.moduleB.z * 8.0 + fi) + r * (10.0 + u.generatorB.x * 12.0) - clock);
            accum += (lineField(checker, 0.105 + u.mid * 0.030) * 0.46 + lineField(mandala, 0.12 + u.low * 0.04) * 0.54) * amp;
            q = rotate2(q * 1.38 + float2(0.13 * fi, -0.09 * fi), 0.53 + u.seed + fi * 0.19);
            amp *= 0.58;
        }
        return clamp(accum * 0.34, 0.0, 1.0);
    }

    float beatShockwaveField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p);
        float field = 0.0;
        float phaseBase = fract(u.beatPhase + u.phraseB.x);
        for (int i = 0; i < 4; ++i) {
            float fi = float(i);
            float phase = fract(phaseBase + fi * 0.23 + hash11(fi + u.seed) * 0.09);
            float b = bandAt(fract(fi * 0.19 + u.phraseB.y), bands);
            float d = bandDeltaAt(fract(fi * 0.23 + u.phraseB.z), bands);
            float ringRadius = 0.08 + phase * (0.78 + u.moduleB.w * 0.30 + b * 0.10);
            float width = 0.020 + phase * 0.030 + u.onset * 0.018;
            float wave = exp(-abs(radius - ringRadius) / max(width, 0.002));
            field += wave * (1.0 - phase) * (0.20 + u.beat * 0.62 + d * 0.82);
        }
        return clamp(field, 0.0, 1.4);
    }

    float waveformTunnelField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p) + 0.018;
        float angle = atan2(p.y, p.x);
        float clock = morphClock(u, 0.68);
        float bandPhase = fract(angle / 6.28318531 + 0.5 + u.beatPhase * 0.04 + u.phraseB.x * 0.11);
        float b = bandAt(bandPhase, bands);
        float d = bandDeltaAt(fract(bandPhase + 0.07), bands);
        float logDepth = log(radius + 0.065) * (5.0 + u.moduleB.w * 8.0 + u.generator.y * 5.0);
        float spiral = sin(logDepth + angle * (2.0 + u.moduleB.z * 8.0 + u.generatorB.x * 4.0) - clock * (1.3 + u.morphA.x * 2.0) + b * 4.4);
        float ribs = sin(angle * (8.0 + u.generatorB.x * 18.0) + radius * (9.0 + u.morphB.w * 12.0) + clock * 0.7);
        float tunnel = lineField(spiral, 0.11 + u.low * 0.045 + d * 0.035) * smoothstep(1.12, 0.04, radius);
        tunnel += lineField(ribs, 0.13 + u.high * 0.05) * smoothstep(0.92, 0.14, radius) * 0.34;
        return clamp(tunnel * (0.22 + b * 0.52 + d * 0.92), 0.0, 1.35);
    }

    float superscopeBraidField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float normX = clamp((p.x / max(u.aspect, 0.001)) + 0.5, 0.0, 1.0);
        float clock = morphClock(u, 0.78);
        float braid = 0.0;
        for (int i = 0; i < 5; ++i) {
            float fi = float(i) + 1.0;
            float t = fract(normX + fi * 0.087 + u.phraseB.y * 0.13);
            float b = bandAt(t, bands);
            float d = bandDeltaAt(fract(t + 0.08), bands);
            float phase = normX * 6.28318531 * (1.0 + fi * 0.62 + u.morphB.w * 2.1) + clock * (0.72 + fi * 0.13) + u.seed * fi;
            float y = sin(phase + sin(phase * (0.27 + u.morphA.y * 0.18)) * (0.8 + u.morphB.w * 0.7)) * (0.045 + b * 0.16 + d * 0.10);
            y += cos(phase * 0.47 + fi * 2.4) * (0.020 + u.morphA.z * 0.045);
            float line = exp(-abs(p.y - y) * (28.0 + u.high * 42.0 + d * 22.0));
            float mirrorLine = exp(-abs(p.y + y) * (30.0 + u.mid * 28.0));
            braid += (line * 0.74 + mirrorLine * 0.34) * (0.16 + b * 0.55 + d * 0.90);
        }
        return clamp(braid * 0.40, 0.0, 1.3);
    }

    float bassLensDistortion(float2 p, constant VisualizerUniforms &u) {
        float radius = length(p) + 0.0001;
        float pulseRadius = 0.10 + fract(u.beatPhase + u.phraseB.w * 0.25) * (0.58 + u.moduleB.w * 0.24);
        float centerLens = exp(-radius * radius * (5.0 + u.morphA.y * 8.0)) * (u.low * 0.68 + u.beat * 0.34);
        float ringLens = exp(-abs(radius - pulseRadius) * (11.0 + u.high * 16.0)) * (u.onset * 0.46 + u.spectralFlux * 0.28);
        float asymmetric = 0.5 + 0.5 * sin(atan2(p.y, p.x) * (2.0 + u.generatorB.x * 8.0) + morphClock(u, 0.64));
        return (centerLens + ringLens * asymmetric) * (0.42 + u.morphB.y * 0.58) * u.generator.w;
    }

    float juliaOrbitTrapField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float clock = morphClock(u, 0.46);
        float2 z = rotate2(p, u.seed * 6.28318531 + clock * 0.12) * (1.04 + u.generator.y * 0.70 + u.morphA.y * 0.34);
        float2 c = float2(
            cos(clock * 0.37 + u.phraseB.x * 6.28318531),
            sin(clock * 0.31 + u.phraseB.y * 6.28318531)
        ) * (0.22 + u.morphA.y * 0.20 + u.low * 0.06);
        float trap = 8.0;
        float glow = 0.0;
        float orbitBand = bandAt(fract(length(p) + u.phraseB.z * 0.31), bands);
        for (int i = 0; i < 7; ++i) {
            float x = z.x * z.x - z.y * z.y + c.x;
            float y = 2.0 * z.x * z.y + c.y;
            z = float2(x, y);
            z = rotate2(z, 0.08 * sin(clock + float(i)) + u.reactive.w * 0.015);
            float r = length(z);
            trap = min(trap, abs(r - (0.32 + orbitBand * 0.22 + float(i) * 0.035)));
            glow += exp(-abs(r - (0.58 + float(i) * 0.08)) * (2.4 + u.morphA.y * 7.0)) / (float(i) + 1.0);
            z = clamp(z, float2(-3.0), float2(3.0));
        }
        float line = exp(-trap * (22.0 + u.high * 28.0 + u.morphA.y * 24.0));
        return clamp(line * 0.62 + glow * 0.20, 0.0, 1.25);
    }

    float harmonicScopeKnotField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float clock = morphClock(u, 0.86);
        float field = 0.0;
        for (int i = 0; i < 96; ++i) {
            float t = float(i) / 95.0;
            float b = bandAt(t, bands);
            float d = bandDeltaAt(fract(t + 0.05), bands);
            float phase = t * 6.28318531;
            float ax = 2.0 + floor(u.generatorB.x * 6.0);
            float ay = 3.0 + floor(u.generator.y * 5.0);
            float2 point = float2(
                sin(phase * ax + clock * (0.33 + u.morphB.w * 0.50) + b * 1.7),
                sin(phase * ay + clock * (0.27 + u.morphA.x * 0.44) + u.phraseB.y * 3.0)
            ) * (0.18 + b * 0.30 + u.morphA.z * 0.10);
            point.x *= u.aspect;
            float width = 0.006 + b * 0.010 + d * 0.010 + u.onset * 0.004;
            field += exp(-length(p - point) / max(width, 0.001)) * (0.020 + b * 0.070 + d * 0.130);
        }
        return clamp(field, 0.0, 1.35);
    }

    float starburstLatticeField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float clock = morphClock(u, 0.70);
        float spokes = 5.0 + floor(u.moduleB.z * 18.0 + u.generatorB.x * 8.0);
        float spokeWave = sin(angle * spokes + radius * (6.0 + u.generator.y * 14.0) - clock * (1.2 + u.morphA.x * 2.1));
        float spokeLine = lineField(spokeWave, 0.075 + u.high * 0.035);
        float ringBand = bandAt(fract(radius * (0.74 + u.moduleB.w * 0.42) + u.phraseB.x), bands);
        float rings = sin(radius * (16.0 + u.moduleB.w * 24.0 + ringBand * 10.0) - clock * 1.3 + u.beatPhase * 6.28318531);
        float ringLine = lineField(rings, 0.095 + u.low * 0.04);
        float lattice = pow(max(0.0, spokeLine * 0.62 + ringLine * 0.52), 1.55);
        float falloff = smoothstep(1.12, 0.08, radius) * (0.42 + ringBand * 0.58);
        return clamp(lattice * falloff * (0.24 + u.beat * 0.30 + u.spectralFlux * 0.26), 0.0, 1.20);
    }

    float moireInterferenceField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float clock = equationClock(u, 0.74);
        float2 q = p * (1.0 + u.generator.y * 1.6 + u.equationB.x * 0.8);
        float2 r = rotate2(q, 0.78539816 + u.equationA.x * 3.14159265 + u.reactive.w * 0.02);
        float b = bandAt(fract(length(p) * 0.37 + u.equationA.y), bands);
        float d = bandDeltaAt(fract(atan2(p.y, p.x) / 6.28318531 + 0.5 + u.equationA.x), bands);
        float f0 = 8.0 + u.moduleB.z * 18.0 + b * 8.0;
        float f1 = 9.5 + u.generatorB.w * 17.0 + u.equationB.y * 7.0;
        float waves = sin(q.x * f0 + q.y * (1.5 + u.equationB.z * 3.0) + clock)
            + sin(r.x * f1 - r.y * (1.2 + u.morphA.y * 3.6) - clock * 0.73);
        float contour = lineField(waves, 0.13 + u.mid * 0.055 + d * 0.025);
        float carrier = 0.5 + 0.5 * sin((q.x + r.y) * (4.0 + u.morphB.w * 8.0) - clock * 0.34);
        return clamp(contour * (0.24 + carrier * 0.42 + b * 0.34 + d * 0.42), 0.0, 1.25);
    }

    float spectralRainField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float rain = 0.0;
        float clock = u.time * (0.06 + u.morphA.x * 0.18) * u.generator.w + u.equationA.x * 17.0;
        for (int i = 0; i < 28; ++i) {
            float fi = float(i);
            float t = fi / 27.0;
            float h = hash11(fi * 7.31 + u.equationA.y * 43.0);
            float b = bandAt(t, bands);
            float d = bandDeltaAt(fract(t + 0.05), bands);
            float x = (t - 0.5) * 2.0 * u.aspect + (h - 0.5) * 0.045;
            float fall = fract(clock * (0.45 + h * 0.90 + b * 0.65) + h + u.beatPhase * u.beat * 0.08);
            float y = mix(0.72, -0.72, fall);
            float width = 0.006 + b * 0.009 + u.equationB.z * 0.004;
            float tail = 0.055 + b * 0.16 + d * 0.12 + u.onset * 0.055;
            float column = exp(-abs(p.x - x) / max(width, 0.001));
            float streak = exp(-max(p.y - y, 0.0) / max(tail, 0.004)) * exp(-abs(min(p.y - y, 0.0)) / max(width * 2.4, 0.002));
            rain += column * streak * (0.08 + b * 0.44 + d * 0.82);
        }
        return clamp(rain * 0.42, 0.0, 1.25);
    }

    float irisShutterField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float clock = equationClock(u, 0.62);
        float blades = 4.0 + floor(u.equationA.x * 7.0 + u.moduleB.z * 5.0);
        float aperture = 0.18 + u.equationB.x * 0.22 + u.low * 0.08 + u.beat * 0.05;
        float bladeWave = sin(angle * blades + radius * (4.0 + u.generator.y * 8.0) - clock);
        float bladeLine = lineField(bladeWave, 0.105 + u.high * 0.040);
        float ring = exp(-abs(radius - aperture) * (17.0 + u.onset * 24.0));
        float spokes = pow(max(0.0, bladeLine), 1.75) * smoothstep(0.92, 0.05, radius);
        float band = bandAt(fract(angle / 6.28318531 + 0.5 + u.equationA.y), bands);
        return clamp((spokes * 0.48 + ring * 0.52) * (0.22 + band * 0.45 + u.equationB.w * 0.30), 0.0, 1.2);
    }

    float chromaticVectorField(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float2 normalized = p / float2(max(u.aspect, 0.001), 1.0);
        float2 grid = normalized * float2(4.0 + u.generator.y * 7.0, 3.0 + u.generatorB.x * 6.0) + u.equationA.xy * 3.0;
        float2 cell = floor(grid);
        float2 local = fract(grid) - 0.5;
        float h = hash21(cell + u.equationA.x * 41.0);
        float b = bandAt(h, bands);
        float d = bandDeltaAt(fract(h + 0.17), bands);
        float angle = h * 6.28318531 + equationClock(u, 0.48) * (0.18 + b * 0.32);
        float2 direction = float2(cos(angle), sin(angle));
        float body = exp(-sdSegment(local, -direction * (0.08 + b * 0.19), direction * (0.10 + d * 0.22)) / (0.012 + u.high * 0.008 + d * 0.006));
        float phase = 0.5 + 0.5 * sin(dot(local, direction.yx) * (18.0 + u.morphB.w * 18.0) + angle);
        return body * (0.12 + b * 0.46 + d * 0.82) * (0.62 + phase * 0.38);
    }

    float2 tileEchoUV(float2 uv, constant VisualizerUniforms &u) {
        float scale = 1.0 + floor(1.0 + u.generatorB.x * 4.0 + u.phraseA.y * 3.0);
        float2 q = (uv - 0.5) * float2(u.aspect, 1.0);
        q = rotate2(q, morphClock(u, 0.10) + u.seed * 3.14159265);
        q /= float2(max(u.aspect, 0.001), 1.0);
        float2 mirrored = abs(fract(q * scale + 0.5) - 0.5) / max(scale, 1.0);
        mirrored = mirrored * 2.0 - 0.5 / max(scale, 1.0);
        mirrored *= float2(u.aspect, 1.0);
        mirrored = rotate2(mirrored, -morphClock(u, 0.06));
        return clamp(mirrored / float2(max(u.aspect, 0.001), 1.0) + 0.5, float2(0.0), float2(1.0));
    }

    float3 driftPalette(float3 a, float3 b, float3 c, float phase, float drift) {
        float3 first = mix(a, b, 0.5 + 0.5 * sin(phase));
        float3 second = mix(c, a, 0.5 + 0.5 * sin(phase * 0.73 + 2.1));
        return mix(first, second, drift);
    }

    float3 acesFilm(float3 x) {
        return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), float3(0.0), float3(1.0));
    }

    float3 chromaPreservingVibrance(float3 color, float3 paletteHue, constant VisualizerUniforms &u, float whiteWash) {
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float maxChannel = max(max(color.r, color.g), color.b);
        float minChannel = min(min(color.r, color.g), color.b);
        float chroma = maxChannel - minChannel;
        float vibrance = (0.08 + u.intensity * 0.10 + u.controls.y * 0.08 + u.high * 0.04)
            * (1.0 - smoothstep(0.20, 0.82, chroma))
            * (1.0 - whiteWash * 0.42);
        color = mix(float3(luma), color, 1.0 + vibrance);

        float highlight = smoothstep(0.68, 0.96, luma);
        float3 hueRescue = paletteHue * (0.30 + luma * 0.68);
        color = mix(color, hueRescue, highlight * (0.035 + whiteWash * 0.16 + u.morphB.x * 0.045));

        float newLuma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float softCeiling = 0.84 + chroma * 0.13 + u.flashLimit * 0.03;
        float knee = max(newLuma - softCeiling, 0.0);
        color *= 1.0 / (1.0 + knee * (1.35 + whiteWash * 1.10));
        return max(color, float3(0.0));
    }

    float3 clarityGrade(float3 color, float3 toneLocalAverage, constant VisualizerUniforms &u) {
        float3 delta = color - toneLocalAverage;
        float localContrast = length(delta);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float haze = (1.0 - smoothstep(0.10, 0.48, localContrast)) * smoothstep(0.05, 0.72, luma);
        color = max(color - toneLocalAverage * haze * (0.045 + u.controls.x * 0.055 + u.morphB.y * 0.020), float3(0.0));
        color += delta * (0.030 + u.controls.x * 0.045 + u.high * 0.018);
        return max(color, float3(0.0));
    }

    float2 milkdropPerPixelWarp(float2 p, constant VisualizerUniforms &u) {
        float worldMix = butterchurnMorphMask(p, u);
        float worldSeed = mix(u.sourceSignature.x, u.targetSignature.x, worldMix);
        float worldScene = mix(u.sourceSignature.z, u.targetSignature.z, worldMix);
        float worldEquation = mix(u.sourceSignature.w, u.targetSignature.w, worldMix);
        float clock = equationClock(u, 0.82) + worldSeed * 4.1;
        float2 center = (float2(u.equationB.x - 0.5, u.equationB.y - 0.5) + float2(worldScene - 0.5, worldEquation - 0.5) * 0.42)
            * float2(u.aspect, 1.0)
            * 0.16;
        float2 q = p - center;
        float radius = length(q) + 0.0001;
        float angle = atan2(q.y, q.x);
        float2 normalized = q / float2(max(u.aspect, 0.001), 1.0);
        float zoomExp = 0.74 + u.equationB.z * 0.68 + u.morphA.y * 0.30;
        float polarZoom = pow(radius + 0.018, zoomExp) - radius;
        q += normalize(q + float2(0.0003, -0.0002)) * polarZoom * (0.018 + u.low * 0.020);
        float warpTimeV = u.time * (0.42 + u.generator.w * 0.78 + u.morphA.x * 0.36);
        float warpScaleInv = 1.0 / max(0.45 + u.generator.y * 2.20 + u.morphA.y * 1.10, 0.001);
        float warpf0 = 11.68 + 4.0 * cos(warpTimeV * 1.413 + 10.0);
        float warpf1 = 8.77 + 3.0 * cos(warpTimeV * 1.113 + 7.0);
        float warpf2 = 10.54 + 3.0 * cos(warpTimeV * 1.233 + 3.0);
        float warpf3 = 11.49 + 4.0 * cos(warpTimeV * 0.933 + 5.0);
        float milkdropWarpAmount = (0.20 + u.low * 0.22 + u.morphA.y * 0.32 + u.equationB.w * 0.18) * u.moduleA.x;
        float2 milkdropWarp = float2(
            sin(warpTimeV * 0.333 + warpScaleInv * (normalized.x * warpf0 - normalized.y * warpf3))
                + cos(warpTimeV * 0.753 - warpScaleInv * (normalized.x * warpf1 - normalized.y * warpf2)),
            cos(warpTimeV * 0.375 - warpScaleInv * (normalized.x * warpf2 + normalized.y * warpf1))
                + sin(warpTimeV * 0.825 + warpScaleInv * (normalized.x * warpf0 + normalized.y * warpf3))
        ) * milkdropWarpAmount * 0.0035;
        q += milkdropWarp * float2(max(u.aspect, 0.001), 1.0);
        q = rotate2(q, sin(radius * (3.0 + u.generatorB.x * 8.0) - clock) * (0.010 + u.reactive.x * 0.012));
        q += float2(
            sin(q.y * (5.0 + u.generator.y * 9.0) + clock * 0.91),
            cos(q.x * (4.0 + u.moduleB.z * 8.0) - clock * 0.77)
        ) * (0.0035 + u.morphA.y * 0.0065 + u.spectralFlux * 0.0040);
        float petal = sin(angle * (2.0 + floor(worldEquation * 10.0)) + clock + radius * 5.0);
        q += normalize(q + float2(0.0002)) * petal * (0.002 + u.onset * 0.006 + u.beat * 0.003);
        return q + center;
    }

    float butterchurnWarpMotionVectors(float2 p, constant VisualizerUniforms &u, constant float *bands) {
        float2 normalized = p / float2(max(u.aspect, 0.001), 1.0);
        float2 gridScale = float2(5.0 + floor(u.moduleB.z * 10.0), 4.0 + floor(u.generator.y * 8.0));
        float2 grid = normalized * gridScale + float2(u.phraseA.x, u.phraseA.y) * 0.35;
        float2 cell = floor(grid);
        float2 local = fract(grid) - 0.5;
        float2 sampleP = ((cell - float2(u.phraseA.x, u.phraseA.y) * 0.35) + 0.5) / gridScale;
        sampleP *= float2(max(u.aspect, 0.001), 1.0);
        float2 warpDir = milkdropPerPixelWarp(sampleP, u) - sampleP;
        float warpLen = length(warpDir);
        float h = hash21(cell + u.seed * 43.0);
        float b = butterchurnSmoothWave(h, bands);
        float d = bandDeltaAt(fract(h + 0.23), bands);
        float2 direction = normalize(warpDir + float2(cos(h * 6.28318531), sin(h * 6.28318531)) * 0.010);
        float lenMult = 7.5 + u.morphB.y * 7.0 + u.beat * 2.0;
        float minLen = 0.045;
        float lengthScale = clamp(max(warpLen * lenMult, minLen) + b * 0.12 + u.onset * 0.05, minLen, 0.34);
        float width = 0.012 + u.high * 0.010 + d * 0.006;
        float mark = exp(-sdSegment(local, -direction * lengthScale, direction * lengthScale) / max(width, 0.001));
        float head = exp(-length(local - direction * lengthScale) / (0.025 + u.onset * 0.018));
        float cellFade = smoothstep(0.62, 0.18, length(local));
        return (mark * 0.74 + head * 0.30) * cellFade * (0.18 + b * 0.58 + d * 0.72);
    }

    float4 distinctHeroGeometry(float2 p, constant VisualizerUniforms &u, constant float *bands, float worldSeed, float worldFamily) {
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float clock = morphClock(u, 0.74) + worldSeed * 6.28318531;
        float spokes = 5.0 + floor(worldSeed * 10.0);
        float normX = clamp(p.x / max(u.aspect, 0.001) + 0.5, 0.0, 1.0);
        float band = butterchurnSmoothWave(normX, bands);
        float delta = bandDeltaAt(normX, bands);

        float ringRadius = 0.18 + 0.20 * softCycle(clock * 0.31 + worldFamily * 4.0) + u.low * 0.08;
        float rings = exp(-abs(radius - ringRadius) * (44.0 + u.high * 26.0));
        rings += exp(-abs(radius - ringRadius * 1.48) * (34.0 + u.mid * 20.0)) * 0.62;
        float mandala = lineField(sin(angle * spokes + radius * (12.0 + u.generator.y * 10.0) - clock), 0.075 + u.low * 0.025);
        mandala *= smoothstep(0.95, 0.08, radius) * (0.34 + rings);

        float y = (band - 0.42) * (0.42 + u.morphB.w * 0.22)
            + sin(normX * (18.0 + spokes * 2.0) + clock) * (0.020 + delta * 0.030);
        float scope = exp(-abs(p.y - y) * (34.0 + u.outputPeak * 28.0));
        float angledScope = exp(-abs(rotate2(p, worldSeed * 3.14159265).y - y * 0.72) * (30.0 + u.high * 22.0));

        float2 q = rotate2(p, worldFamily * 6.28318531 + clock * 0.04);
        float freq = 7.0 + floor(worldSeed * 12.0);
        float grid = max(lineField(sin(q.x * freq + clock * 0.33), 0.052), lineField(sin(q.y * (freq * 0.82) - clock * 0.27), 0.052));
        grid *= smoothstep(1.08, 0.10, radius);

        float familyA = sceneFamilyGate(worldFamily, 0.18, 0.34);
        float familyB = sceneFamilyGate(worldFamily, 0.52, 0.34);
        float familyC = sceneFamilyGate(worldFamily, 0.84, 0.34);
        return float4(
            mandala * (0.58 + familyA * 0.62),
            max(scope, angledScope * 0.74) * (0.50 + familyB * 0.66),
            grid * (0.36 + familyC * 0.58),
            max(max(familyA, familyB), familyC)
        );
    }

    fragment float4 visualizer_warp(VertexOut in [[stage_in]],
                                    constant VisualizerUniforms &u [[buffer(0)]],
                                    texture2d<float> previous [[texture(0)]]) {
        constexpr sampler feedbackSampler(coord::normalized, address::repeat, filter::linear);
        if (u.priming > 0.5) {
            return float4(u.palette0.rgb * 0.10, 1.0);
        }

        float2 uv = in.uv;
        float2 p = (uv - 0.5) * float2(u.aspect, 1.0);
        float radius = length(p) + 0.0001;
        float angle = atan2(p.y, p.x);
        float motion = u.generator.w;
        float morph = morphClock(u, 1.0);
        float modeA = softCycle(morph);
        float modeB = softCycle(morph * 0.71 + 2.4);
        float warpScene = sceneBlendGate(u, 0.82);
        float2 morphFold = kaleido(rotate2(p, morph * 0.11), clamp(u.generatorB.x + u.morphA.z * 0.42 * modeA, 0.0, 1.0));
        float2 flow = flowField(mix(p, morphFold, u.morphA.w * 0.42), u.time, u.morphA.y);
        float folded = sin(angle * (2.0 + u.generatorB.x * 9.0 + u.morphA.z * 5.0 * modeB) + radius * (8.0 + u.moduleB.z * 16.0));
        float turbulence = fbm(p * (1.2 + u.generatorB.z * 2.8 + u.morphA.y * 1.7 * modeA) + float2(u.time * 0.035, -u.time * 0.026) + flow * 0.55);
        float swirl = sin(radius * (4.0 + u.moduleB.z * 12.0) - u.time * 0.42 + u.beatPhase * 6.28318531)
            + (turbulence - 0.5) * 1.2
            + folded * (u.generatorB.x * 0.55 + u.morphA.z * 0.32 * modeA)
            + (modeB - 0.5) * u.morphA.y * 0.55;
        angle += swirl * 0.016 * u.reactive.x * u.moduleA.x * u.intensity * motion * (0.88 + warpScene * 0.36);
        angle += sin(radius * (7.0 + u.combo.z * 11.0) - morph * 1.7) * u.combo.x * 0.014 * motion * (0.90 + warpScene * 0.25);
        angle += u.reactive.w * 0.010 * motion;
        float zoom = 1.0 + (u.reactive.y * 0.014 + u.beat * 0.010 + u.moduleB.w * 0.004 + modeA * u.morphA.w * 0.006 + u.combo.x * 0.010) * u.intensity * motion;
        p *= 1.0 / zoom;
        float bassLens = bassLensDistortion(p, u) * (0.78 + warpScene * 0.42 + u.sceneB.w * 0.16);
        p += normalize(p + float2(0.0003, -0.0002)) * bassLens * (0.006 + u.reactive.x * 0.006 + u.combo.x * 0.004);
        angle += bassLens * (0.010 + u.morphB.y * 0.018 + u.combo.x * 0.008);
        p = rotate2(p, u.reactive.w * 0.010 * motion);
        p += float2(cos(angle * 2.1 + u.time * 0.10 + turbulence * 3.0), sin(angle * 2.7 - u.time * 0.08)) * u.reactive.x * 0.0045 * motion;
        p += flow * u.morphA.y * 0.011 * motion;
        p += flowField(p + float2(u.combo.z), u.time * 0.48, u.morphA.y) * u.combo.x * 0.011 * motion;
        p += float2(dfdx(turbulence), dfdy(turbulence)) * u.generatorB.z * 0.010 * motion;
        p = mix(p, morphFold, (u.morphA.w * modeB * 0.026 + u.combo.x * 0.020 * modeA) * motion);
        float2 formulaWarp = milkdropPerPixelWarp(p, u);
        p = mix(p, formulaWarp, (0.045 + warpScene * 0.055 + u.equationB.w * 0.035) * u.moduleA.x * motion);

        float2 sampleUV = p / float2(u.aspect, 1.0) + 0.5;
        float4 prev = previous.sample(feedbackSampler, sampleUV);
        float2 texel = float2(0.0012 / max(u.aspect, 0.001), 0.0012);
        float3 nearA = previous.sample(feedbackSampler, sampleUV + float2(texel.x, 0.0)).rgb;
        float3 nearB = previous.sample(feedbackSampler, sampleUV - float2(texel.x, 0.0)).rgb;
        float3 nearC = previous.sample(feedbackSampler, sampleUV + float2(0.0, texel.y)).rgb;
        float3 nearD = previous.sample(feedbackSampler, sampleUV - float2(0.0, texel.y)).rgb;
        float centerLuma = dot(prev.rgb, float3(0.2126, 0.7152, 0.0722));
        float neighborLuma = dot((nearA + nearB + nearC + nearD) * 0.25, float3(0.2126, 0.7152, 0.0722));
        float feedbackEdge = abs(centerLuma - neighborLuma);
        float decay = 0.772 + u.moduleB.w * 0.018 + u.morphB.y * 0.020 * modeB - u.spectralFlux * 0.048 - u.onset * 0.034 - u.morphA.y * 0.018 * modeA;
        float3 floorColor = u.palette0.rgb * (0.020 + u.outputPeak * 0.026);
        float3 feedback = max(prev.rgb * decay, floorColor);
        float2 motionVector = sampleUV - uv;
        float motionEnergy = clamp(length(motionVector) * (34.0 + u.reactive.x * 22.0 + u.morphB.y * 18.0), 0.0, 1.0);
        float2 perpendicularEcho = rotate2(motionVector * float2(u.aspect, 1.0), 1.57079633) / float2(max(u.aspect, 0.001), 1.0);
        float3 directionalEcho = max(
            previous.sample(feedbackSampler, sampleUV - motionVector * (0.65 + u.phraseA.w * 0.55)).rgb * 0.74,
            previous.sample(feedbackSampler, sampleUV + perpendicularEcho * (0.35 + u.phraseB.w * 0.45)).rgb * 0.56
        );
        feedback = mix(feedback, max(feedback, directionalEcho), u.morphB.y * motionEnergy * (0.035 + u.combo.x * 0.020));
        feedback += mix(u.palette2.rgb, u.palette3.rgb, modeA + u.combo.z) * feedbackEdge * (u.morphB.y * 0.78 + u.combo.x * 0.34) * (0.010 + u.spectralFlux * 0.026);
        feedback += hueShader(sampleUV, u) * feedbackEdge * motionEnergy * u.morphB.y * (0.007 + u.outputPeak * 0.013);
        return float4(feedback, 1.0);
    }

    fragment float4 visualizer_generate(VertexOut in [[stage_in]],
                                        constant VisualizerUniforms &u [[buffer(0)]],
                                        constant float *bands [[buffer(1)]]) {
        float2 uv = in.uv;
        float2 p = (uv - 0.5) * float2(u.aspect, 1.0);
        float2 foldedP = kaleido(rotate2(p, u.time * 0.025 * u.generator.w + u.seed * 6.28318531), u.generatorB.x);
        float radius = length(p) + 0.0001;
        float foldedRadius = length(foldedP) + 0.0001;
        float angle = atan2(p.y, p.x);
        float normX = clamp((p.x / max(u.aspect, 0.001)) + 0.5, 0.0, 1.0);
        float3 color = float3(0.0);
        float worldMix = butterchurnMorphMask(p, u);
        float worldSeed = mix(u.sourceSignature.x, u.targetSignature.x, worldMix);
        float worldModule = mix(u.sourceSignature.y, u.targetSignature.y, worldMix);
        float worldScene = mix(u.sourceSignature.z, u.targetSignature.z, worldMix);
        float worldEquation = mix(u.sourceSignature.w, u.targetSignature.w, worldMix);
        float morph = morphClock(u, 1.0) + worldSeed * 1.9 + worldEquation * 0.7;
        float modeA = softCycle(morph + worldScene * 2.1);
        float modeB = softCycle(morph * 0.63 + 1.9 + worldModule * 2.7);
        float modeC = softCycle(morph * 1.37 + 4.1 + worldEquation * 1.8);
        float sceneGate = mix(0.35, 1.0, u.morphA.w) * (0.42 + 0.58 * modeB);
        float2 sourceSceneP = mix(p, foldedP, u.morphA.z * (0.18 + u.sourceSignature.z * 0.52));
        float2 targetFoldedP = kaleido(rotate2(p, (u.targetSignature.z - 0.5) * 0.58), clamp(u.generatorB.x + u.targetSignature.y * 0.18, 0.0, 1.0));
        float2 targetSceneP = mix(rotate2(p, (u.targetSignature.x - 0.5) * 0.36), targetFoldedP, u.morphA.z * (0.26 + modeA * 0.58));
        float2 sceneP = mix(sourceSceneP, targetSceneP, worldMix);
        float3 primarySource = driftPalette(u.palette1.rgb, u.palette2.rgb, u.palette3.rgb, morph + angle + u.sourceSignature.x * 6.28318531, u.morphB.x);
        float3 primaryTarget = driftPalette(u.palette2.rgb, u.palette3.rgb, u.palette1.rgb, morph + angle + u.targetSignature.x * 6.28318531, u.morphB.x);
        float3 secondarySource = driftPalette(u.palette2.rgb, u.palette3.rgb, u.palette1.rgb, morph * 0.77 + radius * 2.0 + u.sourceSignature.y * 6.28318531, u.morphB.x);
        float3 secondaryTarget = driftPalette(u.palette3.rgb, u.palette1.rgb, u.palette2.rgb, morph * 0.77 + radius * 2.0 + u.targetSignature.y * 6.28318531, u.morphB.x);
        float3 accentSource = driftPalette(u.palette3.rgb, u.palette1.rgb, u.palette2.rgb, morph * 1.21 - angle + u.sourceSignature.w * 6.28318531, u.morphB.x);
        float3 accentTarget = driftPalette(u.palette1.rgb, u.palette2.rgb, u.palette3.rgb, morph * 1.21 - angle + u.targetSignature.w * 6.28318531, u.morphB.x);
        float3 primary = mix(primarySource, primaryTarget, worldMix);
        float3 secondary = mix(secondarySource, secondaryTarget, worldMix);
        float3 accent = mix(accentSource, accentTarget, worldMix);
        float3 hueField = hueShader(uv, u);
        primary *= mix(float3(1.0), hueField, 0.10 + u.morphB.x * 0.20 + u.combo.x * 0.05);
        secondary *= mix(float3(1.0), float3(hueField.b, hueField.r, hueField.g), 0.08 + u.phraseA.x * 0.16);
        accent *= mix(float3(1.0), float3(hueField.g, hueField.b, hueField.r), 0.12 + u.phraseA.z * 0.20);
        float spectralTilt = clamp(0.5 + u.high - u.low, 0.0, 1.0);
        float audioPunch = clamp(u.outputPeak * 0.45 + u.low * 0.24 + u.mid * 0.18 + u.high * 0.14 + u.onset * 0.75 + u.spectralFlux * 0.48 + u.beat * 0.55, 0.0, 1.60);
        float heroPulse = 0.72 + audioPunch * 0.58;
        float focusBreath = softCycle(morph * 0.37 + u.seed * 2.0);
        float focusRadius = 0.24 + modeB * 0.10 + focusBreath * 0.08 + u.low * 0.05;
        float focalMask = 1.0 - smoothstep(focusRadius, focusRadius + 0.48, radius);
        float rimMask = smoothstep(0.24, 0.86, radius) * (1.0 - smoothstep(1.08, 1.32, radius));
        float compositionMask = mix(0.54, 1.0, max(focalMask, rimMask * 0.62));
        float4 director = compositionDirector(p, u);
        float detailGate = (0.40 + u.controls.x * 0.44) * (1.0 - u.combo.x * 0.18);
        float transientGate = smoothstep(0.14, 0.66, u.onset + u.spectralFlux * 0.55 + u.beat * 0.22);
        float accentGate = 0.28 + transientGate * 0.72;
        float atmosphereGate = 0.44 - u.combo.x * 0.08;
        float primaryGate = 0.66 + modeA * 0.28 + focalMask * 0.12;
        float lineGate = 0.66 + u.controls.x * 0.26 + u.high * 0.08 + audioPunch * 0.10;
        float negativeSpaceMask = 0.76 + 0.24 * smoothstep(0.20, 0.92, abs(sin(angle * (1.35 + u.moduleB.z * 3.0) + morph * 0.18)));
        compositionMask *= director.w;
        detailGate *= director.z;
        atmosphereGate *= director.x;
        primaryGate *= director.y;
        lineGate *= 0.82 + director.y * 0.22;
        negativeSpaceMask *= 0.88 + director.w * 0.12;
        float transitionSpatial = worldMix;
        float transitionEdge = butterchurnMorphEdge(p, u);
        float worldFamily = fract(worldModule * 0.47 + worldScene * 0.31 + worldEquation * 0.22);
        float atmosphereFamily = sceneFamilyGate(worldFamily, 0.06, 0.13);
        float spectrumFamily = sceneFamilyGate(worldFamily, 0.22, 0.13);
        float geometryFamily = sceneFamilyGate(worldFamily, 0.38, 0.13);
        float waveFamily = sceneFamilyGate(worldFamily, 0.56, 0.13);
        float tunnelFamily = sceneFamilyGate(worldFamily, 0.72, 0.13);
        float particleFamily = sceneFamilyGate(worldFamily, 0.88, 0.13);
        float leaderClock = morph * 0.19 + u.seed * 7.0;
        float spectrumLead = 0.24 + 0.76 * softCycle(leaderClock);
        float waveLead = 0.24 + 0.76 * softCycle(leaderClock + 2.09439510);
        float shapeLead = 0.24 + 0.76 * softCycle(leaderClock + 4.18879020);
        float atmosphereLead = 0.38 + 0.44 * softCycle(leaderClock * 0.73 + 1.4);
        float atmosphereScene = sceneBlendGate(u, 0.08) * (0.54 + u.sceneB.x * 0.30);
        float spectrumScene = sceneBlendGate(u, 0.22) * (0.54 + u.sceneB.z * 0.30);
        float geometryScene = sceneBlendGate(u, 0.38) * (0.54 + u.sceneB.y * 0.30);
        float waveScene = sceneBlendGate(u, 0.54) * (0.54 + u.sceneB.y * 0.30);
        float tunnelScene = sceneBlendGate(u, 0.70) * (0.54 + u.sceneB.x * 0.30);
        float particleScene = sceneBlendGate(u, 0.86) * (0.54 + u.sceneB.z * 0.30);
        float sceneChangeRibbon = u.sceneA.z * (1.0 - u.sceneA.z) * 4.0;
        float moireEquation = equationBlendGate(u, 0.10) * (0.70 + u.equationB.y * 0.34);
        float rainEquation = equationBlendGate(u, 0.32) * (0.70 + u.equationB.z * 0.34);
        float irisEquation = equationBlendGate(u, 0.58) * (0.70 + u.equationB.x * 0.34);
        float vectorEquation = equationBlendGate(u, 0.80) * (0.70 + u.equationB.w * 0.34);
        float equationChangeRibbon = u.equationA.z * (1.0 - u.equationA.z) * 4.0;
        spectrumLead = clamp(spectrumLead * (0.86 + u.phraseA.x * 0.28), 0.0, 1.12);
        waveLead = clamp(waveLead * (0.86 + u.phraseA.z * 0.28), 0.0, 1.12);
        shapeLead = clamp(shapeLead * (0.86 + u.phraseA.y * 0.28), 0.0, 1.12);
        atmosphereLead = clamp(atmosphereLead * (0.90 + u.phraseA.w * 0.20), 0.0, 1.08);
        spectrumLead = clamp(spectrumLead * (0.84 + spectrumScene * 0.42 + u.sceneB.w * 0.06), 0.0, 1.22);
        waveLead = clamp(waveLead * (0.84 + waveScene * 0.42 + u.sceneB.w * 0.06), 0.0, 1.22);
        shapeLead = clamp(shapeLead * (0.84 + geometryScene * 0.42 + u.sceneB.w * 0.06), 0.0, 1.22);
        atmosphereLead = clamp(atmosphereLead * (0.86 + atmosphereScene * 0.34 + u.sceneB.w * 0.04), 0.0, 1.16);
        atmosphereLead = clamp(atmosphereLead * (0.46 + atmosphereFamily * 0.74 + tunnelFamily * 0.10), 0.0, 1.06);
        spectrumLead = clamp(spectrumLead * (0.38 + spectrumFamily * 0.86 + particleFamily * 0.10), 0.0, 1.18);
        waveLead = clamp(waveLead * (0.38 + waveFamily * 0.88 + spectrumFamily * 0.08), 0.0, 1.18);
        shapeLead = clamp(shapeLead * (0.36 + geometryFamily * 0.86 + tunnelFamily * 0.12), 0.0, 1.14);
        detailGate *= 0.72 + max(max(geometryScene, waveScene), max(spectrumScene, particleScene)) * 0.26 + max(max(moireEquation, rainEquation), max(irisEquation, vectorEquation)) * 0.08;
        detailGate *= 0.66 + max(max(spectrumFamily, geometryFamily), max(waveFamily, particleFamily)) * 0.28;
        compositionMask *= mix(0.90, 1.04, transitionSpatial);
        float2 mobiusP = moebiusFold(sceneP, u.morphA.y * (0.22 + modeC * 0.58), morph + u.seed * 6.28318531);
        float4 heroGeometry = distinctHeroGeometry(sceneP, u, bands, worldSeed, worldFamily);
        float heroEnergy = max(max(heroGeometry.x, heroGeometry.y), heroGeometry.z);
        float heroPresence = (0.48 + u.controls.x * 0.22 + u.outputPeak * 0.18)
            * (0.80 + max(max(spectrumFamily, geometryFamily), waveFamily) * 0.32);
        color += mix(primary, accent, heroGeometry.w) * heroGeometry.x * heroPresence * (0.48 + u.low * 0.20);
        color += mix(secondary, primary, spectralTilt) * heroGeometry.y * heroPresence * (0.38 + u.mid * 0.20 + u.onset * 0.10);
        color += mix(accent, secondary, modeC) * heroGeometry.z * heroPresence * detailGate * (0.28 + u.high * 0.20);
        float idleField = smoothstep(0.20, 0.90, fbm(sceneP * (1.4 + u.morphA.z * 2.2 + u.combo.x * 0.8) + float2(morph * 0.18 + u.combo.z, -morph * 0.11)));
        color += mix(u.palette0.rgb, primary, 0.34) * idleField * atmosphereGate * atmosphereLead * (0.018 + u.morphA.w * 0.016 + u.outputPeak * 0.018) * (1.0 - heroEnergy * 0.22);

        float fieldScale = 1.25 + u.generator.y * 3.0 + u.generatorB.z * 2.0;
        float nebulaA = fbm(foldedP * fieldScale + float2(u.time * 0.055, u.seed * 5.0));
        float nebulaB = fbm(p * (fieldScale * 2.1) - float2(u.time * 0.032, u.time * 0.041));
        float nebula = smoothstep(0.38, 0.86, nebulaA + nebulaB * 0.48 + u.low * 0.10);
        color += mix(u.palette0.rgb, mix(u.palette1.rgb, u.palette2.rgb, nebulaB), nebula)
            * nebula
            * u.generatorB.z
            * atmosphereGate
            * atmosphereLead
            * (0.052 + u.outputPeak * 0.075)
            * (1.0 - heroEnergy * 0.18);

        float3 textureBank = proceduralTextureBank(mix(sceneP, mobiusP, u.morphA.w * 0.36), u);
        float texturePresence = (0.055 + u.generatorB.z * 0.10 + u.morphA.y * 0.070 + u.combo.x * 0.035) * atmosphereLead;
        color += textureBank * texturePresence * atmosphereGate * (0.34 + u.outputPeak * 0.18) * compositionMask * (0.86 + atmosphereScene * 0.36);

        float4 liquidGlass = liquidGlassField(mix(sceneP, mobiusP, u.morphA.w * 0.28), u, bands);
        float liquidGate = atmosphereGate * atmosphereLead * compositionMask
            * (0.28 + atmosphereScene * 0.32 + waveScene * 0.14)
            * (0.38 + u.generatorB.z * 0.40 + u.morphA.y * 0.22);
        color += mix(primary, secondary, liquidGlass.w) * liquidGlass.x * liquidGate * (0.10 + u.mid * 0.10 + u.outputPeak * 0.06);
        color += mix(u.palette2.rgb, accent, u.equationB.z) * liquidGlass.y * liquidGate * detailGate * (0.035 + u.high * 0.060 + u.onset * 0.040);
        color *= 1.0 - liquidGlass.z * liquidGate * (0.045 + u.morphB.y * 0.040);

        float moireInterference = moireInterferenceField(mix(sceneP, foldedP, u.equationB.y * 0.32), u, bands);
        color += mix(secondary, primary, u.equationB.x) * moireInterference * moireEquation * detailGate * compositionMask * (0.08 + u.mid * 0.10 + equationChangeRibbon * 0.05);

        float radial = 0.0;
        float transientRings = 0.0;
        for (int i = 0; i < 31; ++i) {
            float fi = float(i);
            float b = bands[i];
            float d = bands[32 + i];
            float phase = fi / 31.0;
            float spokeAngle = phase * 6.28318531 + u.time * (0.025 + u.reactive.w * 0.16) + u.seed * 6.28318531;
            float spoke = exp(-angleDistance(angle + sin(radius * 4.0 + fi) * u.generatorB.x * 0.18, spokeAngle) * (7.0 + u.generator.y * 15.0));
            float ringCenter = 0.12 + b * 0.34 + fract(fi * 0.137 + u.time * 0.018 + u.beatPhase * 0.12) * (0.18 + u.moduleB.w * 0.18);
            float ring = exp(-abs(mix(radius, foldedRadius, u.generatorB.x * 0.55) - ringCenter) * (15.0 + u.beat * 14.0));
            radial += spoke * ring * (0.08 + b * 0.70 + d * 1.15);
            transientRings += exp(-abs(radius - ringCenter - d * 0.10) * (28.0 + u.onset * 38.0)) * d * (0.12 + spoke * 0.38);
        }
        color += mix(u.palette1.rgb, u.palette2.rgb, sin(angle * (2.0 + u.moduleB.z * 8.0) + u.time * 0.18) * 0.5 + 0.5)
            * radial * u.moduleA.z * primaryGate * compositionMask * spectrumLead * 0.72 * (0.86 + spectrumScene * 0.34) * heroPulse;
        color += mix(accent, primary, modeA) * transientRings * u.moduleA.z * detailGate * accentGate * spectrumLead * 0.72 * (0.84 + spectrumScene * 0.36 + sceneChangeRibbon * 0.10) * (0.70 + audioPunch * 0.76);
        color += mix(accentSource, primaryTarget, transitionSpatial) * transitionEdge * compositionMask * (0.060 + u.morphA.y * 0.100 + u.onset * 0.070);

        float beatShockwaves = beatShockwaveField(sceneP, u, bands);
        color += mix(accent, primary, spectralTilt) * beatShockwaves * u.moduleA.z * accentGate * compositionMask * (0.10 + u.beat * 0.18 + u.onset * 0.16 + audioPunch * 0.22) * (0.82 + spectrumScene * 0.40 + sceneChangeRibbon * 0.08);

        float starburstLattice = starburstLatticeField(mix(sceneP, foldedP, u.moduleB.z * 0.30), u, bands);
        color += mix(primary, accent, starburstLattice) * starburstLattice * u.moduleA.z * detailGate * spectrumLead * compositionMask * (0.10 + u.high * 0.10 + u.beat * 0.10) * (0.76 + spectrumScene * 0.52);

        float irisShutter = irisShutterField(sceneP, u, bands);
        color += mix(primary, accent, u.equationB.z) * irisShutter * irisEquation * shapeLead * detailGate * compositionMask * (0.08 + u.onset * 0.12 + equationChangeRibbon * 0.05);

        float interference = 0.0;
        for (int i = 0; i < 5; ++i) {
            float fi = float(i) + 1.0;
            float2 focus = float2(
                cos(fi * 2.17 + u.time * (0.07 + fi * 0.011)),
                sin(fi * 1.61 - u.time * (0.05 + fi * 0.013))
            ) * (0.16 + 0.22 * hash11(fi + u.seed * 31.0));
            focus.x *= u.aspect;
            float d = length(p - focus);
            float wave = sin(d * (18.0 + u.generator.y * 30.0) - u.time * (0.8 + fi * 0.12) + u.beatPhase * 6.28318531);
            float transient = bandDeltaAt(fract(fi * 0.19), bands);
            interference += lineField(wave, 0.17 + u.high * 0.08) * (0.08 + bandAt(fract(fi * 0.19), bands) * 0.38 + transient * 0.62);
        }
        color += mix(u.palette2.rgb, u.palette3.rgb, nebulaA) * interference * u.generatorB.w * detailGate * accentGate * 0.56;

        float cells = voronoi(foldedP * (4.0 + u.generator.y * 10.0 + u.low * 3.0) + float2(u.time * 0.10, -u.time * 0.07));
        float cellEdge = smoothstep(0.085, 0.0, abs(cells - (0.16 + u.beat * 0.055)));
        float cellCore = smoothstep(0.10, 0.02, cells);
        color += mix(u.palette1.rgb, u.palette3.rgb, cellCore) * (cellEdge * 0.54 + cellCore * 0.16) * u.generatorB.y * detailGate * shapeLead * (0.34 + u.mid * 0.35);

        float recursiveTiles = recursiveTileField(mix(sceneP, foldedP, u.generatorB.x * 0.35), u);
        color += mix(primary, secondary, recursiveTiles) * recursiveTiles * u.generatorB.x * u.morphA.z * detailGate * shapeLead * compositionMask * (0.10 + u.mid * 0.12 + u.phraseA.y * 0.08) * (0.78 + geometryScene * 0.48);

        float reactionDiffusion = reactionDiffusionField(mix(sceneP, mobiusP, 0.35 + u.morphA.w * 0.25), u);
        float reactionEdge = exp(-abs(reactionDiffusion - (0.40 + u.phraseA.y * 0.20)) * (8.0 + u.high * 11.0));
        color += mix(secondary, accent, reactionDiffusion) * (reactionDiffusion * 0.30 + reactionEdge * 0.10) * u.generatorB.y * detailGate * shapeLead * compositionMask * (0.18 + u.mid * 0.16 + u.onset * 0.10);

        float fractal = fractalTrap(sceneP * (0.74 + u.generator.y * 1.2) + flowField(sceneP, u.time * 0.32, u.morphA.y) * 0.18, u.seed + modeC, u.morphA.y);
        color += mix(primary, accent, fractal) * fractal * u.morphA.y * sceneGate * compositionMask * (0.14 + u.low * 0.12);

        float juliaOrbitTrap = juliaOrbitTrapField(mix(sceneP, mobiusP, 0.28 + u.morphA.w * 0.32), u, bands);
        color += mix(secondary, accent, juliaOrbitTrap) * juliaOrbitTrap * u.morphA.y * sceneGate * compositionMask * detailGate * (0.08 + u.low * 0.12 + u.spectralFlux * 0.10) * (0.78 + geometryScene * 0.44 + tunnelScene * 0.14);

        float logPolar = logPolarLine(mobiusP, 5.5 + u.moduleB.w * 12.0 + u.morphA.y * 5.0, 2.0 + u.moduleB.z * 9.0, -morph * (1.2 + u.morphA.x * 3.0));
        float logGate = smoothstep(1.08, 0.05, length(mobiusP));
        color += mix(secondary, accent, spectralTilt) * logPolar * logGate * u.morphA.y * sceneGate * primaryGate * (0.08 + u.spectralFlux * 0.16);

        float2 causticP = mobiusP * (2.2 + u.generator.y * 4.4) + flowField(mobiusP, u.time * 0.26, u.morphA.y) * (0.45 + u.beat * 0.28);
        float causticA = sin(causticP.x * (3.8 + u.morphB.w * 5.0) + sin(causticP.y * 4.1 - morph * 0.64));
        float causticB = sin(rotate2(causticP, 1.0472).x * (4.6 + u.generatorB.w * 5.4) - morph * 0.52);
        float caustic = pow(max(0.0, 1.0 - abs(causticA) * 0.58 - abs(causticB) * 0.42), 3.2);
        color += mix(primary, accent, modeC) * caustic * u.generatorB.w * detailGate * (0.08 + u.high * 0.14 + u.onset * 0.08);

        float2 comboP = moebiusFold(rotate2(p, morph * (0.08 + u.combo.z * 0.22)), u.combo.x * (0.34 + u.morphA.y * 0.46), morph * 0.71 + u.combo.z * 6.28318531);
        float comboPortal = logPolarLine(comboP, 7.0 + u.combo.z * 16.0 + u.moduleB.w * 7.0, 3.0 + u.generatorB.x * 8.0, morph * (1.4 + u.combo.z));
        float comboCells = pow(max(0.0, 1.0 - voronoi(comboP * (5.0 + u.generator.y * 7.0) + float2(u.combo.z * 8.0, morph * 0.16)) * 1.8), 2.4);
        float comboRing = exp(-abs(length(comboP) - (0.14 + 0.46 * softCycle(morph * 0.52 + u.combo.z * 5.0))) * (11.0 + u.onset * 24.0));
        color += mix(accent, secondary, comboCells) * (comboPortal * 0.10 + comboCells * 0.055 + comboRing * 0.11) * u.combo.x * accentGate * compositionMask * (0.42 + u.spectralFlux * 0.42);

        float shapes = 0.0;
        float shapeFill = 0.0;
        for (int i = 0; i < 7; ++i) {
            float fi = float(i) + 1.0;
            float orbit = morph * (0.35 + hash11(fi * 2.7) * 0.85) + fi * 1.618;
            float2 center = float2(cos(orbit), sin(orbit * 0.83 + fi)) * (0.12 + hash11(fi * 9.1 + u.seed) * 0.32);
            center.x *= u.aspect;
            float2 q = rotate2(sceneP - center, orbit * 0.42 + u.reactive.w);
            float petal = 1.0 + sin(atan2(q.y, q.x) * (3.0 + floor(hash11(fi * 6.3) * 7.0)) + morph * (1.0 + hash11(fi))) * 0.14 * u.morphA.z;
            float shapeTransient = bandDeltaAt(fract(fi * 0.117), bands);
            float circleDistance = length(q) * petal - (0.045 + hash11(fi * 4.4) * 0.075 + bandAt(fract(fi * 0.117), bands) * 0.035 + shapeTransient * 0.050);
            float boxDistance = sdBox(q, float2(0.035 + hash11(fi) * 0.060, 0.020 + hash11(fi * 3.2) * 0.052));
            float diamondDistance = sdDiamond(q, 0.055 + hash11(fi * 8.3) * 0.080);
            float shapeDistance = mix(mix(circleDistance, boxDistance, modeA), diamondDistance, modeC * u.morphA.z);
            float edge = exp(-abs(shapeDistance) * (46.0 + u.high * 34.0));
            shapes += edge * (0.18 + bandAt(fract(fi * 0.211), bands) * 0.52 + bandDeltaAt(fract(fi * 0.211), bands) * 0.86);
            shapeFill += smoothstep(0.035, -0.020, shapeDistance) * 0.10;
        }
        color += mix(secondary, accent, modeC) * shapes * u.morphA.z * sceneGate * compositionMask * detailGate * shapeLead * 0.44;
        color += mix(u.palette0.rgb, primary, 0.36) * shapeFill * u.morphA.z * sceneGate * compositionMask * shapeLead * 0.78;

        float4 customShapeActors = customShapeActorField(sceneP, u, bands);
        color += mix(primary, secondary, modeA) * customShapeActors.x * u.morphA.z * sceneGate * shapeLead * compositionMask * 0.48;
        color += mix(accent, primary, modeC) * customShapeActors.y * u.morphA.z * detailGate * shapeLead * 0.36;
        color += mix(u.palette0.rgb, secondary, 0.62) * customShapeActors.z * u.generatorB.z * atmosphereGate * shapeLead * 0.40;
        color += mix(u.palette3.rgb, u.palette1.rgb, modeB) * customShapeActors.w * accentGate * detailGate * 0.34;

        float metaballs = metaballField(sceneP, u, bands);
        color += mix(primary, accent, u.phraseA.z) * metaballs * detailGate * shapeLead * compositionMask * (0.10 + u.low * 0.16 + u.onset * 0.10);

        float superRadius = superShapeRadius(atan2(sceneP.y, sceneP.x), u.morphA.z, u.low + u.onset * 0.5);
        float superLine = exp(-abs(length(sceneP) - superRadius * (0.075 + u.moduleB.z * 0.090 + u.low * 0.035)) * (24.0 + u.high * 18.0));
        color += mix(primary, accent, modeB) * superLine * u.morphA.z * u.moduleB.z * sceneGate * compositionMask * shapeLead * (0.16 + u.onset * 0.16);

        float ribbons = 0.0;
        for (int i = 0; i < 8; ++i) {
            if (float(i) >= u.generator.z) { continue; }
            float fi = float(i) + 1.0;
            float lane = (fi / (u.generator.z + 1.0) - 0.5) * (1.1 + u.moduleB.w * 0.36);
            float b = bandAt(fract(fi * 0.173 + u.beatPhase * 0.12), bands);
            float lissX = sin(p.x * (2.2 + fi * 0.75) + u.time * (0.32 + fi * 0.045) + fi * 1.7);
            float lissY = cos(p.x * (1.4 + fi * 0.52) - u.time * (0.24 + fi * 0.035) + u.seed * 5.0);
            float wave = (lissX * 0.70 + lissY * 0.30) * (0.055 + b * 0.145);
            float line = exp(-abs(mix(p.y, foldedP.y, u.generatorB.x * 0.38) - lane - wave) * (18.0 + u.high * 20.0));
            ribbons += line * (0.16 + b * 0.78);
        }
        color += mix(u.palette2.rgb, u.palette3.rgb, normX) * ribbons * u.moduleA.y * lineGate * negativeSpaceMask * waveLead * 0.74;

        float morphWaves = 0.0;
        for (int i = 0; i < 6; ++i) {
            float fi = float(i) + 1.0;
            float b = bandAt(fract(fi * 0.137 + modeA * 0.19), bands);
            float d = bandDeltaAt(fract(fi * 0.137 + modeA * 0.19), bands);
            float frequency = 1.6 + fi * (0.72 + u.morphB.w * 0.58);
            float wavePhase = normX * 6.28318531 * frequency + morph * (0.85 + fi * 0.14) + u.seed * fi;
            float carrier = sin(wavePhase + sin(wavePhase * (0.31 + u.morphA.y * 0.25) + fi) * (0.9 + u.morphB.w));
            float rose = sin(angle * (2.0 + fi + u.morphA.z * 6.0) + radius * (4.0 + fi * 0.55) - morph * 1.5);
            float y = carrier * (0.075 + b * 0.15 + d * 0.13) + rose * (0.015 + u.morphA.z * 0.035);
            float line = exp(-abs(mix(p.y, sceneP.y, modeC * u.morphA.z) - y) * (24.0 + u.high * 34.0));
            morphWaves += line * (0.08 + b * 0.46 + d * 0.92);
        }
        color += mix(primary, secondary, normX + modeB * 0.2) * morphWaves * u.morphB.w * sceneGate * lineGate * waveLead * 0.54;

        float waveformEnergy = bandAt(normX, bands);
        float waveformDelta = bandDeltaAt(normX, bands);
        float scopeA = (waveformEnergy - 0.35) * 0.58 + sin(normX * 32.0 + u.time * 0.62) * 0.026;
        float scopeB = sin((normX + u.beatPhase * 0.03) * 58.0 + u.time * 0.28) * (0.018 + u.high * 0.045 + waveformDelta * 0.045);
        float waveform = exp(-abs(p.y - scopeA - scopeB) * (22.0 + u.outputPeak * 26.0));
        color += mix(u.palette1.rgb, u.palette3.rgb, waveformEnergy + waveformDelta) * waveform * u.moduleB.y * lineGate * waveLead * (0.18 + waveformEnergy * 0.34 + waveformDelta * 0.48) * heroPulse;

        float customWaveLoop = customWaveLoopField(sceneP, u, bands);
        color += mix(accent, primary, modeB) * customWaveLoop * u.moduleB.y * waveLead * lineGate * (0.15 + u.morphB.w * 0.20 + u.spectralFlux * 0.12) * heroPulse;

        float classicWaveModes = classicWaveformModes(sceneP, u, bands);
        color += mix(primary, u.palette3.rgb, spectralTilt) * classicWaveModes * u.moduleB.y * waveLead * (0.11 + u.morphB.w * 0.20 + u.onset * 0.10) * heroPulse;

        float4 milkdropWaveStack = milkdropWaveStackField(mix(sceneP, p, 0.30 + u.equationB.x * 0.20), u, bands);
        float stackGate = (0.52 + waveScene * 0.40 + equationBlendGate(u, 0.46) * 0.30) * lineGate;
        color += mix(secondary, accent, milkdropWaveStack.w) * milkdropWaveStack.x * u.moduleB.y * waveLead * stackGate * (0.10 + u.mid * 0.12 + u.spectralFlux * 0.10) * heroPulse;
        color += mix(primary, u.palette3.rgb, u.equationB.z) * milkdropWaveStack.y * u.moduleB.y * detailGate * stackGate * (0.035 + u.high * 0.070 + u.onset * 0.060) * (0.78 + audioPunch * 0.40);
        color += mix(u.palette0.rgb, primary, 0.42) * milkdropWaveStack.z * u.moduleB.y * waveLead * (0.040 + u.low * 0.045) * heroPulse;

        float superscopeBraid = superscopeBraidField(mix(p, mobiusP, 0.25 + u.morphA.w * 0.25), u, bands);
        color += mix(secondary, accent, u.phraseA.x) * superscopeBraid * u.moduleB.y * waveLead * lineGate * (0.12 + u.morphB.w * 0.18 + u.spectralFlux * 0.10) * (0.78 + waveScene * 0.48) * heroPulse;

        float harmonicScopeKnot = harmonicScopeKnotField(sceneP, u, bands);
        color += mix(primary, accent, u.phraseA.w) * harmonicScopeKnot * u.moduleB.y * waveLead * lineGate * detailGate * (0.10 + u.mid * 0.10 + u.onset * 0.12) * (0.76 + waveScene * 0.50 + sceneChangeRibbon * 0.08) * heroPulse;

        float waveformTunnel = waveformTunnelField(mobiusP, u, bands);
        color += mix(accent, primary, modeA) * waveformTunnel * u.moduleB.w * u.moduleB.y * sceneGate * compositionMask * (0.12 + u.low * 0.16 + u.beat * 0.08 + audioPunch * 0.12) * (0.78 + tunnelScene * 0.50);

        float warpMotionVectors = butterchurnWarpMotionVectors(sceneP, u, bands);
        float motionVectors = max(motionVectorGlyph(sceneP, u, bands) * 0.58, warpMotionVectors);
        float vectorGate = (0.16 + u.morphA.w * 0.26 + u.morphB.y * 0.24) * (0.45 + 0.55 * shapeLead);
        color += mix(u.palette2.rgb, u.palette3.rgb, motionVectors) * motionVectors * vectorGate * detailGate * lineGate * (0.22 + u.spectralFlux * 0.38);

        float chromaticVectors = chromaticVectorField(sceneP, u, bands);
        color += mix(accent, primary, u.equationB.y) * chromaticVectors * vectorEquation * detailGate * lineGate * (0.10 + u.high * 0.12 + u.spectralFlux * 0.10);

        float particles = 0.0;
        for (int i = 0; i < 96; ++i) {
            if (float(i) >= u.generator.x) { continue; }
            float fi = float(i) + 1.0;
            float seed = u.seed * 97.0;
            float2 star = float2(hash11(fi * 12.17 + seed), hash11(fi * 91.7 + seed)) * 2.0 - 1.0;
            star.x *= u.aspect;
            float depth = 0.25 + hash11(fi * 5.73 + seed) * 0.75;
            float spin = u.time * (0.006 + hash11(fi * 4.31) * 0.028) * u.generator.w;
            float cs = cos(spin);
            float sn = sin(spin);
            star = float2(star.x * cs - star.y * sn, star.x * sn + star.y * cs);
            star *= mix(1.25, 0.20, fract(u.time * (0.016 + depth * 0.028) + depth));
            float particleDelta = bandDeltaAt(hash11(fi * 0.37 + seed), bands);
            float pulse = 0.0020 + hash11(fi * 7.13) * 0.0045 + u.beat * 0.004 + particleDelta * 0.006;
            particles += exp(-length(p - star) / pulse) * (0.24 + hash11(fi * 3.9) * 0.50 + particleDelta * 0.70) * depth;
        }
        color += mix(u.palette1.rgb, u.palette3.rgb, u.high) * particles * u.moduleA.w * detailGate * 0.062 * (0.82 + particleScene * 0.45);

        float spectralRain = spectralRainField(sceneP, u, bands);
        color += mix(u.palette2.rgb, u.palette3.rgb, u.equationB.z) * spectralRain * rainEquation * (0.10 + u.moduleA.w * 0.10 + particleScene * 0.08 + u.high * 0.08);

        float lattice = abs(cos(foldedP.x * (9.0 + u.moduleB.z * 18.0) + u.time * 0.08)
            * cos(foldedP.y * (8.0 + u.generator.y * 16.0) - u.time * 0.06));
        lattice = pow(lattice, 12.0 - u.mid * 4.0);
        color += mix(u.palette1.rgb, u.palette2.rgb, lattice) * lattice * u.moduleB.z * detailGate * 0.22;

        float inverseRadius = 1.0 / (radius + 0.075);
        float tunnelWave = sin(inverseRadius * (1.8 + u.moduleB.w * 5.0) + angle * (2.0 + u.moduleB.z * 7.0 + modeA * 3.0) - morph * (3.0 + u.morphA.x * 4.0));
        float tunnelGrid = lineField(tunnelWave, 0.13 + u.low * 0.06) * smoothstep(1.10, 0.05, radius);
        float tunnelSpark = pow(max(0.0, 1.0 - voronoi(float2(angle * 1.8, inverseRadius * 0.9) + float2(morph * 0.2, u.seed * 4.0)) * 2.2), 3.0);
        color += mix(accent, primary, modeA) * (tunnelGrid * 0.24 + tunnelSpark * 0.075) * u.moduleB.w * sceneGate * compositionMask * (0.84 + tunnelScene * 0.40);

        float glow = exp(-radius * (2.45 - u.low * 0.55)) * (u.low * 0.32 + u.beat * 0.22 + u.reactive.z * 0.15);
        float mandala = abs(sin(atan2(foldedP.y, foldedP.x) * (3.0 + u.moduleB.z * 10.0) + foldedRadius * 13.0 - u.time * 0.12));
        color += mix(u.palette2.rgb, u.palette3.rgb, mandala) * glow * u.moduleB.x * primaryGate;

        color *= mix(0.86, 1.0, compositionMask) * negativeSpaceMask;
        float alpha = clamp(length(color) * 0.095 + heroEnergy * 0.12 + radial * 0.018 + ribbons * 0.017 + morphWaves * 0.014 + nebula * 0.018, 0.040, 0.58);
        color *= u.intensity * (0.82 + u.morphA.w * 0.12);
        return float4(color, alpha);
    }

    fragment float4 visualizer_final(VertexOut in [[stage_in]],
                                     constant VisualizerUniforms &u [[buffer(0)]],
                                     texture2d<float> frame [[texture(0)]]) {
        constexpr sampler frameSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        float morph = morphClock(u, 0.82);
        float prismPulse = softCycle(morph * 0.91 + 1.2);
        float2 center = (in.uv - 0.5) * float2(u.aspect, 1.0);
        float2 prismDirection = normalize(center + float2(0.0001, -0.0002));
        float prismAmount = u.morphB.z * (0.0011 + u.high * 0.0018 + prismPulse * 0.0010) * (0.55 + u.intensity * 0.45);
        float2 prismUV = prismDirection * prismAmount / float2(max(u.aspect, 0.001), 1.0);
        float3 color;
        color.r = frame.sample(frameSampler, in.uv + prismUV).r;
        color.g = frame.sample(frameSampler, in.uv).g;
        color.b = frame.sample(frameSampler, in.uv - prismUV).b;
        float2 fine = float2(0.0010 / max(u.aspect, 0.001), 0.0010);
        float3 localAverage = (
            frame.sample(frameSampler, in.uv + float2(fine.x, 0.0)).rgb
            + frame.sample(frameSampler, in.uv - float2(fine.x, 0.0)).rgb
            + frame.sample(frameSampler, in.uv + float2(0.0, fine.y)).rgb
            + frame.sample(frameSampler, in.uv - float2(0.0, fine.y)).rgb
        ) * 0.25;
        color += (color - localAverage) * (0.050 + u.controls.x * 0.070);
        color += mix(u.palette1.rgb, u.palette3.rgb, prismPulse) * (0.020 + u.outputPeak * 0.028) * (0.50 + u.intensity * 0.50);
        float bloomRadius = (0.0018 + u.controls.x * 0.0028 + u.reactive.z * 0.0012 + u.combo.x * 0.0007) * (0.72 + u.controls.w * 0.18);
        float2 px = float2(bloomRadius / max(u.aspect, 0.001), bloomRadius);
        float3 bloom = float3(0.0);
        bloom += max(frame.sample(frameSampler, in.uv + float2( px.x, 0.0)).rgb - 0.12, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv + float2(-px.x, 0.0)).rgb - 0.12, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv + float2(0.0,  px.y)).rgb - 0.12, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv + float2(0.0, -px.y)).rgb - 0.12, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv + px).rgb - 0.16, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv - px).rgb - 0.16, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv + float2(px.x, -px.y)).rgb - 0.16, float3(0.0));
        bloom += max(frame.sample(frameSampler, in.uv + float2(-px.x, px.y)).rgb - 0.16, float3(0.0));
        bloom *= 0.125;
        color += bloom * u.controls.y * (0.29 + u.moduleB.x * 0.44 + u.reactive.z * 0.18 + u.combo.x * 0.13);
        float3 blurPyramid = float3(0.0);
        blurPyramid += max(frame.sample(frameSampler, in.uv, level(1.0)).rgb - 0.10, float3(0.0)) * 0.42;
        blurPyramid += max(frame.sample(frameSampler, in.uv + px * 2.0, level(2.0)).rgb - 0.08, float3(0.0)) * 0.28;
        blurPyramid += max(frame.sample(frameSampler, in.uv - px * 2.6, level(2.0)).rgb - 0.08, float3(0.0)) * 0.24;
        blurPyramid += max(frame.sample(frameSampler, in.uv + float2(px.x * -3.2, px.y * 2.8), level(3.0)).rgb - 0.06, float3(0.0)) * 0.20;
        blurPyramid += max(frame.sample(frameSampler, in.uv + float2(px.x * 3.4, px.y * -2.4), level(3.0)).rgb - 0.06, float3(0.0)) * 0.18;
        color += blurPyramid * u.controls.y * (0.070 + u.moduleB.x * 0.085 + u.morphB.y * 0.065 + u.reactive.z * 0.040);
        color = mix(color, driftPalette(color, u.palette2.rgb, u.palette3.rgb, morph + u.combo.z * 6.28318531, 0.65), u.combo.x * 0.14);
        color += u.palette0.rgb * 0.024;
        float2 echoSampleUV = echoUV(in.uv, u, morph * 0.08 + prismPulse * 0.23);
        float3 echoColor = frame.sample(frameSampler, echoSampleUV).rgb;
        float echoMix = u.morphB.y * (0.035 + prismPulse * 0.055 + u.beat * 0.025);
        color = mix(color, max(color, echoColor * (0.58 + u.moduleB.w * 0.22)), echoMix);
        float2 videoEchoSampleUV = milkdropVideoEchoUV(in.uv, u);
        float3 videoEcho = frame.sample(frameSampler, videoEchoSampleUV).rgb;
        float videoEchoMix = u.morphB.y * equationBlendGate(u, 0.68) * (0.020 + u.equationB.w * 0.035 + u.beat * 0.015);
        color = mix(color, max(color, videoEcho * (0.50 + u.moduleB.w * 0.22 + u.phraseA.z * 0.12)), videoEchoMix);
        float2 tileSampleUV = tileEchoUV(in.uv, u);
        float3 tileEcho = frame.sample(frameSampler, tileSampleUV).rgb;
        float tileEchoMix = u.generatorB.x * u.morphB.y * (0.012 + u.phraseA.y * 0.032 + u.combo.x * 0.016);
        color = mix(color, max(color, tileEcho * (0.48 + u.moduleB.z * 0.18 + prismPulse * 0.12)), tileEchoMix);
        color = solarizeGrade(color, u.morphA.y * u.morphB.z * (0.018 + prismPulse * 0.045));
        float3 compHue = hueShader(in.uv, u);
        color *= mix(float3(1.0), compHue, 0.06 + u.morphB.x * 0.10 + u.combo.x * 0.04);
        float sceneGrade = sceneBlendGate(u, 0.08) * 0.22 + sceneBlendGate(u, 0.54) * 0.18 + sceneBlendGate(u, 0.86) * 0.16;
        float sceneCrossChroma = u.sceneA.z * (1.0 - u.sceneA.z) * 4.0;
        color = mix(color, driftPalette(color, compHue, u.palette3.rgb, morph + u.sceneA.x * 6.28318531, 0.72), sceneGrade * (0.035 + sceneCrossChroma * 0.025));
        float equationGrade = equationBlendGate(u, 0.10) * 0.16 + equationBlendGate(u, 0.58) * 0.14 + equationBlendGate(u, 0.80) * 0.12;
        color = mix(color, driftPalette(color, u.palette1.rgb, compHue, morph + u.equationA.x * 6.28318531, 0.62), equationGrade * (0.030 + u.equationB.w * 0.020));
        float compInvert = smoothstep(0.84, 0.99, u.phraseA.w) * u.morphA.y * u.morphB.z * 0.055;
        color = mix(color, float3(1.0) - color, compInvert);
        color = mix(color, sqrt(max(color, float3(0.0))), u.phraseA.x * u.morphB.x * 0.035);
        color = mix(color, color * color, u.phraseA.y * u.morphB.y * 0.026);
        float border = borderGlow(in.uv, u);
        color += mix(u.palette3.rgb, u.palette1.rgb, prismPulse) * border * (0.050 + u.morphB.y * 0.075 + u.beat * 0.035);
        float darkenCenter = darkenCenterAmount(center, u) * (0.035 + u.morphA.w * 0.040 + u.controls.x * 0.020);
        color *= 1.0 - darkenCenter;
        float2 aaOffset = float2(0.00115 / max(u.aspect, 0.001), 0.00115) * (0.78 + u.controls.w * 0.18);
        float3 aaNW = frame.sample(frameSampler, in.uv + float2(-aaOffset.x, -aaOffset.y)).rgb;
        float3 aaNE = frame.sample(frameSampler, in.uv + float2( aaOffset.x, -aaOffset.y)).rgb;
        float3 aaSW = frame.sample(frameSampler, in.uv + float2(-aaOffset.x,  aaOffset.y)).rgb;
        float3 aaSE = frame.sample(frameSampler, in.uv + float2( aaOffset.x,  aaOffset.y)).rgb;
        float lumaNW = dot(aaNW, float3(0.299, 0.587, 0.114));
        float lumaNE = dot(aaNE, float3(0.299, 0.587, 0.114));
        float lumaSW = dot(aaSW, float3(0.299, 0.587, 0.114));
        float lumaSE = dot(aaSE, float3(0.299, 0.587, 0.114));
        float lumaCenter = dot(color, float3(0.299, 0.587, 0.114));
        float lumaMin = min(lumaCenter, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
        float lumaMax = max(lumaCenter, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
        float edgeSmoother = smoothstep(0.08, 0.34, lumaMax - lumaMin);
        float3 fxaaResolve = (aaNW + aaNE + aaSW + aaSE + color * 2.0) * 0.16666667;
        color = mix(color, fxaaResolve, edgeSmoother * (0.10 + u.controls.w * 0.045));
        float exposure = 0.74 + u.intensity * 0.31 + u.outputPeak * 0.058 + u.combo.x * 0.030;
        float3 toneLocalAverage = acesFilm(localAverage * exposure);
        color = acesFilm(color * exposure);
        float toneLuma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float toneChroma = max(max(abs(color.r - color.g), abs(color.g - color.b)), abs(color.b - color.r));
        float whiteWash = smoothstep(0.66, 0.91, toneLuma) * (1.0 - smoothstep(0.035, 0.20, toneChroma));
        float3 rescuePalette = driftPalette(u.palette1.rgb, u.palette2.rgb, u.palette3.rgb, morph + length(center) * 0.7 + u.combo.z, 0.90);
        color = mix(color, rescuePalette * (0.38 + toneLuma * 0.42), whiteWash * (0.18 + u.combo.x * 0.16 + u.controls.y * 0.06));
        color = butterchurnCompositeFlags(color, compHue, u, whiteWash);
        color = pow(clamp(color, float3(0.0), float3(1.0)), float3(0.82));
        float drift = u.morphB.x * (0.04 + prismPulse * 0.08);
        color = mix(color, float3(color.g, color.b, color.r), drift);
        float gray = dot(color, float3(0.299, 0.587, 0.114));
        color = mix(float3(gray), color, 1.18 + u.intensity * 0.24 + u.controls.y * 0.10 + whiteWash * 0.18);
        color = chromaPreservingVibrance(color, compHue, u, whiteWash);
        color = clarityGrade(color, toneLocalAverage, u);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        if (u.flashLimit > 0.5 && luma > 0.83) {
            color *= 0.83 / max(luma, 0.001);
            color += u.palette3.rgb * min(u.beat, 0.25) * 0.045;
        }
        float vignette = smoothstep(1.08, 0.18, length((in.uv - 0.5) * float2(u.aspect, 1.0)));
        color *= 0.66 + vignette * 0.34;
        return float4(clamp(color, float3(0.0), float3(1.0)), 1.0);
    }
    """
}
