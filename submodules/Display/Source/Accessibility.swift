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

    override public func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        let label = self.accessibilityLabel ?? ""
        let identifier = self.accessibilityIdentifier ?? ""
        print("[VO-SWIPE-DEBUG] focused-element snapshot=\(String(describing: directionalSnapshotId)) index=\(String(describing: directionalFocusIndex)) id='\(identifier)' label='\(label)'")
        if let snapshotId = directionalSnapshotId, let index = directionalFocusIndex {
            focused?(snapshotId, index)
        }
    }

    override public func accessibilityActivate() -> Bool {
        return sourceView?.accessibilityActivate() ?? false
    }

    override public func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        let label = self.accessibilityLabel ?? ""
        let identifier = self.accessibilityIdentifier ?? ""
        print("[VO-SWIPE-DEBUG] lost-focus snapshot=\(String(describing: directionalSnapshotId)) index=\(String(describing: directionalFocusIndex)) id='\(identifier)' label='\(label)'")
        if let snapshotId = directionalSnapshotId, let index = directionalFocusIndex {
            focusLost?(snapshotId, index)
        }
    }
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
    element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view)
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
            element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view)
            element.accessibilityLabel = node.accessibilityLabel
            element.accessibilityValue = node.accessibilityValue
            element.accessibilityTraits = node.accessibilityTraits
            element.accessibilityHint = node.accessibilityHint
            element.accessibilityIdentifier = node.accessibilityIdentifier
            element.accessibilityCustomActions = node.view.accessibilityCustomActions
            list.append(element)
        } else {
            let element = UIAccessibilityElement(accessibilityContainer: container)
            element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view)
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
                list.append(makeFocusTrackingElement(from: childElement, container: container, sourceView: node.view))
            }
        } else {
            list.append(contentsOf: accessibilityElements)
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
