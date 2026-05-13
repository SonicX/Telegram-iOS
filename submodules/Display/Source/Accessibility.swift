import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit

public final class FocusTrackingAccessibilityElement: UIAccessibilityElement {
    public var directionalFocusIndex: Int?
    public var directionalSnapshotId: Int?
    public var focused: ((Int, Int) -> Void)?
    public var focusLost: ((Int, Int) -> Void)?
    public weak var sourceView: UIView?
    /// Local item index this proxy is pooled under.  Set by
    /// `ListView.reuseOrCreateDirectionalElement(localIndex:childOrder:sourceView:)`.
    /// Used by `handleSystemAccessibilityFocusNotification` to scroll
    /// directly to the item via `ListView.transaction(scrollToItem:)`,
    /// bypassing geometric off-screen-frame computations that fail for
    /// rotated chat history with very tall message bubbles.
    public var pinnedLocalIndex: Int?

    override public func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        if let snapshotId = directionalSnapshotId, let index = directionalFocusIndex {
            focused?(snapshotId, index)
        }
    }

    override public func accessibilityActivate() -> Bool {
        return sourceView?.accessibilityActivate() ?? false
    }

    override public func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        if let snapshotId = directionalSnapshotId, let index = directionalFocusIndex {
            focusLost?(snapshotId, index)
        }
    }
}

private func clipAccessibilityFrame(_ frame: CGRect, for node: ASDisplayNode) -> CGRect {
    guard !frame.isNull else {
        return .zero
    }
    var result = frame
    var currentNode: ASDisplayNode? = node
    while let node = currentNode {
        if let clippingContainer = node as? AccessibilityClippingContainer, let clippingFrame = clippingContainer.accessibilityClippingFrameInScreenCoordinates() {
            result = result.intersection(clippingFrame)
            if result.isNull || result.width <= 1.0 || result.height <= 1.0 {
                return .zero
            }
        }
        currentNode = node.supernode
    }
    return result
}

public func makeAccessibilityElement(of node: ASDisplayNode, container: Any, trackFocus: Bool) -> UIAccessibilityElement {
    let element: UIAccessibilityElement
    if trackFocus {
        let focusElement = FocusTrackingAccessibilityElement(accessibilityContainer: container)
        focusElement.sourceView = node.view
        element = focusElement
    } else {
        element = UIAccessibilityElement(accessibilityContainer: container)
    }
    element.accessibilityFrame = clipAccessibilityFrame(UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view), for: node)
    element.accessibilityLabel = node.accessibilityLabel
    element.accessibilityValue = node.accessibilityValue
    element.accessibilityTraits = node.accessibilityTraits
    element.accessibilityHint = node.accessibilityHint
    element.accessibilityIdentifier = node.accessibilityIdentifier
    element.accessibilityCustomActions = node.view.accessibilityCustomActions
    return element
}

private func makeFocusTrackingElement(from element: UIAccessibilityElement, container: Any, sourceView: UIView?) -> FocusTrackingAccessibilityElement {
    let focusElement = FocusTrackingAccessibilityElement(accessibilityContainer: container)
    focusElement.sourceView = sourceView
    focusElement.accessibilityFrame = element.accessibilityFrame
    focusElement.accessibilityLabel = element.accessibilityLabel
    focusElement.accessibilityValue = element.accessibilityValue
    focusElement.accessibilityTraits = element.accessibilityTraits
    focusElement.accessibilityHint = element.accessibilityHint
    focusElement.accessibilityIdentifier = element.accessibilityIdentifier
    focusElement.accessibilityCustomActions = element.accessibilityCustomActions
    return focusElement
}

public func addAccessibilityChildren(of node: ASDisplayNode, container: Any, to list: inout [Any], trackFocus: Bool = false) {
    if node.isAccessibilityElement {
        if trackFocus {
            let element = FocusTrackingAccessibilityElement(accessibilityContainer: container)
            element.sourceView = node.view
            element.accessibilityFrame = clipAccessibilityFrame(UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view), for: node)
            element.accessibilityLabel = node.accessibilityLabel
            element.accessibilityValue = node.accessibilityValue
            element.accessibilityTraits = node.accessibilityTraits
            element.accessibilityHint = node.accessibilityHint
            element.accessibilityIdentifier = node.accessibilityIdentifier
            element.accessibilityCustomActions = node.view.accessibilityCustomActions
            list.append(element)
        } else {
            let element = UIAccessibilityElement(accessibilityContainer: container)
            element.accessibilityFrame = clipAccessibilityFrame(UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view), for: node)
            element.accessibilityLabel = node.accessibilityLabel
            element.accessibilityValue = node.accessibilityValue
            element.accessibilityTraits = node.accessibilityTraits
            element.accessibilityHint = node.accessibilityHint
            element.accessibilityIdentifier = node.accessibilityIdentifier
            
            //node.accessibilityFrame = UIAccessibilityConvertFrameToScreenCoordinates(node.bounds, node.view)
            list.append(element)
        }
    } else if let accessibilityElements = node.accessibilityElements {
        if trackFocus {
            for childElement in accessibilityElements {
                guard let childElement = childElement as? UIAccessibilityElement else {
                    list.append(childElement)
                    continue
                }
                let element = makeFocusTrackingElement(from: childElement, container: container, sourceView: node.view)
                element.accessibilityFrame = clipAccessibilityFrame(childElement.accessibilityFrame, for: node)
                if !element.accessibilityFrame.isEmpty {
                    list.append(element)
                }
            }
        } else {
            for childElement in accessibilityElements {
                if let childElement = childElement as? UIAccessibilityElement {
                    childElement.accessibilityFrame = clipAccessibilityFrame(childElement.accessibilityFrame, for: node)
                    if !childElement.accessibilityFrame.isEmpty {
                        list.append(childElement)
                    }
                } else {
                    list.append(childElement)
                }
            }
        }
    }
}

public func smartInvertColorsEnabled() -> Bool {
    if #available(iOSApplicationExtension 11.0, iOS 11.0, *), UIAccessibility.isInvertColorsEnabled {
        return true
    } else {
        return false
    }
}

public func isReduceMotionEnabled() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        subscriber.putNext(UIAccessibility.isReduceMotionEnabled)
        
        let observer = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main, using: { _ in
            subscriber.putNext(UIAccessibility.isReduceMotionEnabled)
        })
        
        return ActionDisposable {
            Queue.mainQueue().async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    } |> runOn(Queue.mainQueue())
}

public func isSpeakSelectionEnabled() -> Bool {
    return UIAccessibility.isSpeakSelectionEnabled
}

public func isSpeakSelectionEnabledSignal() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        subscriber.putNext(UIAccessibility.isSpeakSelectionEnabled)
        
        let observer = NotificationCenter.default.addObserver(forName: UIAccessibility.speakSelectionStatusDidChangeNotification, object: nil, queue: .main, using: { _ in
            subscriber.putNext(UIAccessibility.isSpeakSelectionEnabled)
        })
        
        return ActionDisposable {
            Queue.mainQueue().async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    } |> runOn(Queue.mainQueue())
}

public func isBoldTextEnabled() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        subscriber.putNext(UIAccessibility.isBoldTextEnabled)
        
        let observer = NotificationCenter.default.addObserver(forName: UIAccessibility.boldTextStatusDidChangeNotification, object: nil, queue: .main, using: { _ in
            subscriber.putNext(UIAccessibility.isBoldTextEnabled)
        })
        
        return ActionDisposable {
            Queue.mainQueue().async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
    |> runOn(Queue.mainQueue())
}

public func isReduceTransparencyEnabled() -> Bool {
    UIAccessibility.isReduceTransparencyEnabled
}
