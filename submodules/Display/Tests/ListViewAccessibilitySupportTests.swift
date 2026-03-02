import XCTest
@testable import Display

final class ListViewAccessibilitySupportTests: XCTestCase {
    func testResolvedRangePrefersDisplayedRangeWhenConsistent() {
        let displayed = ListViewVisibleItemRange(firstIndex: 4, firstIndexFullyVisible: true, lastIndex: 9)
        
        let range = resolvedAccessibilityVisibleRange(
            displayedVisibleRange: displayed,
            visibleNodeIndices: [4, 5, 6, 7, 8, 9]
        )
        
        XCTAssertEqual(range?.first, 4)
        XCTAssertEqual(range?.last, 9)
    }
    
    func testResolvedRangeFallsBackToVisibleNodesWhenDisplayedRangeCollapses() {
        let displayed = ListViewVisibleItemRange(firstIndex: 6, firstIndexFullyVisible: true, lastIndex: 6)
        
        let range = resolvedAccessibilityVisibleRange(
            displayedVisibleRange: displayed,
            visibleNodeIndices: [5, 6, 7, 8, 9, 10]
        )
        
        XCTAssertEqual(range?.first, 5)
        XCTAssertEqual(range?.last, 10)
    }
    
    func testResolvedRangeUsesVisibleNodesWhenDisplayedRangeMissing() {
        let range = resolvedAccessibilityVisibleRange(
            displayedVisibleRange: nil,
            visibleNodeIndices: [20, 22, 21]
        )
        
        XCTAssertEqual(range?.first, 20)
        XCTAssertEqual(range?.last, 22)
    }
    
    func testShouldPostVoiceOverScreenChangedOnAppear() {
        XCTAssertTrue(shouldPostVoiceOverScreenChangedOnAppear(isVoiceOverRunning: true))
        XCTAssertFalse(shouldPostVoiceOverScreenChangedOnAppear(isVoiceOverRunning: false))
    }
}
