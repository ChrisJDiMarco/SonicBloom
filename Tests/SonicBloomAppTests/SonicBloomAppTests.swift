import XCTest
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
}
