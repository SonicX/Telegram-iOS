import Foundation
import UIKit
import AsyncDisplayKit

public protocol AccessibilityFocusableNode {
    func accessibilityElementDidBecomeFocused()
}

public protocol AccessibilityClippingContainer: AnyObject {
    func accessibilityClippingFrameInScreenCoordinates() -> CGRect?
}

public final class AccessibilityAreaNode: ASDisplayNode {
    private final class View: UIView {
        weak var areaNode: AccessibilityAreaNode?

        override var accessibilityFrame: CGRect {
            get {
                return self.areaNode?.resolvedAccessibilityFrame() ?? super.accessibilityFrame
            }
            set {
                super.accessibilityFrame = newValue
            }
        }

        override func accessibilityActivate() -> Bool {
            return self.areaNode?.accessibilityActivate() ?? super.accessibilityActivate()
        }

        override func accessibilityElementDidBecomeFocused() {
            super.accessibilityElementDidBecomeFocused()
            self.areaNode?.accessibilityElementDidBecomeFocused()
        }

        override func accessibilityIncrement() {
            if let areaNode = self.areaNode {
                areaNode.accessibilityIncrement()
            } else {
                super.accessibilityIncrement()
            }
        }

        override func accessibilityDecrement() {
            if let areaNode = self.areaNode {
                areaNode.accessibilityDecrement()
            } else {
                super.accessibilityDecrement()
            }
        }
    }
    
    public var activate: (() -> Bool)?
    public var increment: (() -> Void)?
    public var decrement: (() -> Void)?
    public var focused: (() -> Void)?
    
    override public init() {
        super.init()
        
        self.setViewBlock({
            return View()
        })
        
        self.isAccessibilityElement = true
    }
    
    override public func didLoad() {
        super.didLoad()
        
        (self.view as? View)?.areaNode = self
    }
    
    override public func accessibilityActivate() -> Bool {
        return self.activate?() ?? false
    }
    
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
    
    override public func accessibilityElementDidBecomeFocused() {
        if let focused = self.focused {
            focused()
        } else {
            var supernode = self.supernode
            while true {
                if let supernodeValue = supernode {
                    if let listItemNode = supernodeValue as? AccessibilityFocusableNode {
                        listItemNode.accessibilityElementDidBecomeFocused()
                        break
                    } else {
                        supernode = supernodeValue.supernode
                    }
                } else {
                    break
                }
            }
        }
    }

    override public func accessibilityIncrement() {
        self.increment?()
    }
    
    override public func accessibilityDecrement() {
        self.decrement?()
    }
    
    @discardableResult
    public func updateFrameClippedToAccessibilityContainers(_ frame: CGRect, in containerNode: ASDisplayNode) -> Bool {
        guard let clippedFrame = self.clippedFrame(frame, in: containerNode) else {
            self.frame = .zero
            self.isAccessibilityElement = false
            return false
        }
        self.frame = clippedFrame
        self.isAccessibilityElement = true
        return true
    }

    private func clippedFrame(_ frame: CGRect, in containerNode: ASDisplayNode) -> CGRect? {
        guard !frame.isNull, frame.width > 1.0, frame.height > 1.0 else {
            return nil
        }

        var screenFrame = UIAccessibility.convertToScreenCoordinates(frame, in: containerNode.view)
        guard !screenFrame.isNull, screenFrame.width > 1.0, screenFrame.height > 1.0 else {
            return nil
        }

        var currentNode: ASDisplayNode? = containerNode
        while let node = currentNode {
            if let clippingContainer = node as? AccessibilityClippingContainer, let clippingFrame = clippingContainer.accessibilityClippingFrameInScreenCoordinates() {
                screenFrame = screenFrame.intersection(clippingFrame)
                if screenFrame.isNull || screenFrame.width <= 1.0 || screenFrame.height <= 1.0 {
                    return nil
                }
            }
            currentNode = node.supernode
        }

        let localFrame = containerNode.view.convert(screenFrame, from: nil)
        guard !localFrame.isNull, localFrame.width > 1.0, localFrame.height > 1.0 else {
            return nil
        }

        return localFrame
    }

    private func resolvedAccessibilityFrame() -> CGRect {
        guard self.isNodeLoaded, !self.isHidden, self.alpha > 0.01 else {
            return .zero
        }
        
        var frame = UIAccessibility.convertToScreenCoordinates(self.bounds, in: self.view)
        if frame.isNull {
            return .zero
        }
        
        var currentSupernode = self.supernode
        while let supernode = currentSupernode {
            if let clippingContainer = supernode as? AccessibilityClippingContainer, let clippingFrame = clippingContainer.accessibilityClippingFrameInScreenCoordinates() {
                frame = frame.intersection(clippingFrame)
                if frame.isNull || frame.width <= 1.0 || frame.height <= 1.0 {
                    return .zero
                }
            }
            currentSupernode = supernode.supernode
        }
        
        return frame
    }
}
