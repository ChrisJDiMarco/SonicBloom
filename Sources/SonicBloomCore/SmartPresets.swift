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
    private let cooldownObservations: Int
    private var candidate: SmartContentProfile?
    private var count = 0
    private var emitted: SmartContentProfile?
    private var cooldownRemaining = 0

    public init(requiredMatches: Int = 6, cooldownObservations: Int = 10) {
        self.requiredMatches = max(1, requiredMatches)
        self.cooldownObservations = max(0, cooldownObservations)
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
        if cooldownRemaining > 0 {
            cooldownRemaining -= 1
            return nil
        }
        guard count >= requiredMatches, emitted != profile else { return nil }
        emitted = profile
        cooldownRemaining = cooldownObservations
        return SmartPresetAdvisor.preset(for: profile)
    }

    public mutating func reset() {
        candidate = nil
        count = 0
        cooldownRemaining = 0
    }
}
