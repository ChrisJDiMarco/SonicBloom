import XCTest
import SonicBloomCore
@testable import SonicBloomApp

final class SonicBloomAppTests: XCTestCase {
    @MainActor
    func testSelectedPresetWinsOverSuggestedForegroundAppPreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)

        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.profileAudioRefreshCountForTesting = 0
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
        XCTAssertEqual(viewModel.profileAudioRefreshCountForTesting, 0)
    }

    @MainActor
    func testForegroundAppSwitchDoesNotChangeLiveSyncMode() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)
        viewModel.settings = SonicBloomSettings(syncMode: .music)

        viewModel.setForegroundAppBundleIdentifierForTesting("com.spotify.client")
        XCTAssertEqual(viewModel.processingSyncModeForTesting, .music)

        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        XCTAssertEqual(viewModel.processingSyncModeForTesting, .music)
    }

    @MainActor
    func testSavedAppRuleDoesNotOverrideMasterPreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)

        viewModel.profile.upsert(AppAudioRule(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Chrome",
            isMuted: true,
            presetName: DSPPreset.spokenVoice.name
        ))
        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
        XCTAssertGreaterThan(viewModel.processingPresetForTesting.outputGainDB, -60)
    }

    @MainActor
    func testAppProfileCanApplyToForegroundAppWhenEnabled() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)

        viewModel.profile.upsert(AppAudioRule(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Chrome",
            gainDB: -3,
            presetName: DSPPreset.spokenVoice.name
        ))
        viewModel.settings = SonicBloomSettings(applyAppProfilesAutomatically: true)
        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.spokenVoice.name)
        XCTAssertLessThan(viewModel.processingPresetForTesting.outputGainDB, DSPPreset.spokenVoice.outputGainDB)
    }

    @MainActor
    func testAutomaticAppProfilesIgnoreUnsavedSuggestions() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)

        viewModel.settings = SonicBloomSettings(applyAppProfilesAutomatically: true)
        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
    }

    @MainActor
    func testSmartMeterDoesNotChangeMasterPreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)
        viewModel.settings = SonicBloomSettings(smartPresetMatching: true)
        viewModel.isBridgeRunning = true
        viewModel.selectedPreset = .deepBass

        for _ in 0..<6 {
            viewModel.handleMeterForTesting(DSPMeter(lowEnergy: 0.14, midEnergy: 0.20, highEnergy: 0.18))
        }

        XCTAssertEqual(viewModel.selectedPreset.name, DSPPreset.deepBass.name)
    }

    func testPerAppMixerLeavesRoomForRouteActionTray() {
        XCTAssertGreaterThanOrEqual(
            PerAppMixerLayout.bottomScrollClearance,
            PerAppMixerLayout.routeActionTrayHeight + PerAppMixerLayout.sectionSpacing
        )
        XCTAssertGreaterThanOrEqual(
            PerAppMixerLayout.panelHeight,
            PerAppMixerLayout.minimumPanelHeight(visibleRows: 4)
        )
    }

    func testBridgeEnqueuesPerAppFramesIntoPlaybackRing() {
        let bridge = SonicBloomAudioBridge()
        bridge.prepareRingForTesting(capacity: 8)

        bridge.enqueueAppFrames([StereoFrame(left: 0.25, right: -0.5)], observedCallbackFrames: 1)

        XCTAssertEqual(bridge.drainFramesForTesting(count: 1), [
            StereoFrame(left: 0.25, right: -0.5)
        ])
        bridge.stop()
    }
}
