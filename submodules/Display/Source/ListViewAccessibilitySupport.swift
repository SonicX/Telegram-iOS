import Foundation

public func resolvedAccessibilityVisibleRange(
    displayedVisibleRange: ListViewVisibleItemRange?,
    visibleNodeIndices: [Int]
) -> (first: Int, last: Int)? {
    let sortedVisibleNodeIndices = visibleNodeIndices.sorted()
    let visibleNodesRange: (first: Int, last: Int)? = sortedVisibleNodeIndices.first.flatMap { first in
        sortedVisibleNodeIndices.last.map { last in
            (first: first, last: last)
        }
    }
    
    guard let displayedVisibleRange else {
        return visibleNodesRange
    }
    
    if let visibleNodesRange {
        // Guard against transient states when displayed range collapses to one index.
        if displayedVisibleRange.firstIndex == displayedVisibleRange.lastIndex, visibleNodesRange.first < visibleNodesRange.last {
            return visibleNodesRange
        }
    }
    
    return (first: displayedVisibleRange.firstIndex, last: displayedVisibleRange.lastIndex)
}

public func shouldPostVoiceOverScreenChangedOnAppear(isVoiceOverRunning: Bool) -> Bool {
    return isVoiceOverRunning
}
