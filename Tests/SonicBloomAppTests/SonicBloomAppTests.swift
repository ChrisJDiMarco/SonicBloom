import XCTest
import SonicBloomCore
@testable import SonicBloomApp

final class SonicBloomAppTests: XCTestCase {
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
