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
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
    }

    @MainActor
    func testUnsavedSuggestedAppRuleDoesNotOverrideRuntimePreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel(defaults: defaults)
        let item = AppMixerItem(
            rule: AppAudioRule(
                bundleIdentifier: "com.google.Chrome",
                displayName: "Chrome",
                presetName: DSPPreset.cleanLoud.name,
                syncMode: .video
            ),
            processID: 42,
            processObjectID: 100,
            captureStatus: .ready
        )

        let runtimeItem = viewModel.runtimeAppMixerItemForTesting(item)

        XCTAssertNil(runtimeItem.rule.presetName)
        XCTAssertNil(runtimeItem.rule.syncMode)
        XCTAssertEqual(runtimeItem.processID, item.processID)
        XCTAssertEqual(runtimeItem.processObjectID, item.processObjectID)
        XCTAssertEqual(runtimeItem.captureStatus, item.captureStatus)
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
