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

func resolvedAccessibilityRecoveryIndex(
    preferredStableKey: String?,
    aroundIndex: Int?,
    candidateStableKeys: [String]
) -> Int? {
    guard !candidateStableKeys.isEmpty else {
        return nil
    }
    
    if let preferredStableKey {
        let matchingIndices = candidateStableKeys.enumerated().compactMap { index, stableKey in
            stableKey == preferredStableKey ? index : nil
        }
        if let aroundIndex, !matchingIndices.isEmpty {
            return matchingIndices.min(by: { abs($0 - aroundIndex) < abs($1 - aroundIndex) })
        } else if let firstMatchingIndex = matchingIndices.first {
            return firstMatchingIndex
        }
    }
    
    if let aroundIndex {
        return max(0, min(aroundIndex, candidateStableKeys.count - 1))
    } else {
        return max(0, min(candidateStableKeys.count / 2, candidateStableKeys.count - 1))
    }
}
