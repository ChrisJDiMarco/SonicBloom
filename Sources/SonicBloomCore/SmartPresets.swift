import Foundation

public enum SmartContentProfile: String, Codable, Equatable, Sendable {
    case quiet
    case speech
    case music
    case movie
}

public enum SmartPresetAdvisor {
    public static func profile(for meter: DSPMeter) -> SmartContentProfile {
        let total = meter.lowEnergy + meter.midEnergy + meter.highEnergy
        guard total >= 0.03 else { return .quiet }
        let lowShare = meter.lowEnergy / total
        let midShare = meter.midEnergy / total
        let highShare = meter.highEnergy / total

        if midShare > 0.58, lowShare < 0.28 {
            return .speech
        }
        if lowShare > 0.46, highShare < 0.28 {
            return .movie
        }
        return .music
    }

    public static func preset(for profile: SmartContentProfile) -> DSPPreset? {
        switch profile {
        case .quiet: nil
        case .speech: .spokenVoice
        case .music: .cleanLoud
        case .movie: .movies
        }
    }
}

public struct SmartPresetStabilizer: Sendable {
    private let requiredMatches: Int
    private var candidate: SmartContentProfile?
    private var count = 0
    private var emitted: SmartContentProfile?

    public init(requiredMatches: Int = 6) {
        self.requiredMatches = max(1, requiredMatches)
    }

    public mutating func observe(_ profile: SmartContentProfile) -> DSPPreset? {
        guard profile != .quiet else {
            candidate = nil
            count = 0
            return nil
        }
        if candidate == profile {
            count += 1
        } else {
            candidate = profile
            count = 1
        }
        guard count >= requiredMatches, emitted != profile else { return nil }
        emitted = profile
        return SmartPresetAdvisor.preset(for: profile)
    }

    public mutating func reset() {
        candidate = nil
        count = 0
    }
}
