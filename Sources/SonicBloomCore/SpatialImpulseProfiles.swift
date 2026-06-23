import Foundation

public enum SpatialImpulseProfileImportError: Error, Equatable, LocalizedError, Sendable {
    case noImpulseResponse
    case unsupportedBinarySOFA

    public var errorDescription: String? {
        switch self {
        case .noImpulseResponse:
            "No BRIR/HRTF impulse response samples were found."
        case .unsupportedBinarySOFA:
            "Binary .sofa files need conversion to SOFA JSON before import."
        }
    }
}

public struct SpatialImpulseProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var manufacturer: String
    public var name: String
    public var sampleRate: Double
    public var nearEar: [Float]
    public var farEar: [Float]
    public var roomNear: [Float]
    public var roomFar: [Float]
    public var spatialTrim: Double
    public var crossfeedTrim: Double
    public var ambienceTrim: Double
    public var hrtfTrim: Double

    public init(
        id: String,
        manufacturer: String,
        name: String,
        sampleRate: Double,
        nearEar: [Float],
        farEar: [Float],
        roomNear: [Float] = [],
        roomFar: [Float] = [],
        spatialTrim: Double? = nil,
        crossfeedTrim: Double? = nil,
        ambienceTrim: Double? = nil,
        hrtfTrim: Double? = nil
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.name = name
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.nearEar = Self.clean(nearEar)
        self.farEar = Self.clean(farEar)
        self.roomNear = Self.clean(roomNear)
        self.roomFar = Self.clean(roomFar)
        let energy = Self.energyRatio(near: self.nearEar, far: self.farEar)
        self.spatialTrim = Self.clamp(spatialTrim ?? min(max(energy * 0.12, 0.03), 0.14), -1, 1)
        self.crossfeedTrim = Self.clamp(crossfeedTrim ?? min(max(energy * 0.06, 0.02), 0.09), -1, 1)
        self.ambienceTrim = Self.clamp(ambienceTrim ?? (self.roomNear.isEmpty && self.roomFar.isEmpty ? 0.01 : 0.04), -1, 1)
        self.hrtfTrim = Self.clamp(hrtfTrim ?? min(max(energy * 0.18, 0.06), 0.16), -1, 1)
    }

    public func headphoneProfile() -> HeadphoneProfile {
        HeadphoneProfile(
            id: id,
            manufacturer: manufacturer,
            name: name,
            calibrationBandsDB: Array(repeating: 0, count: DSPPreset.bandCount),
            spatialTrim: spatialTrim,
            crossfeedTrim: crossfeedTrim,
            ambienceTrim: ambienceTrim,
            hrtfTrim: hrtfTrim
        )
    }

    public func dspKernels(tapCount: Int = 128) -> SpatialImpulseKernels {
        let near = Self.kernelSamples(nearEar, tapCount: tapCount)
        let far = Self.kernelSamples(farEar, tapCount: tapCount)
        let roomNear = Self.kernelSamples(roomNear, tapCount: tapCount)
        let roomFar = Self.kernelSamples(roomFar, tapCount: tapCount)
        let peak = max(
            near.map(abs).max() ?? 0,
            far.map(abs).max() ?? 0,
            roomNear.map(abs).max() ?? 0,
            roomFar.map(abs).max() ?? 0
        )
        let gain = peak > 1 ? 1 / peak : 1
        return SpatialImpulseKernels(
            nearEar: near.map { $0 * gain },
            farEar: far.map { $0 * gain },
            roomNear: roomNear.map { $0 * gain },
            roomFar: roomFar.map { $0 * gain }
        )
    }

    private static func clean(_ samples: [Float]) -> [Float] {
        Array(samples.prefix(8192).map { $0.isFinite ? $0 : 0 })
    }

    private static func kernelSamples(_ samples: [Float], tapCount: Int) -> [Float] {
        let safeTapCount = max(tapCount, 0)
        return Array((samples + Array(repeating: 0, count: safeTapCount)).prefix(safeTapCount))
    }

    private static func energyRatio(near: [Float], far: [Float]) -> Double {
        let nearEnergy = max(near.reduce(Double(0)) { $0 + Double($1 * $1) }, 0.000_001)
        let farEnergy = far.reduce(Double(0)) { $0 + Double($1 * $1) }
        return min(max(farEnergy / nearEnergy, 0), 1)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

public struct SpatialImpulseKernels: Equatable, Sendable {
    public var nearEar: [Float]
    public var farEar: [Float]
    public var roomNear: [Float]
    public var roomFar: [Float]
}

public enum SpatialImpulseProfileImporter {
    public static func profile(name: String, manufacturer: String = "Imported BRIR", text: String) throws -> SpatialImpulseProfile {
        guard let data = text.data(using: .utf8) else { throw SpatialImpulseProfileImportError.noImpulseResponse }
        return try profile(name: name, manufacturer: manufacturer, data: data)
    }

    public static func profile(name: String, manufacturer: String = "Imported BRIR", data: Data) throws -> SpatialImpulseProfile {
        if data.starts(with: [0x89, 0x48, 0x44, 0x46]) {
            throw SpatialImpulseProfileImportError.unsupportedBinarySOFA
        }
        let raw = try JSONDecoder().decode(RawSpatialImpulseProfile.self, from: data)
        let near = raw.nearEar ?? raw.left ?? raw.sofaReceivers.first
        let far = raw.farEar ?? raw.right ?? raw.sofaReceivers.dropFirst().first
        guard let near, let far, !near.isEmpty, !far.isEmpty else {
            throw SpatialImpulseProfileImportError.noImpulseResponse
        }
        let title = raw.title ?? raw.name ?? name
        let resolvedName = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported BRIR" : title
        return SpatialImpulseProfile(
            id: raw.id ?? slug("\(manufacturer) \(resolvedName)"),
            manufacturer: raw.manufacturer ?? raw.listener ?? manufacturer,
            name: resolvedName,
            sampleRate: raw.sampleRate ?? 48_000,
            nearEar: near,
            farEar: far,
            roomNear: raw.roomNear ?? [],
            roomFar: raw.roomFar ?? [],
            spatialTrim: raw.spatialTrim,
            crossfeedTrim: raw.crossfeedTrim,
            ambienceTrim: raw.ambienceTrim,
            hrtfTrim: raw.hrtfTrim
        )
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).split(separator: "-").joined(separator: "-")
    }
}

public final class FFTPartitionedConvolver {
    private let blockSize: Int
    private let fftSize: Int
    private let impulseLength: Int
    private let partitions: [[FFTComplex]]

    public init(impulse: [Float], blockSize: Int = 128) throws {
        guard !impulse.isEmpty, blockSize > 0 else { throw SpatialImpulseProfileImportError.noImpulseResponse }
        let resolvedFFTSize = Self.nextPowerOfTwo(blockSize * 2)
        self.blockSize = blockSize
        self.fftSize = resolvedFFTSize
        self.impulseLength = impulse.count
        self.partitions = stride(from: 0, to: impulse.count, by: blockSize).map { start in
            var spectrum = Array(repeating: FFTComplex(), count: resolvedFFTSize)
            for index in 0..<min(blockSize, impulse.count - start) {
                spectrum[index].real = Double(impulse[start + index])
            }
            Self.fft(&spectrum, inverse: false)
            return spectrum
        }
    }

    public func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        var output = Array(repeating: Float(0), count: input.count + impulseLength - 1)
        for blockStart in stride(from: 0, to: input.count, by: blockSize) {
            var inputSpectrum = Array(repeating: FFTComplex(), count: fftSize)
            for index in 0..<min(blockSize, input.count - blockStart) {
                inputSpectrum[index].real = Double(input[blockStart + index])
            }
            Self.fft(&inputSpectrum, inverse: false)
            for (partitionIndex, partition) in partitions.enumerated() {
                var spectrum = zip(inputSpectrum, partition).map(*)
                Self.fft(&spectrum, inverse: true)
                let outputStart = blockStart + partitionIndex * blockSize
                guard outputStart < output.count else { continue }
                for index in 0..<min(fftSize, output.count - outputStart) {
                    output[outputStart + index] += Float(spectrum[index].real)
                }
            }
        }
        return output
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var power = 1
        while power < value { power <<= 1 }
        return power
    }

    private static func fft(_ values: inout [FFTComplex], inverse: Bool) {
        let count = values.count
        var j = 0
        for i in 1..<count {
            var bit = count >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j { values.swapAt(i, j) }
        }
        var length = 2
        while length <= count {
            let angle = (inverse ? 2.0 : -2.0) * Double.pi / Double(length)
            let root = FFTComplex(real: cos(angle), imaginary: sin(angle))
            for start in stride(from: 0, to: count, by: length) {
                var factor = FFTComplex(real: 1)
                for offset in 0..<(length / 2) {
                    let even = values[start + offset]
                    let odd = values[start + offset + length / 2] * factor
                    values[start + offset] = even + odd
                    values[start + offset + length / 2] = even - odd
                    factor = factor * root
                }
            }
            length <<= 1
        }
        if inverse {
            for index in values.indices {
                values[index].real /= Double(count)
                values[index].imaginary /= Double(count)
            }
        }
    }
}

private struct RawSpatialImpulseProfile: Decodable {
    var id: String?
    var manufacturer: String?
    var name: String?
    var title: String?
    var listener: String?
    var sampleRate: Double?
    var nearEar: [Float]?
    var farEar: [Float]?
    var left: [Float]?
    var right: [Float]?
    var roomNear: [Float]?
    var roomFar: [Float]?
    var sofaReceivers: [[Float]] = []
    var spatialTrim: Double?
    var crossfeedTrim: Double?
    var ambienceTrim: Double?
    var hrtfTrim: Double?

    enum CodingKeys: String, CodingKey {
        case id, manufacturer, name, sampleRate, nearEar, farEar, left, right, roomNear, roomFar, spatialTrim, crossfeedTrim, ambienceTrim, hrtfTrim
        case title = "GLOBAL_Title"
        case listener = "GLOBAL_ListenerShortName"
        case sofaSampleRate = "Data.SamplingRate"
        case sofaIR = "Data.IR"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        manufacturer = try values.decodeIfPresent(String.self, forKey: .manufacturer)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        listener = try values.decodeIfPresent(String.self, forKey: .listener)
        sampleRate = try values.decodeIfPresent(Double.self, forKey: .sampleRate)
            ?? values.decodeFirstDouble(forKey: .sofaSampleRate)
        nearEar = try values.decodeIfPresent([Float].self, forKey: .nearEar)
        farEar = try values.decodeIfPresent([Float].self, forKey: .farEar)
        left = try values.decodeIfPresent([Float].self, forKey: .left)
        right = try values.decodeIfPresent([Float].self, forKey: .right)
        roomNear = try values.decodeIfPresent([Float].self, forKey: .roomNear)
        roomFar = try values.decodeIfPresent([Float].self, forKey: .roomFar)
        spatialTrim = try values.decodeIfPresent(Double.self, forKey: .spatialTrim)
        crossfeedTrim = try values.decodeIfPresent(Double.self, forKey: .crossfeedTrim)
        ambienceTrim = try values.decodeIfPresent(Double.self, forKey: .ambienceTrim)
        hrtfTrim = try values.decodeIfPresent(Double.self, forKey: .hrtfTrim)
        if let ir = try? values.decode([[[Float]]].self, forKey: .sofaIR) {
            sofaReceivers = ir.first ?? []
        } else if let ir = try? values.decode([[[[Float]]]].self, forKey: .sofaIR) {
            sofaReceivers = ir.first?.first ?? []
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFirstDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let values = try? decode([Double].self, forKey: key) { return values.first }
        return nil
    }
}

private struct FFTComplex: Equatable {
    var real = 0.0
    var imaginary = 0.0

    static func + (lhs: FFTComplex, rhs: FFTComplex) -> FFTComplex {
        FFTComplex(real: lhs.real + rhs.real, imaginary: lhs.imaginary + rhs.imaginary)
    }

    static func - (lhs: FFTComplex, rhs: FFTComplex) -> FFTComplex {
        FFTComplex(real: lhs.real - rhs.real, imaginary: lhs.imaginary - rhs.imaginary)
    }

    static func * (lhs: FFTComplex, rhs: FFTComplex) -> FFTComplex {
        FFTComplex(
            real: lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            imaginary: lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }
}
