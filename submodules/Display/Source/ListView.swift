import UIKit
import AsyncDisplayKit
import SwiftSignalKit
import UIKitRuntimeUtils
import ObjCRuntimeUtils

private let insertionAnimationDuration: Double = 0.4

@inline(__always)
private func voDebugLog(_ message: @autoclosure () -> String) {
}

private struct VisibleHeaderNodeId: Hashable {
    var id: ListViewItemNode.HeaderId
    var affinity: Int
    
    init(id: ListViewItemNode.HeaderId, affinity: Int) {
        self.id = id
        self.affinity = affinity
    }
}

private final class ListViewBackingLayer: CALayer {
    override func setNeedsLayout() {
    }
    
    override func layoutSublayers() {
    }
    
    override func setNeedsDisplay() {
    }
    
    override func displayIfNeeded() {
    }
    
    override func needsDisplay() -> Bool {
        return false
    }
    
    override func display() {
    }
}

public final class ListViewBackingView: UIView {
    public fileprivate(set) weak var target: ListView?
    
    override public class var layerClass: AnyClass {
        return ListViewBackingLayer.self
    }
    
    override public func setNeedsLayout() {
    }
    
    override public func layoutSubviews() {
    }
    
    override public func setNeedsDisplay() {
    }
    
    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.target?.touchesBegan(touches, with: event)
    }
    
    override public func touchesCancelled(_ touches: Set<UITouch>?, with event: UIEvent?) {
        self.target?.touchesCancelled(touches, with: event)
    }
    
    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.target?.touchesMoved(touches, with: event)
    }
    
    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.target?.touchesEnded(touches, with: event)
    }
    
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.isHidden, let target = self.target {
            if target.bounds.contains(point) {
                if target.decelerationAnimator != nil {
                    target.decelerationAnimator?.isPaused = true
                    target.decelerationAnimator = nil
                }
            }
            if target.limitHitTestToNodes, !target.internalHitTest(point, with: event) {
                return nil
            }
            if let result = target.headerHitTest(point, with: event) {
                return result
            }
        }
        return super.hitTest(point, with: event)
    }
    
    override public func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        voDebugLog("[VO-DEBUG] ListViewBackingView.accessibilityScroll called, direction=\(direction.rawValue), target=\(self.target != nil)")
        return self.target?.accessibilityScroll(direction) ?? false
    }
}

private final class ListViewTimerProxy: NSObject {
    private let action: () -> ()
    
    init(_ action: @escaping () -> ()) {
        self.action = action
        super.init()
    }
    
    @objc func timerEvent() {
        self.action()
    }
}

public enum ListViewVisibleContentOffset {
    case known(CGFloat)
    case unknown
    case none
}

public enum ListViewScrollDirection {
    case up
    case down
}

public struct ListViewKeepTopItemOverscrollBackground {
    public let color: UIColor
    public let direction: Bool
    
    public init(color: UIColor, direction: Bool) {
        self.color = color
        self.direction = direction
    }
    
    fileprivate func isEqual(to: ListViewKeepTopItemOverscrollBackground) -> Bool {
        if !self.color.isEqual(to.color) {
            return false
        }
        if self.direction != to.direction {
            return false
        }
        return true
    }
}

public enum GeneralScrollDirection {
    case up
    case down
}

public enum ListViewAccessibilityNavigationOrder {
    case natural
    case reversed
}

private func cancelContextGestures(view: UIView) {
    if let gestureRecognizers = view.gestureRecognizers {
        for gesture in gestureRecognizers {
            if let gesture = gesture as? ContextGesture {
                gesture.cancel()
            }
        }
    }
    for subview in view.subviews {
        cancelContextGestures(view: subview)
    }
}

open class ListView: ASDisplayNode, ASScrollViewDelegate, ASGestureRecognizerDelegate, AccessibilityClippingContainer {
    public struct ScrollingIndicatorState {
        public struct Item {
            public var index: Int
            public var offset: CGFloat
            public var height: CGFloat

            public init(
                index: Int,
                offset: CGFloat,
                height: CGFloat
            ) {
                self.index = index
                self.offset = offset
                self.height = height
            }
        }

        public var insets: UIEdgeInsets
        public var topItem: Item
        public var bottomItem: Item
        public var itemCount: Int

        public init(
            insets: UIEdgeInsets,
            topItem: Item,
            bottomItem: Item,
            itemCount: Int
        ) {
            self.insets = insets
            self.topItem = topItem
            self.bottomItem = bottomItem
            self.itemCount = itemCount
        }
    }

    public final let scroller: ListViewScroller
    public private(set) final var visibleSize: CGSize = CGSize()
    public private(set) final var insets = UIEdgeInsets()
    public final var visualInsets: UIEdgeInsets?
    private var itemOffsetInsets: UIEdgeInsets?
    public final var dynamicVisualInsets: (() -> UIEdgeInsets)?
    public private(set) final var headerInsets = UIEdgeInsets()
    public private(set) final var scrollIndicatorInsets = UIEdgeInsets()
    private final var ensureTopInsetForOverlayHighlightedItems: CGFloat?
    private final var lastContentOffset: CGPoint = CGPoint()
    private final var lastContentOffsetTimestamp: CFAbsoluteTime = 0.0
    private final var ignoreScrollingEvents: Bool = false
    public final var globalIgnoreScrollingEvents: Bool = false
    public final var ignoreStopScrolling: Bool = false

    private let infiniteScrollSize: CGFloat
    
    private final var displayLink: CADisplayLink!
    private final var needsAnimations = false
    
    public final var dynamicBounceEnabled = true
    public final var rotated = false
    public final var experimentalSnapScrollToItem = false
    public final var useMainQueueTransactions = false
    
    public final var scrollEnabled: Bool = true {
        didSet {
            self.scroller.isScrollEnabled = self.scrollEnabled
        }
    }
    
    private final var invisibleInset: CGFloat = 500.0
    public var preloadPages: Bool = true {
        didSet {
            if self.preloadPages != oldValue {
                self.invisibleInset = self.preloadPages ? 500.0 : 20.0
                //self.invisibleInset = self.preloadPages ? 20.0 : 20.0
                if self.preloadPages {
                    self.enqueueUpdateVisibleItems(synchronous: false)
                }
            }
        }
    }
    
    // When set (e.g. while VoiceOver is active), overrides `invisibleInset` at
    // state-creation time.  Used to force `ListView` to materialise *every*
    // item in the list so that the accessibility array really contains all of
    // them – otherwise VoiceOver can only traverse the ~screen-sized buffer
    // that ListView normally keeps realised and eventually escapes the list.
    public var accessibilityInvisibleInsetOverride: CGFloat? {
        didSet {
            if self.accessibilityInvisibleInsetOverride != oldValue {
                self.enqueueUpdateVisibleItems(synchronous: false)
            }
        }
    }

    private var effectiveInvisibleInset: CGFloat {
        if let override = self.accessibilityInvisibleInsetOverride {
            return override
        }
        return self.invisibleInset
    }
    
    public final var keepMinimalScrollHeightWithTopInset: CGFloat?
    
    public final var itemNodeHitTest: ((CGPoint) -> Bool)?
    
    public final var stackFromBottom: Bool = false
    public final var stackFromBottomInsetItemFactor: CGFloat = 0.0
    public final var limitHitTestToNodes: Bool = false
    public final var keepTopItemOverscrollBackground: ListViewKeepTopItemOverscrollBackground? {
        didSet {
            if let value = self.keepTopItemOverscrollBackground {
                self.topItemOverscrollBackground?.color = value.color
            }
            self.updateTopItemOverscrollBackground(transition: .immediate)
        }
    }
    public final var keepBottomItemOverscrollBackground: UIColor? {
        didSet {
            if let color = self.keepBottomItemOverscrollBackground {
                self.bottomItemOverscrollBackground?.backgroundColor = color
            }
            self.updateBottomItemOverscrollBackground()
        }
    }
    public final var snapToBottomInsetUntilFirstInteraction: Bool = false
    public final var allowInsetFixWhileTracking: Bool = false
    
    public final var updateFloatingHeaderOffset: ((CGFloat, ContainedViewLayoutTransition) -> Void)?
    public final var didScrollWithOffset: ((CGFloat, ContainedViewLayoutTransition, ListViewItemNode?, Bool) -> Void)?
    public final var addContentOffset: ((CGFloat, ListViewItemNode?) -> Void)?
    public final var shouldStopScrolling: ((CGFloat) -> Bool)?
    public final var onContentsUpdated: ((ContainedViewLayoutTransition) -> Void)?

    public final var updateScrollingIndicator: ((ScrollingIndicatorState?, ContainedViewLayoutTransition) -> Void)?
    
    private var topItemOverscrollBackground: ListViewOverscrollBackgroundNode?
    private var bottomItemOverscrollBackground: ASDisplayNode?
    
    private var itemHighlightOverlayBackground: ASDisplayNode?
    
    private var verticalScrollIndicator: ASImageNode?
    public var verticalScrollIndicatorColor: UIColor? {
        didSet {
            if let fillColor = self.verticalScrollIndicatorColor {
                if self.verticalScrollIndicator == nil {
                    let verticalScrollIndicator = ASImageNode()
                    verticalScrollIndicator.isUserInteractionEnabled = false
                    verticalScrollIndicator.alpha = 0.0
                    verticalScrollIndicator.image = generateStretchableFilledCircleImage(diameter: 3.0, color: fillColor)
                    self.verticalScrollIndicator = verticalScrollIndicator
                    self.addSubnode(verticalScrollIndicator)
                }
            } else {
                self.verticalScrollIndicator?.removeFromSupernode()
                self.verticalScrollIndicator = nil
            }
        }
    }
    public final var verticalScrollIndicatorFollowsOverscroll: Bool = false
    
    private var touchesPosition = CGPoint()
    public private(set) var isTracking = false
    public private(set) var trackingOffset: CGFloat = 0.0
    public private(set) var beganTrackingAtTopOrigin = false
    public private(set) var isDragging = false
    public private(set) var isDeceleratingAfterTracking = false
    
    private var isTrackingOrDecelerating: Bool {
        return self.isTracking || self.isDragging || self.isDeceleratingAfterTracking
    }
    
    private final var transactionQueue: ListViewTransactionQueue
    private final var transactionOffset: CGFloat = 0.0
    
    private final var enqueuedUpdateVisibleItems = false
    
    private final var createdItemNodes = 0
    
    public final var synchronousNodes = false
    public final var debugInfo = false
    
    public final var useSingleDimensionTouchPoint = false
    
    public var enableExtractedBackgrounds: Bool = false {
        didSet {
            if self.enableExtractedBackgrounds != oldValue {
                if self.enableExtractedBackgrounds {
                    let extractedBackgroundsContainerNode = ASDisplayNode()
                    self.extractedBackgroundsContainerNode = extractedBackgroundsContainerNode
                    self.insertSubnode(extractedBackgroundsContainerNode, at: 0)
                } else if let extractedBackgroundsContainerNode = self.extractedBackgroundsContainerNode {
                    self.extractedBackgroundsContainerNode = nil
                    extractedBackgroundsContainerNode.removeFromSupernode()
                }
            }
        }
    }
    private final var extractedBackgroundsContainerNode: ASDisplayNode?
    
    private final var items: [ListViewItem] = []
    private final var itemNodes: [ListViewItemNode] = []
    private final var itemHeaderNodes: [VisibleHeaderNodeId: ListViewItemHeaderNode] = [:]
    
    public final var itemHeaderNodesAlpha: CGFloat = 1.0
    
    public final var displayedItemRangeChanged: (ListViewDisplayedItemRange, Any?) -> Void = { _, _ in }
    public private(set) final var displayedItemRange: ListViewDisplayedItemRange = ListViewDisplayedItemRange(loadedRange: nil, visibleRange: nil)
    public private(set) final var internalDisplayedItemRange: ListViewDisplayedItemRange?
    
    public private(set) final var opaqueTransactionState: Any?
    
    public final var visibleContentOffsetChanged: (ListViewVisibleContentOffset) -> Void = { _ in }
    public final var visibleBottomContentOffsetChanged: (ListViewVisibleContentOffset) -> Void = { _ in }
    public final var beganInteractiveDragging: (CGPoint) -> Void = { _ in }
    public final var endedInteractiveDragging: (CGPoint) -> Void = { _ in }
    public final var didEndScrolling: ((Bool) -> Void)?
    public final var didEndScrollingWithOverscroll: (() -> Void)?
    
    
    private var currentGeneralScrollDirection: GeneralScrollDirection?
    public final var generalScrollDirectionUpdated: (GeneralScrollDirection) -> Void = { _ in }
    
    public var autoScrollWhenReordering = true
    public private(set) var isReordering = false
    public final var willBeginReorder: (CGPoint) -> Void = { _ in }
    public final var reorderBegan: () -> Void = { }
    public final var reorderItem: (Int, Int, Any?) -> Signal<Bool, NoError> = { _, _, _ in return .single(false) }
    public final var reorderCompleted: (Any?) -> Void = { _ in }
    
    private final var animations: [ListViewAnimation] = []
    private final var actionsForVSync: [() -> ()] = []
    private final var inVSync = false
    
    private var tapGestureRecognizer: UITapGestureRecognizer?
    public final var tapped: (() -> Void)? {
        didSet {
            self.tapGestureRecognizer?.isEnabled = self.tapped != nil
        }
    }
    
    private let frictionSlider = UISlider()
    private let springSlider = UISlider()
    private let freeResistanceSlider = UISlider()
    private let scrollingResistanceSlider = UISlider()
    
    private var selectionTouchLocation: CGPoint?
    private var selectionTouchDelayTimer: Foundation.Timer?
    private var selectionLongTapDelayTimer: Foundation.Timer?
    private var flashNodesDelayTimer: Foundation.Timer?
    private var flashScrollIndicatorTimer: Foundation.Timer?
    private var highlightedItemIndex: Int?
    private var scrolledToItem: (Int, ListViewScrollPosition)?
    private var reorderNode: ListViewReorderingItemNode?
    private var reorderFeedback: HapticFeedback?
    private var reorderFeedbackDisposable: MetaDisposable?
    private var reorderInProgress: Bool = false
    private var reorderingItemsCompleted: (() -> Void)?
    private var reorderScrollStartTimestamp: Double?
    private var reorderScrollUpdateTimestamp: Double?
    private var reorderLastTimestamp: Double?
    public var reorderedItemHasShadow = true
    public var reorderingRequiresLongPress = false
    
    private let waitingForNodesDisposable = MetaDisposable()
    
    private var auxiliaryDisplayLink: CADisplayLink?
    private var auxiliaryDisplayLinkHandle: SharedDisplayLinkDriver.Link?
    private var debugView: UIView?
    private var isAuxiliaryDisplayLinkEnabled: Bool = false {
        didSet {
            if self.isAuxiliaryDisplayLinkEnabled {
                if self.auxiliaryDisplayLinkHandle == nil {
                    self.auxiliaryDisplayLinkHandle = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
                        guard let self else {
                            return
                        }
                        if self.debugView == nil {
                            let debugView = UIView(frame: CGRect(origin: CGPoint(), size: CGSize(width: 1.0, height: 1.0)))
                            debugView.backgroundColor = .black
                            debugView.alpha = 0.0001
                            self.debugView = debugView
                            self.view.addSubview(debugView)
                        }
                        if let debugView = self.debugView {
                            if debugView.frame.origin.x == 0.0 {
                                debugView.frame = CGRect(origin: CGPoint(x: 1.0, y: 0.0), size: CGSize(width: 1.0, height: 1.0))
                            } else {
                                debugView.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: 1.0, height: 1.0))
                            }
                        }
                    })
                }
            } else if let auxiliaryDisplayLinkHandle = self.auxiliaryDisplayLinkHandle {
                self.auxiliaryDisplayLinkHandle = nil
                auxiliaryDisplayLinkHandle.invalidate()
                if let debugView = self.debugView {
                    self.debugView = nil
                    debugView.removeFromSuperview()
                }
            }
            
            /*if self.isAuxiliaryDisplayLinkEnabled != oldValue {
                if self.isAuxiliaryDisplayLinkEnabled {
                    if self.auxiliaryDisplayLink == nil {
                        let displayLink = CADisplayLink(target: DisplayLinkTarget({
                        }), selector: #selector(DisplayLinkTarget.event))
                        if #available(iOS 15.0, *) {
                            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                        }
                        displayLink.add(to: RunLoop.main, forMode: .common)
                        self.auxiliaryDisplayLink = displayLink
                    }
                } else {
                    if let auxiliaryDisplayLink = self.auxiliaryDisplayLink {
                        self.auxiliaryDisplayLink = nil
                        auxiliaryDisplayLink.invalidate()
                    }
                }
            }*/
        }
    }
    
    override open var accessibilityElements: [Any]? {
        get {
            return self.customAccessibilityElements()
        } set(value) {
        }
    }

    @objc open func customAccessibilityElements() -> [Any]? {
        // Баг 1: пока список приостановлен (уходим в чат — см.
        // accessibilityFocusHandlingSuspended), отдаём VoiceOver ПУСТОЙ набор.
        // Иначе VO сам наводится на строки ещё видимого под новым экраном
        // списка и зачитывает соседний чат, пока история открываемого грузится.
        // Флаг ставит только список чатов (история его не выставляет).
        if self.accessibilityFocusHandlingSuspended {
            return nil
        }
        var accessibilityElements: [Any] = []
        let trackDirectionalFocus = self.accessibilityDirectionalAnnouncement != nil
        var directionalCandidates: [(localIndex: Int, order: Int, element: Any)] = []
        var activeLocalIndices = Set<Int>()
        let visibleTop: CGFloat
        let visibleBottom: CGFloat
        // **`visibleRect` must be in the item-node frame space, which is
        // the list view's own bounds (view space) — NOT offset by
        // `scroller.contentOffset.y`.**
        //
        // `ListView` keeps materialised item nodes positioned directly
        // in its view bounds (a visible row has `frame.minY` in
        // `[insets.top, visibleSize.height - insets.bottom]`); the hidden
        // `scroller` is only a gesture/offset proxy whose `contentOffset`
        // hovers around `infiniteScrollSize` (10 000) due to the
        // infinite-scroll trick. Adding `contentOffset.y` to the
        // viewport rect therefore shifts it ~10 000 pt away from where
        // the item frames actually are.
        //
        // For the chat *list* this went unnoticed: there
        // `contentOffset.y == 0`, so `+ contentOffset.y` was a harmless
        // no-op and `visibleRect` matched the item frames. For rotated
        // chat *history* `contentOffset.y == 10 000`, so `visibleRect`
        // landed at y≈10 144 while item frames sit at y≈-700…400 — they
        // never intersected, the filter dropped every element, and
        // `customAccessibilityElements()` returned an empty array
        // (diagnosed via the `[VO-BASE-DIAG]` log). Dropping
        // `contentOffset.y` puts `visibleRect` back in item-frame space.
        if self.rotated {
            visibleTop = self.insets.bottom
            visibleBottom = self.visibleSize.height - self.insets.top
        } else {
            visibleTop = self.insets.top
            visibleBottom = self.visibleSize.height - self.insets.bottom
        }
        let visibleRect = CGRect(x: 0.0, y: visibleTop, width: self.visibleSize.width, height: max(0.0, visibleBottom - visibleTop))
        // Expanded accessibility inclusion zone.
        //
        // Rationale (see investigation summarised in ListView comments and
        // commit log): when we only include item nodes whose frames strictly
        // intersect the visible rect, each programmatic silent-scroll of one
        // row drops *both* accessibility children of the cell exiting at the
        // top (≈2 elements removed) while the cell entering at the bottom
        // contributes only one element at a time (its second child is still
        // clipped to zero height by the visible screen rect), which produces
        // a monotonically shrinking array (8 → 7 → 6 → … → 0) that
        // inevitably pushes VoiceOver focus out of the list.
        //
        // Instead we expand the inclusion zone by one full visible screen in
        // each direction so that the entire render buffer of already-
        // materialised item nodes is admitted. Children are then passed
        // through with their *original* (potentially partially off-screen)
        // accessibilityFrame, which is something VoiceOver handles natively:
        // it keeps the element in its traversal order and — paired with the
        // offscreen-focus-scroll handling below — lets the user walk through
        // items beyond the viewport without the array ever collapsing.
        let accessibilityInclusionRect: CGRect
        if self.accessibilityInvisibleInsetOverride != nil {
            // Full-materialisation mode: include *every* materialised item,
            // regardless of on-screen position.  Combined with the huge
            // `invisibleInset` override and the on-focus
            // `scrollAccessibilityFocusIntoViewIfNeeded` path below, this lets
            // VoiceOver traverse the complete list (e.g. all 51 chats)
            // without the accessibility array ever collapsing to a screen-
            // sized window.
            let huge = CGFloat(1_000_000_000.0)
            accessibilityInclusionRect = CGRect(x: -huge / 2.0, y: -huge / 2.0, width: huge, height: huge)
        } else {
            accessibilityInclusionRect = visibleRect.insetBy(dx: 0.0, dy: -max(visibleRect.height, 1.0))
        }
        let poolClipScreenFrame = self.accessibilityClippingFrameInScreenCoordinates()
        self.forEachItemNode({ node in
            if trackDirectionalFocus {
                guard let itemNode = node as? ListViewItemNode, let itemIndex = itemNode.index else {
                    return
                }
                let intersection = itemNode.frame.intersection(accessibilityInclusionRect)
                guard !intersection.isNull, intersection.height > 1.0, intersection.width > 1.0 else {
                    return
                }
                activeLocalIndices.insert(itemIndex)
                if itemNode.isAccessibilityElement {
                    let element = self.reuseOrCreateDirectionalElement(localIndex: itemIndex, childOrder: 0, sourceView: itemNode.view)
                    var frame = UIAccessibility.convertToScreenCoordinates(itemNode.bounds, in: itemNode.view)
                    guard !frame.isNull, frame.height > 1.0, frame.width > 1.0 else {
                        return
                    }
                    // Обрезаем фрейм пулового элемента ТОЛЬКО СВЕРХУ (по кромке
                    // навбара): элемент, уехавший выше вьюпорта, накрывал навбар
                    // и VO-касания по «Назад»/заголовку доставались невидимым
                    // сообщениям. СНИЗУ НЕ обрезаем: реальные фреймы ниже
                    // вьюпорта — штатные цели свайпа ВПЕРЁД (как в списке чатов,
                    // где свайп «бесконечен»); симметричная обрезка превращала их
                    // в 2pt-полоски, VoiceOver не принимал их за цели и свайп у
                    // нижнего края выпадал в навбар вместо подскролла.
                    if let poolClipFrame = poolClipScreenFrame {
                        if frame.maxY <= poolClipFrame.minY + 1.0 {
                            // Целиком выше видимой области — полоска у верхней
                            // кромки, чтобы элемент не выпал из обхода (порядок
                            // задаётся порядком массива).
                            frame = CGRect(x: poolClipFrame.minX, y: poolClipFrame.minY, width: poolClipFrame.width, height: 2.0)
                        } else if frame.minY < poolClipFrame.minY {
                            // Частично под навбаром — срезаем только верх.
                            frame = CGRect(x: frame.minX, y: poolClipFrame.minY, width: frame.width, height: frame.maxY - poolClipFrame.minY)
                        }
                    }
                    element.accessibilityFrame = frame
                    element.accessibilityLabel = itemNode.accessibilityLabel
                    element.accessibilityValue = itemNode.accessibilityValue
                    element.accessibilityTraits = itemNode.accessibilityTraits
                    element.accessibilityHint = itemNode.accessibilityHint
                    element.accessibilityIdentifier = itemNode.accessibilityIdentifier
                    element.accessibilityCustomActions = itemNode.view.accessibilityCustomActions
                    directionalCandidates.append((localIndex: itemIndex, order: 0, element: element))
                } else if let nodeChildren = itemNode.accessibilityElements {
                    for (order, childElement) in nodeChildren.enumerated() {
                        if let child = childElement as? UIAccessibilityElement {
                            let frame = child.accessibilityFrame
                            guard !frame.isNull, frame.height > 1.0, frame.width > 1.0 else {
                                continue
                            }
                            let element = self.reuseOrCreateDirectionalElement(localIndex: itemIndex, childOrder: order, sourceView: itemNode.view)
                            element.accessibilityFrame = frame
                            element.accessibilityLabel = child.accessibilityLabel
                            element.accessibilityValue = child.accessibilityValue
                            element.accessibilityTraits = child.accessibilityTraits
                            element.accessibilityHint = child.accessibilityHint
                            element.accessibilityIdentifier = child.accessibilityIdentifier
                            element.accessibilityCustomActions = child.accessibilityCustomActions
                            directionalCandidates.append((localIndex: itemIndex, order: order, element: element))
                        } else {
                            directionalCandidates.append((localIndex: itemIndex, order: order, element: childElement))
                        }
                    }
                }
                return
            }
            let intersection = node.frame.intersection(visibleRect)
            let minimumVisibleHeight: CGFloat = node.frame.height * 0.5
            if !intersection.isNull && intersection.height > minimumVisibleHeight {
                addAccessibilityChildren(of: node, container: self, to: &accessibilityElements, trackFocus: false)
            }
        })
        if !trackDirectionalFocus && accessibilityElements.isEmpty {
            self.forEachItemNode({ node in
                let intersection = node.frame.intersection(visibleRect)
                if !intersection.isNull && intersection.height > 1.0 {
                    addAccessibilityChildren(of: node, container: self, to: &accessibilityElements, trackFocus: false)
                }
            })
        }
        if trackDirectionalFocus {
            // Баг 2: дописываем реальные trailing-элементы (кнопки) как пуловые
            // FocusTrackingAccessibilityElement с синтетическим localIndex ниже
            // минимального. После сортировки по возрастанию и reverse они
            // оказываются последними swipe-стопами (после новейшего сообщения).
            self.accessibilitySyntheticTrailingIndices.removeAll()
            if let provider = self.accessibilityTrailingPooledElementsProvider {
                let trailing = provider()
                self.accessibilitySuppressTrailingBoundaryScroll = !trailing.isEmpty
                if !trailing.isEmpty {
                    let minLocalIndex = directionalCandidates.map({ $0.localIndex }).min() ?? 0
                    for (i, item) in trailing.enumerated() {
                        let synthIndex = minLocalIndex - 1 - i
                        let element = self.reuseOrCreateDirectionalElement(localIndex: synthIndex, childOrder: 0, sourceView: item.sourceView)
                        element.accessibilityFrame = item.frame
                        element.accessibilityLabel = item.label
                        element.accessibilityValue = item.value
                        element.accessibilityHint = nil
                        element.accessibilityTraits = item.traits
                        element.accessibilityCustomActions = nil
                        directionalCandidates.append((localIndex: synthIndex, order: 0, element: element))
                        activeLocalIndices.insert(synthIndex)
                        self.accessibilitySyntheticTrailingIndices.insert(synthIndex)
                    }
                }
            }
            accessibilityElements = directionalCandidates.sorted(by: { lhs, rhs in
                if lhs.localIndex != rhs.localIndex {
                    return lhs.localIndex < rhs.localIndex
                } else {
                    return lhs.order < rhs.order
                }
            }).map(\.element)
            self.cleanupDirectionalElementPool(activeLocalIndices: activeLocalIndices)
        } else {
            accessibilityElements = accessibilityElements.enumerated().sorted(by: { lhs, rhs in
                let lhsFrame = (lhs.element as? UIAccessibilityElement)?.accessibilityFrame ?? .null
                let rhsFrame = (rhs.element as? UIAccessibilityElement)?.accessibilityFrame ?? .null
                if lhsFrame.isNull != rhsFrame.isNull {
                    return !lhsFrame.isNull
                }
                let dy = lhsFrame.minY - rhsFrame.minY
                if abs(dy) > 0.5 {
                    return dy < 0.0
                }
                let dx = lhsFrame.minX - rhsFrame.minX
                if abs(dx) > 0.5 {
                    return dx < 0.0
                }
                return lhs.offset < rhs.offset
            }).map(\.element)
        }
        if self.accessibilityNavigationOrder == .reversed {
            accessibilityElements.reverse()
        }
        self.logAccessibilityArrayDiffIfNeeded(accessibilityElements)
        self.updateAccessibilityDirectionalElements(accessibilityElements)
        return accessibilityElements.isEmpty ? nil : accessibilityElements
    }

    override public init() {
        class DisplayLinkProxy: NSObject {
            weak var target: ListView?
            init(target: ListView) {
                self.target = target
            }
            
            @objc func displayLinkEvent() {
                self.target?.displayLinkEvent()
            }
        }
        
        self.transactionQueue = ListViewTransactionQueue()
        
        self.scroller = ListViewScroller()

        self.infiniteScrollSize = 10000.0
        
        super.init()
        
        self.isAccessibilityContainer = true
        
        self.setViewBlock({ () -> UIView in
            return ListViewBackingView()
        })
        
        self.clipsToBounds = true
        
        (self.view as! ListViewBackingView).target = self
        
        self.transactionQueue.transactionCompleted = { [weak self] in
            if let strongSelf = self {
                strongSelf.updateVisibleItemRange()
            }
        }
        
        self.scroller.alwaysBounceVertical = true
        self.scroller.contentSize = CGSize(width: 0.0, height: infiniteScrollSize * 2.0)
        self.scroller.isHidden = true
        self.scroller.delegate = self.wrappedScrollViewDelegate
        self.view.addSubview(self.scroller)
        self.scroller.panGestureRecognizer.cancelsTouchesInView = true
        self.view.addGestureRecognizer(self.scroller.panGestureRecognizer)
                
        let trackingRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.trackingGesture(_:)))
        trackingRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        trackingRecognizer.cancelsTouchesInView = false
        self.view.addGestureRecognizer(trackingRecognizer)

        self.view.addGestureRecognizer(ListViewReorderingGestureRecognizer(shouldBegin: { [weak self] point in
            if let strongSelf = self, !strongSelf.isTracking {
                if let index = strongSelf.itemIndexAtPoint(point) {
                    for i in 0 ..< strongSelf.itemNodes.count {
                        if strongSelf.itemNodes[i].index == index {
                            let itemNode = strongSelf.itemNodes[i]
                            let itemNodeFrame = itemNode.frame
                            let itemNodeBounds = itemNode.bounds
                            if itemNode.isReorderable(at: point.offsetBy(dx: -itemNodeFrame.minX + itemNodeBounds.minX, dy: -itemNodeFrame.minY + itemNodeBounds.minY)) {
                                let requiresLongPress = strongSelf.reorderingRequiresLongPress
                                return (true, requiresLongPress, itemNode)
                            }
                            break
                        }
                    }
                }
            }
            return (false, false, nil)
        }, willBegin: { [weak self] point in
            self?.willBeginReorder(point)
        }, began: { [weak self] itemNode in
            self?.beginReordering(itemNode: itemNode)
        }, ended: { [weak self] in
            self?.endReordering()
        }, moved: { [weak self] offset in
            self?.updateReordering(offset: offset)
        }))
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        tapGestureRecognizer.isEnabled = false
        tapGestureRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        self.view.addGestureRecognizer(tapGestureRecognizer)
        self.tapGestureRecognizer = tapGestureRecognizer
        
        self.displayLink = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.displayLinkEvent))
        self.displayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        
        if #available(iOS 15.0, iOSApplicationExtension 15.0, *) {
            self.displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60.0, maximum: 120.0, preferred: 120.0)
        }
        
        self.displayLink.isPaused = true
        
        self.accessibilityElementFocusedObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleSystemAccessibilityFocusNotification(notification)
        }
    }
    
    deinit {
        let _ = { () -> Void in
            self.pauseAnimations()
            self.displayLink.invalidate()
            
            for i in (0 ..< self.itemNodes.count).reversed() {
                var itemNode: AnyObject? = self.itemNodes[i]
                self.itemNodes.remove(at: i)
                ASPerformMainThreadDeallocation(&itemNode)
            }
            for key in self.itemHeaderNodes.keys {
                var itemHeaderNode: AnyObject? = self.itemHeaderNodes[key]
                self.itemHeaderNodes.removeValue(forKey: key)
                ASPerformMainThreadDeallocation(&itemHeaderNode)
            }
            
            self.waitingForNodesDisposable.dispose()
            self.reorderFeedbackDisposable?.dispose()
            if let accessibilityElementFocusedObserver = self.accessibilityElementFocusedObserver {
                NotificationCenter.default.removeObserver(accessibilityElementFocusedObserver)
                self.accessibilityElementFocusedObserver = nil
            }
        }()
    }
    
    @objc private func tapGesture(_ gestureRecognizer: UITapGestureRecognizer) {
        self.tapped?()
    }
    
    private func displayLinkEvent() {
        self.updateAnimations()
    }
    
    private func setNeedsAnimations() {
        if !self.needsAnimations {
            self.needsAnimations = true
            self.displayLink.isPaused = false
        }
    }
    
    private func pauseAnimations() {
        if self.needsAnimations {
            self.needsAnimations = false
            self.displayLink.isPaused = true
        }
    }
    
    private func dispatchOnVSync(forceNext: Bool = false, action: @escaping () -> ()) {
        /*Queue.mainQueue().async {
            if !forceNext && self.inVSync {
                action()
            } else {
                action()
            }
        }*/
        if self.useMainQueueTransactions && Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
    
    private func beginReordering(itemNode: ListViewItemNode) {
        self.isReordering = true
        self.reorderBegan()
        
        if let reorderNode = self.reorderNode {
            reorderNode.removeFromSupernode()
        }
        let reorderNode = ListViewReorderingItemNode(itemNode: itemNode, initialLocation: itemNode.frame.origin, hasShadow: self.reorderedItemHasShadow)
        self.reorderNode = reorderNode
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            self.insertSubnode(reorderNode, belowSubnode: verticalScrollIndicator)
        } else {
            self.addSubnode(reorderNode)
        }
        itemNode.isHidden = true
        
        if self.reorderFeedback == nil {
            self.reorderFeedback = HapticFeedback()
        }
        self.reorderFeedback?.impact()
    }
    
    private func endReordering() {
        self.itemReorderingTimer?.invalidate()
        self.itemReorderingTimer = nil
        self.lastReorderingOffset = nil
        
        let f: () -> Void = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if let reorderNode = strongSelf.reorderNode {
                strongSelf.reorderNode = nil
                if let itemNode = reorderNode.itemNode, itemNode.supernode == strongSelf {
                    strongSelf.reorderItemNodeToFront(itemNode)
                    reorderNode.animateCompletion(completion: { [weak reorderNode] in
                        reorderNode?.removeFromSupernode()
                    })
                    strongSelf.setNeedsAnimations()
                } else {
                    reorderNode.removeFromSupernode()
                }
            }
            strongSelf.reorderCompleted(strongSelf.opaqueTransactionState)
            strongSelf.isReordering = false
        }
        if self.reorderInProgress {
            self.reorderingItemsCompleted = f
        } else {
            f()
        }
    }
    
    private func updateReordering(offset: CGFloat) {
        if let reorderNode = self.reorderNode {
            if !self.autoScrollWhenReordering, case let .known(contentOffset) = self.visibleContentOffset() {
                let updatedLocation = reorderNode.initialLocation.y + offset
                if updatedLocation < self.insets.top - contentOffset {
                    return
                }
            }
            reorderNode.updateOffset(offset: offset)
            self.checkItemReordering()
        }
    }
    
    private var itemReorderingTimer: SwiftSignalKit.Timer?
    private var lastReorderingOffset: CGFloat?
    
    private func checkItemReordering(force: Bool = false) {
        guard let reorderNode = self.reorderNode, let verticalTopOffset = reorderNode.currentOffset() else {
            return
        }
        
        if let lastReorderingOffset = self.lastReorderingOffset, abs(lastReorderingOffset - verticalTopOffset) < 4.0 && !force {
            return
        }
        
        self.itemReorderingTimer?.invalidate()
        self.itemReorderingTimer = nil
        
        self.lastReorderingOffset = verticalTopOffset
        
        if !force {
            self.itemReorderingTimer = SwiftSignalKit.Timer(timeout: 0.025, repeat: false, completion: { [weak self] in
                self?.checkItemReordering(force: true)
            }, queue: Queue.mainQueue())
            self.itemReorderingTimer?.start()
            return
        }
        
        let timestamp = CACurrentMediaTime()
        if let reorderItemNode = reorderNode.itemNode, let reorderItemIndex = reorderItemNode.index, reorderItemNode.supernode == self {
            let verticalOffset = verticalTopOffset
            var closestIndex: (Int, CGFloat)?
            for i in 0 ..< self.itemNodes.count {
                if let itemNodeIndex = self.itemNodes[i].index, itemNodeIndex != reorderItemIndex {
                    let itemFrame = self.itemNodes[i].apparentContentFrame

                    let offsetToMin = itemFrame.minY - verticalOffset
                    let offsetToMax = itemFrame.maxY - verticalOffset
                    let deltaOffset: CGFloat
                    if abs(offsetToMin) > abs(offsetToMax) {
                        deltaOffset = offsetToMax
                    } else {
                        deltaOffset = offsetToMin
                    }
                    if let (_, closestOffset) = closestIndex {
                        if abs(deltaOffset) < abs(closestOffset) {
                            closestIndex = (itemNodeIndex, deltaOffset)
                        }
                    } else {
                        closestIndex = (itemNodeIndex, deltaOffset)
                    }
                }
            }
            if let (closestIndexValue, offset) = closestIndex {
//                print("closest \(closestIndexValue) offset \(offset)")
                var toIndex: Int
                if offset > 0 {
                    toIndex = closestIndexValue
                    if toIndex > reorderItemIndex {
                        toIndex -= 1
                    }
                } else {
                    toIndex = closestIndexValue + 1
                    if toIndex > reorderItemIndex {
                        toIndex -= 1
                    }
                }
                if toIndex != reorderItemNode.index {
                    if let reorderLastTimestamp = self.reorderLastTimestamp, timestamp < reorderLastTimestamp + 0.2 {
                        return
                    }
                    if reorderNode.currentState?.0 != reorderItemIndex || reorderNode.currentState?.1 != toIndex {
                        self.reorderLastTimestamp = timestamp
                        
                        reorderNode.currentState = (reorderItemIndex, toIndex)
                        //print("reorder \(reorderItemIndex) to \(toIndex) offset \(offset)")
                        if self.reorderFeedbackDisposable == nil {
                            self.reorderFeedbackDisposable = MetaDisposable()
                        }
                        self.reorderInProgress = true
                        self.reorderFeedbackDisposable?.set((self.reorderItem(reorderItemIndex, toIndex, self.opaqueTransactionState)
                        |> deliverOnMainQueue).start(next: { [weak self] value in
                            guard let strongSelf = self else {
                                return
                            }
                            
                            strongSelf.reorderInProgress = false
                            if let reorderingItemsCompleted = strongSelf.reorderingItemsCompleted {
                                strongSelf.reorderingItemsCompleted = nil
                                reorderingItemsCompleted()
                            }
                            
                            if !value {
                                return
                            }
                            if strongSelf.reorderFeedback == nil {
                                strongSelf.reorderFeedback = HapticFeedback()
                            }
                            strongSelf.reorderFeedback?.impact()
                        }))
                    }
                }
            }
            
            self.setNeedsAnimations()
        }
    }
    
    public func flashHeaderItems(duration: Double = 2.0) {
        self.resetHeaderItemsFlashTimer(start: true, duration: duration)
    }
    
    private func resetHeaderItemsFlashTimer(start: Bool, duration: Double = 0.3) {
        if let flashNodesDelayTimer = self.flashNodesDelayTimer {
            flashNodesDelayTimer.invalidate()
            self.flashNodesDelayTimer = nil
        }
        
        if start {
            let timer = Timer(timeInterval: duration, target: ListViewTimerProxy { [weak self] in
                if let strongSelf = self {
                    if let flashNodesDelayTimer = strongSelf.flashNodesDelayTimer {
                        flashNodesDelayTimer.invalidate()
                        strongSelf.flashNodesDelayTimer = nil
                        strongSelf.updateHeaderItemsFlashing(animated: true)
                    }
                }
            }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
            self.flashNodesDelayTimer = timer
            RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
            self.updateHeaderItemsFlashing(animated: true)
        }
    }
    
    private func resetScrollIndicatorFlashTimer(start: Bool) {
        if let flashScrollIndicatorTimer = self.flashScrollIndicatorTimer {
            flashScrollIndicatorTimer.invalidate()
            self.flashScrollIndicatorTimer = nil
        }
        
        if start {
            let timer = Timer(timeInterval: 0.1, target: ListViewTimerProxy { [weak self] in
                if let strongSelf = self {
                    if let flashScrollIndicatorTimer = strongSelf.flashScrollIndicatorTimer {
                        flashScrollIndicatorTimer.invalidate()
                        strongSelf.flashScrollIndicatorTimer = nil
                        strongSelf.verticalScrollIndicator?.alpha = 0.0
                        strongSelf.verticalScrollIndicator?.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
                    }
                }
            }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
            self.flashScrollIndicatorTimer = timer
            RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
        } else {
            self.verticalScrollIndicator?.layer.removeAnimation(forKey: "opacity")
            self.verticalScrollIndicator?.alpha = 1.0
        }
    }
    
    private func headerItemsAreFlashing() -> Bool {
        //print("\(self.scroller.isDragging) || (\(self.scroller.isDecelerating) && \(self.isDeceleratingAfterTracking)) || \(self.flashNodesDelayTimer != nil)")
        return self.scroller.isDragging || (self.isDeceleratingAfterTracking) || self.flashNodesDelayTimer != nil
    }
    
    private func updateHeaderItemsFlashing(animated: Bool) {
        let flashing = self.headerItemsAreFlashing()
        for (_, headerNode) in self.itemHeaderNodes {
            headerNode.updateFlashingOnScrolling(flashing, animated: animated)
        }
    }
    
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.interruptAccessibilitySpeechIfNeeded()
        self.lastContentOffsetTimestamp = 0.0
        self.resetHeaderItemsFlashTimer(start: false)
        self.updateHeaderItemsFlashing(animated: true)
        self.resetScrollIndicatorFlashTimer(start: false)
        
        if self.snapToBottomInsetUntilFirstInteraction {
            self.snapToBottomInsetUntilFirstInteraction = false
        }
        self.scrolledToItem = nil

        self.scroller.forceDecelerating = false
        self.isDragging = true
        
        self.beganInteractiveDragging(self.touchesPosition)
        
        for itemNode in self.itemNodes {
            if !itemNode.isLayerBacked {
                cancelContextGestures(view: itemNode.view)
            }
        }
    }
    
    public func resetScrolledToItem() {
        self.scrolledToItem = nil
    }
    
    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if let shouldStopScrolling = self.shouldStopScrolling, shouldStopScrolling(velocity.y) {
            targetContentOffset.pointee.y = scrollView.contentOffset.y
        }
    }
    
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.isDragging = false
        if decelerate {
            self.lastContentOffsetTimestamp = CACurrentMediaTime()
            self.isDeceleratingAfterTracking = true
            self.updateHeaderItemsFlashing(animated: true)
            self.resetScrollIndicatorFlashTimer(start: false)
            
            self.isAuxiliaryDisplayLinkEnabled = true
            
            if scrollView.contentOffset.y < -48.0 {
                self.didEndScrollingWithOverscroll?()
            }
        } else {
            self.isDeceleratingAfterTracking = false
            self.resetHeaderItemsFlashTimer(start: true)
            self.updateHeaderItemsFlashing(animated: true)
            self.resetScrollIndicatorFlashTimer(start: true)
            
            self.lastContentOffsetTimestamp = 0.0
            self.isAuxiliaryDisplayLinkEnabled = false
        }
        self.ignoreScrollingEvents = true
        self.ignoreScrollingEvents = false
        self.endedInteractiveDragging(self.touchesPosition)
        if !decelerate {
            self.didEndScrolling?(false)
        }
    }
    
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.lastContentOffsetTimestamp = 0.0
        self.isDeceleratingAfterTracking = false
        self.resetHeaderItemsFlashTimer(start: true)
        self.updateHeaderItemsFlashing(animated: true)
        self.resetScrollIndicatorFlashTimer(start: true)
        self.isAuxiliaryDisplayLinkEnabled = false
        if !scrollView.isTracking {
            self.didEndScrolling?(true)
        }
    }
    
    fileprivate var decelerationAnimator: ConstantDisplayLinkAnimator?
    private var accumulatedTransferVelocityOffset: CGFloat = 0.0
    
    public func transferVelocity(_ velocity: CGFloat) {
        self.decelerationAnimator?.isPaused = true
        let startTime = CACurrentMediaTime()
        let decelerationRate: CGFloat = 0.998
        self.scroller.forceDecelerating = true
        self.decelerationAnimator = ConstantDisplayLinkAnimator(update: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            let t = CACurrentMediaTime() - startTime
            var currentVelocity = velocity * 15.0 * CGFloat(pow(Double(decelerationRate), 1000.0 * t))
            strongSelf.accumulatedTransferVelocityOffset += currentVelocity
            let signFactor: CGFloat = strongSelf.accumulatedTransferVelocityOffset >= 0.0 ? 1.0 : -1.0
            let remainder = abs(strongSelf.accumulatedTransferVelocityOffset).remainder(dividingBy: UIScreenPixel)
            //print("accumulated \(strongSelf.accumulatedTransferVelocityOffset), \(remainder), resulting accumulated \(strongSelf.accumulatedTransferVelocityOffset - remainder * signFactor) add delta \(strongSelf.accumulatedTransferVelocityOffset - remainder * signFactor)")
            var currentOffset = strongSelf.scroller.contentOffset
            let addedDela = strongSelf.accumulatedTransferVelocityOffset - remainder * signFactor
            currentOffset.y += addedDela
            strongSelf.accumulatedTransferVelocityOffset -= addedDela
            let maxOffset = strongSelf.scroller.contentSize.height - strongSelf.scroller.bounds.height
            if currentOffset.y >= maxOffset {
                currentOffset.y = maxOffset
                currentVelocity = 0.0
            }
            if currentOffset.y < 0.0 {
                currentOffset.y = 0.0
                currentVelocity = 0.0
            }
            
            if abs(currentVelocity) < 0.1 {
                strongSelf.scroller.forceDecelerating = false
                strongSelf.decelerationAnimator?.isPaused = true
                strongSelf.decelerationAnimator = nil
            }
            var contentOffset = strongSelf.scroller.contentOffset
            contentOffset.y = floorToScreenPixels(currentOffset.y)
            strongSelf.scroller.setContentOffset(contentOffset, animated: false)
        })
        self.decelerationAnimator?.isPaused = false
    }
    
    public var defaultToSynchronousTransactionWhileScrolling: Bool = false
    
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateScrollViewDidScroll(scrollView, synchronous: self.defaultToSynchronousTransactionWhileScrolling)
        scrollView.fixScrollDisplayLink()
    }
    
    private var generalAccumulatedDeltaY: CGFloat = 0.0
    private var previousDidScrollTimestamp: Double = 0.0
    
    private var ignoreNextScrollAdjustment: Bool = false
    
    private func updateScrollViewDidScroll(_ scrollView: UIScrollView, synchronous: Bool) {
        if self.ignoreScrollingEvents || scroller !== self.scroller {
            return
        }
        if self.globalIgnoreScrollingEvents {
            return
        }

        /*let timestamp = CACurrentMediaTime()
        if !self.previousDidScrollTimestamp.isZero {
            let delta = timestamp - self.previousDidScrollTimestamp
            if delta < 0.1 {
                print("Scrolling delta: \(delta)")
            }
        }
        self.previousDidScrollTimestamp = timestamp*/
            
        //CATransaction.begin()
        //CATransaction.setDisableActions(true)
        
        let deltaY = scrollView.contentOffset.y - self.lastContentOffset.y
        
        /*if self.ignoreNextScrollAdjustment {
            self.ignoreNextScrollAdjustment = false
            self.lastContentOffset = scrollView.contentOffset
            return
        }*/
        
        //if abs(deltaY) > 30.0 {
        //    print("deltaY: \(deltaY)")
        //}
        
        self.generalAccumulatedDeltaY += deltaY
        if abs(self.generalAccumulatedDeltaY) > 14.0 {
            let direction: GeneralScrollDirection = self.generalAccumulatedDeltaY < 0 ? .up : .down
            self.generalAccumulatedDeltaY = 0.0
            if self.currentGeneralScrollDirection != direction {
                self.currentGeneralScrollDirection = direction
                self.generalScrollDirectionUpdated(direction)
            }
        }
        
        self.lastContentOffset = scrollView.contentOffset
        //print("lastContentOffset9 = \(self.lastContentOffset.y)")
        if !self.lastContentOffsetTimestamp.isZero {
            self.lastContentOffsetTimestamp = CACurrentMediaTime()
        }
        
        self.transactionOffset += -deltaY
        
        if self.isTracking {
            self.trackingOffset += -deltaY
        }
        
        if self.useMainQueueTransactions {
            DispatchQueue.main.async { [weak self] in
                self?.enqueueUpdateVisibleItems(synchronous: false)
            }
        } else {
            self.enqueueUpdateVisibleItems(synchronous: false)
        }
        
        var useScrollDynamics = false
        
        let anchor: CGFloat
        if self.isTracking {
            anchor = self.touchesPosition.y
        } else if deltaY < 0.0 {
            anchor = self.visibleSize.height
        } else {
            anchor = 0.0
        }
        
        self.didScrollWithOffset?(deltaY, .immediate, nil, self.isTrackingOrDecelerating)
        
        for itemNode in self.itemNodes {
            itemNode.updateFrame(itemNode.frame.offsetBy(dx: 0.0, dy: -deltaY), within: self.visibleSize)
            
            if self.dynamicBounceEnabled && itemNode.wantsScrollDynamics {
                useScrollDynamics = true
                
                var distance: CGFloat
                let itemFrame = itemNode.apparentFrame
                if anchor < itemFrame.origin.y {
                    distance = abs(itemFrame.origin.y - anchor)
                } else if anchor > itemFrame.origin.y + itemFrame.size.height {
                    distance = abs(anchor - (itemFrame.origin.y + itemFrame.size.height))
                } else {
                    distance = 0.0
                }
                
                let factor: CGFloat = max(0.08, abs(distance) / self.visibleSize.height)
                
                let resistance: CGFloat = testSpringFreeResistance

                itemNode.addScrollingOffset(deltaY * factor * resistance)
            }
        }
        
        if !self.snapToBounds(snapTopItem: false, stackFromBottom: self.stackFromBottom, insetDeltaOffsetFix: 0.0).offset.isZero {
            self.updateVisibleContentOffset()
        }
        self.updateScroller(transition: .immediate)
        
        self.updateItemHeaders(leftInset: self.insets.left, rightInset: self.insets.right, synchronousLoad: false)
        
        for (_, headerNode) in self.itemHeaderNodes {
            if self.dynamicBounceEnabled && headerNode.wantsScrollDynamics {
                useScrollDynamics = true
                
                var distance: CGFloat
                let itemFrame = headerNode.frame
                if anchor < itemFrame.origin.y {
                    distance = abs(itemFrame.origin.y - anchor)
                } else if anchor > itemFrame.origin.y + itemFrame.size.height {
                    distance = abs(anchor - (itemFrame.origin.y + itemFrame.size.height))
                } else {
                    distance = 0.0
                }
                
                let factor: CGFloat = max(0.08, abs(distance) / self.visibleSize.height)
                
                let resistance: CGFloat = testSpringFreeResistance
                
                headerNode.addScrollingOffset(deltaY * factor * resistance)
            }
        }
        
        if useScrollDynamics {
            self.setNeedsAnimations()
        }
        
        self.updateVisibleContentOffset()
        self.updateVisibleItemRange()
        self.updateItemNodesVisibilities(onlyPositive: false)
        self.onContentsUpdated?(.immediate)
        
        //CATransaction.commit()
    }
    
    private func calculateAdditionalTopInverseInset() -> CGFloat {
        var additionalInverseTopInset: CGFloat = 0.0
        if !self.stackFromBottomInsetItemFactor.isZero {
            var remainingFactor = self.stackFromBottomInsetItemFactor
            for itemNode in self.itemNodes {
                if remainingFactor.isLessThanOrEqualTo(0.0) {
                    break
                }
                
                let itemFactor: CGFloat
                if CGFloat(1.0).isLessThanOrEqualTo(remainingFactor) {
                    itemFactor = 1.0
                } else {
                    itemFactor = remainingFactor
                }
                
                additionalInverseTopInset += floor(itemNode.apparentBounds.height * itemFactor)
                
                remainingFactor -= 1.0
            }
        }
        return additionalInverseTopInset
    }
    
    private func areAllItemsOnScreen() -> Bool {
        if self.itemNodes.count == 0 {
            return true
        }
        
        var completeHeight: CGFloat = 0.0
        var topItemFound = false
        var bottomItemFound = false
        
        for i in 0 ..< self.itemNodes.count {
            if let index = itemNodes[i].index {
                if index == 0 {
                    topItemFound = true
                }
                break
            }
        }
        
        var effectiveInsets = self.insets
        if topItemFound && !self.stackFromBottomInsetItemFactor.isZero {
            let additionalInverseTopInset = self.calculateAdditionalTopInverseInset()
            effectiveInsets.top = max(effectiveInsets.top, self.visibleSize.height - additionalInverseTopInset)
        }
        
        for i in (0 ..< self.itemNodes.count).reversed() {
            if let index = itemNodes[i].index {
                if index == self.items.count - 1 {
                    bottomItemFound = true
                }
                break
            }
        }
        
        if topItemFound && bottomItemFound {
            for itemNode in self.itemNodes {
                completeHeight += itemNode.apparentBounds.height
            }
            
            if completeHeight <= self.visibleSize.height - self.insets.top - self.insets.bottom {
                return true
            }
        }
        
        return false
    }
    
    public var tempTopInset: CGFloat = 0.0 {
        didSet {
            if self.tempTopInset != oldValue {
                self.updateScroller(transition: .immediate)
            }
        }
    }
    
    private func getAdjustedContentHeight(effectiveInsets: UIEdgeInsets) -> CGFloat {
        if let keepMinimalScrollHeightWithTopInset = self.keepMinimalScrollHeightWithTopInset, !keepMinimalScrollHeightWithTopInset.isZero {
            return self.visibleSize.height + effectiveInsets.top + effectiveInsets.bottom// - 137.0
        } else {
            return 0.0
        }
    }
    
    private func snapToBounds(snapTopItem: Bool, stackFromBottom: Bool, updateSizeAndInsets: ListViewUpdateSizeAndInsets? = nil, scrollToItem: ListViewScrollToItem? = nil, isExperimentalSnapToScrollToItem: Bool = false, insetDeltaOffsetFix: CGFloat) -> (snappedTopInset: CGFloat, offset: CGFloat) {
        if self.itemNodes.count == 0 {
            return (0.0, 0.0)
        }
        
        var overscroll: CGFloat = 0.0
        if self.scroller.contentOffset.y < 0.0 {
            overscroll = self.scroller.contentOffset.y
        } else if self.scroller.contentOffset.y > max(0.0, self.scroller.contentSize.height - self.scroller.bounds.size.height) {
            overscroll = self.scroller.contentOffset.y - max(0.0, (self.scroller.contentSize.height - self.scroller.bounds.size.height))
        }
        
        var completeHeight: CGFloat = 0.0
        var topItemFound = false
        var bottomItemFound = false
        var topItemEdge: CGFloat = 0.0
        var bottomItemEdge: CGFloat = 0.0
        
        for i in 0 ..< self.itemNodes.count {
            if let index = self.itemNodes[i].index {
                if index == 0 {
                    topItemFound = true
                }
                break
            }
        }
        
        var effectiveInsets = self.insets
        if topItemFound && !self.stackFromBottomInsetItemFactor.isZero {
            let additionalInverseTopInset = self.calculateAdditionalTopInverseInset()
            effectiveInsets.top = max(effectiveInsets.top, self.visibleSize.height - additionalInverseTopInset)
        }
        
        if topItemFound {
            topItemEdge = self.itemNodes[0].apparentFrame.origin.y - self.tempTopInset
        }
        
        var bottomItemNode: ListViewItemNode?
        for i in (0 ..< self.itemNodes.count).reversed() {
            if let index = self.itemNodes[i].index {
                if index == self.items.count - 1 {
                    bottomItemNode = itemNodes[i]
                    bottomItemFound = true
                }
                break
            }
        }
        
        if bottomItemFound {
            bottomItemEdge = self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY
        } else {
            bottomItemEdge = self.visibleSize.height
        }
        
        if topItemFound && bottomItemFound {
            for itemNode in self.itemNodes {
                completeHeight += itemNode.apparentBounds.height
            }
        }
        
        if let keepMinimalScrollHeightWithTopInset = self.keepMinimalScrollHeightWithTopInset, topItemFound {
            if !self.stackFromBottom {
                if !keepMinimalScrollHeightWithTopInset.isZero {
                    completeHeight = max(completeHeight, self.getAdjustedContentHeight(effectiveInsets: effectiveInsets))
                }
                //completeHeight = max(completeHeight, self.visibleSize.height + keepMinimalScrollHeightWithTopInset - effectiveInsets.bottom - effectiveInsets.top)
                bottomItemEdge = max(bottomItemEdge, topItemEdge + completeHeight)
            } else {
                effectiveInsets.top = max(effectiveInsets.top, self.visibleSize.height - completeHeight)
                completeHeight = max(completeHeight, self.visibleSize.height)
                bottomItemEdge = max(bottomItemEdge, topItemEdge + completeHeight)
            }
        }
        
        var transition: ContainedViewLayoutTransition = .immediate
        if let updateSizeAndInsets = updateSizeAndInsets {
            if !updateSizeAndInsets.duration.isZero && !isExperimentalSnapToScrollToItem {
                switch updateSizeAndInsets.curve {
                    case let .Spring(duration):
                        transition = .animated(duration: duration, curve: .spring)
                    case let .Default(duration):
                        transition = .animated(duration: max(updateSizeAndInsets.duration, duration ?? 0.3), curve: .easeInOut)
                    case let .Custom(duration, cp1x, cp1y, cp2x, cp2y):
                        transition = .animated(duration: duration, curve: .custom(cp1x, cp1y, cp2x, cp2y))
                }
            }
        } else if let scrollToItem = scrollToItem {
            if scrollToItem.animated {
                switch scrollToItem.curve {
                    case let .Spring(duration):
                        transition = .animated(duration: duration, curve: .spring)
                    case let .Default(duration):
                        if let duration = duration, duration.isZero {
                            transition = .immediate
                        } else {
                            transition = .animated(duration: duration ?? 0.3, curve: .easeInOut)
                        }
                    case let .Custom(duration, cp1x, cp1y, cp2x, cp2y):
                        transition = .animated(duration: duration, curve: .custom(cp1x, cp1y, cp2x, cp2y))
                }
            }
        }
        
        var offset: CGFloat = 0.0
        if topItemFound && bottomItemFound {
            let visibleAreaHeight = self.visibleSize.height - effectiveInsets.bottom - effectiveInsets.top
            if self.stackFromBottom {
                if visibleAreaHeight > completeHeight {
                    let areaHeight = completeHeight
                    if topItemEdge < self.visibleSize.height - effectiveInsets.bottom - areaHeight - overscroll {
                        offset = self.visibleSize.height - effectiveInsets.bottom - areaHeight - overscroll - topItemEdge
                    } else if bottomItemEdge > self.visibleSize.height - effectiveInsets.bottom - overscroll {
                        offset = self.visibleSize.height - effectiveInsets.bottom - overscroll - bottomItemEdge
                    }
                } else {
                    let areaHeight = min(completeHeight, visibleAreaHeight)
                    if bottomItemEdge < effectiveInsets.top + areaHeight - overscroll {
                        offset = effectiveInsets.top + areaHeight - overscroll - bottomItemEdge
                    } else if topItemEdge > effectiveInsets.top - overscroll {
                        offset = (effectiveInsets.top - overscroll) - topItemEdge
                    }
                }
            } else if !self.isTracking {
                let areaHeight = min(completeHeight, visibleAreaHeight)
                if bottomItemEdge < effectiveInsets.top + areaHeight - overscroll {
                    if snapTopItem && topItemEdge < effectiveInsets.top {
                        offset = (effectiveInsets.top - overscroll) - topItemEdge
                    } else {
                        offset = effectiveInsets.top + areaHeight - overscroll - bottomItemEdge
                    }
                } else if topItemEdge > effectiveInsets.top - overscroll {
                    offset = (effectiveInsets.top - overscroll) - topItemEdge
                }
            }
            
            if visibleAreaHeight > completeHeight {
                if let itemNode = bottomItemNode, itemNode.wantsTrailingItemSpaceUpdates {
                    itemNode.updateTrailingItemSpace(visibleAreaHeight - completeHeight, transition: transition)
                }
            } else {
                if let itemNode = bottomItemNode, itemNode.wantsTrailingItemSpaceUpdates {
                    itemNode.updateTrailingItemSpace(0.0, transition: transition)
                }
            }
        } else {
            if let itemNode = bottomItemNode, itemNode.wantsTrailingItemSpaceUpdates {
                itemNode.updateTrailingItemSpace(0.0, transition: transition)
            }
            if topItemFound {
                if topItemEdge > effectiveInsets.top - overscroll && /*snapTopItem*/ true {
                    offset = (effectiveInsets.top - overscroll) - topItemEdge
                }
            } else if bottomItemFound {
                if bottomItemEdge < self.visibleSize.height - effectiveInsets.bottom - overscroll {
                    offset = self.visibleSize.height - effectiveInsets.bottom - overscroll - bottomItemEdge
                }
            }
        }
        
        if abs(offset) > CGFloat.ulpOfOne {
            self.didScrollWithOffset?(-offset, .immediate, nil, self.isTrackingOrDecelerating)
            
            for itemNode in self.itemNodes {
                var frame = itemNode.frame
                frame.origin.y += offset
                itemNode.updateFrame(frame, within: self.visibleSize)
                if let accessoryItemNode = itemNode.accessoryItemNode {
                    itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: self.insets.left, rightInset: self.insets.right)
                }
            }
        }
        
        var snappedTopInset: CGFloat = 0.0
        if !self.stackFromBottomInsetItemFactor.isZero && topItemFound {
            snappedTopInset = max(0.0, (effectiveInsets.top - self.insets.top) - (topItemEdge + offset))
        }
        
        return (snappedTopInset, offset)
    }
    
    public func visibleContentOffset() -> ListViewVisibleContentOffset {
        var offset: ListViewVisibleContentOffset = .unknown
        var topItemIndexAndMinY: (Int, CGFloat) = (-1, 0.0)
        
        var currentMinY: CGFloat?
        for itemNode in self.itemNodes {
            if let index = itemNode.index {
                let updatedMinY: CGFloat
                if let currentMinY = currentMinY {
                    if itemNode.apparentFrame.minY < currentMinY {
                        updatedMinY = itemNode.apparentFrame.minY
                    } else {
                        updatedMinY = currentMinY
                    }
                } else {
                    updatedMinY = itemNode.apparentFrame.minY
                }
                topItemIndexAndMinY = (index, updatedMinY)
                break
            } else if currentMinY == nil {
                currentMinY = itemNode.apparentFrame.minY
            }
        }
        if topItemIndexAndMinY.0 == 0 {
            let offsetValue: CGFloat = -(topItemIndexAndMinY.1 - self.insets.top)
            offset = .known(offsetValue)
        } else if topItemIndexAndMinY.0 == -1 {
            offset = .none
        }
        return offset
    }
    
    public func visibleBottomContentOffset() -> ListViewVisibleContentOffset {
        var offset: ListViewVisibleContentOffset = .unknown
        var bottomItemIndexAndFrame: (Int, CGRect) = (-1, CGRect())
        for itemNode in self.itemNodes.reversed() {
            if let index = itemNode.index {
                bottomItemIndexAndFrame = (index, itemNode.apparentFrame)
                break
            }
        }
        if bottomItemIndexAndFrame.0 == self.items.count - 1 {
            offset = .known(bottomItemIndexAndFrame.1.maxY - (self.visibleSize.height - self.insets.bottom))
        } else if bottomItemIndexAndFrame.0 == -1 {
            offset = .none
        }
        return offset
    }
    
    private func updateVisibleContentOffset() {
        self.visibleContentOffsetChanged(self.visibleContentOffset())
        self.visibleBottomContentOffsetChanged(self.visibleBottomContentOffset())
    }
    
    public func stopScrolling() {
        let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
        self.ignoreScrollingEvents = true
        self.scroller.setContentOffset(self.scroller.contentOffset, animated: false)
        self.ignoreScrollingEvents = wasIgnoringScrollingEvents
    }
    
    public func cancelTracking() {
        self.scroller.panGestureRecognizer.isEnabled = false
        self.scroller.panGestureRecognizer.isEnabled = true
    }
    
    private func updateTopItemOverscrollBackground(transition: ContainedViewLayoutTransition) {
        if let value = self.keepTopItemOverscrollBackground {
            var applyTransition = transition
            
            let topItemOverscrollBackground: ListViewOverscrollBackgroundNode
            if let current = self.topItemOverscrollBackground {
                topItemOverscrollBackground = current
            } else {
                applyTransition = .immediate
                topItemOverscrollBackground = ListViewOverscrollBackgroundNode(color: value.color)
                topItemOverscrollBackground.isLayerBacked = true
                self.topItemOverscrollBackground = topItemOverscrollBackground
                if let extractedBackgroundsContainerNode = self.extractedBackgroundsContainerNode {
                    self.insertSubnode(topItemOverscrollBackground, aboveSubnode: extractedBackgroundsContainerNode)
                } else {
                    self.insertSubnode(topItemOverscrollBackground, at: 0)
                }
            }
            var topItemFound = false
            var topItemNodeIndex: Int?
            if !self.itemNodes.isEmpty {
                topItemNodeIndex = self.itemNodes[0].index
            }
            if topItemNodeIndex == 0 {
                topItemFound = true
            }
            
            var backgroundFrame: CGRect
            
            if topItemFound {
                let realTopItemEdge = itemNodes.first!.apparentFrame.origin.y
                let realTopItemEdgeOffset = max(0.0, realTopItemEdge)
                backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: self.visibleSize.width, height: realTopItemEdgeOffset))
                if value.direction {
                    backgroundFrame.origin.y = 0.0
                    backgroundFrame.size.height = realTopItemEdgeOffset
                } else {
                    backgroundFrame.origin.y = min(self.insets.top, realTopItemEdgeOffset)
                    backgroundFrame.size.height = max(0.0, self.visibleSize.height - backgroundFrame.origin.y) + 400.0
                }
            } else {
                backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: self.visibleSize.width, height: 0.0))
                if value.direction {
                    backgroundFrame.origin.y = 0.0
                } else {
                    backgroundFrame.origin.y = 0.0
                    backgroundFrame.size.height = self.visibleSize.height
                }
            }
            
            let previousFrame = topItemOverscrollBackground.frame
            if !previousFrame.equalTo(backgroundFrame) {
                topItemOverscrollBackground.frame = backgroundFrame
                
                let positionDelta = CGPoint(x: backgroundFrame.minX - previousFrame.minX, y: backgroundFrame.minY - previousFrame.minY)
                
                applyTransition.animateOffsetAdditive(node: topItemOverscrollBackground, offset: positionDelta.y)
            }
            
            topItemOverscrollBackground.updateLayout(size: backgroundFrame.size, transition: applyTransition)
        } else if let topItemOverscrollBackground = self.topItemOverscrollBackground {
            self.topItemOverscrollBackground = nil
            topItemOverscrollBackground.removeFromSupernode()
        }
    }
    
    private func updateFloatingHeaderNode(transition: ContainedViewLayoutTransition) {
        guard let updateFloatingHeaderOffset = self.updateFloatingHeaderOffset else {
            return
        }
        
        var topItemFound = false
        var topItemNodeIndex: Int?
        if !self.itemNodes.isEmpty {
            topItemNodeIndex = self.itemNodes[0].index
        }
        if topItemNodeIndex == 0 {
            topItemFound = true
        }
        
        if !topItemFound, self.stackFromBottom && !self.autoScrollWhenReordering, let itemNode = self.itemNodes.first, itemNode.apparentFrame.minY > 0.0 {
            topItemFound = true
        }
        
        var topOffset: CGFloat
        
        if topItemFound {
            let realTopItemEdge = self.itemNodes.first!.apparentFrame.origin.y
            let realTopItemEdgeOffset = max(0.0, realTopItemEdge)

            topOffset = realTopItemEdgeOffset
        } else {
            if !self.itemNodes.isEmpty {
                if self.stackFromBottom {
                    topOffset = 0.0
                } else {
                    topOffset = 0.0
                }
            } else {
                if self.stackFromBottom {
                    topOffset = self.visibleSize.height
                } else {
                    topOffset = self.insets.top
                }
            }
        }
        
        updateFloatingHeaderOffset(topOffset, transition)
    }
    
    private func updateBottomItemOverscrollBackground() {
        if let color = self.keepBottomItemOverscrollBackground {
            var bottomItemFound = false
            var lastItemNodeIndex: Int?
            if !itemNodes.isEmpty {
                lastItemNodeIndex = self.itemNodes[itemNodes.count - 1].index
            }
            if lastItemNodeIndex == self.items.count - 1 {
                bottomItemFound = true
            }
            
            let bottomItemOverscrollBackground: ASDisplayNode
            if let currentBottomItemOverscrollBackground = self.bottomItemOverscrollBackground {
                bottomItemOverscrollBackground = currentBottomItemOverscrollBackground
            } else {
                bottomItemOverscrollBackground = ASDisplayNode()
                bottomItemOverscrollBackground.backgroundColor = color
                bottomItemOverscrollBackground.isLayerBacked = true
                if let extractedBackgroundsContainerNode = self.extractedBackgroundsContainerNode {
                    self.insertSubnode(bottomItemOverscrollBackground, aboveSubnode: extractedBackgroundsContainerNode)
                } else {
                    self.insertSubnode(bottomItemOverscrollBackground, at: 0)
                }
                self.bottomItemOverscrollBackground = bottomItemOverscrollBackground
            }
            
            if bottomItemFound {
                let realBottomItemEdge = itemNodes.last!.apparentFrame.origin.y
                let realBottomItemEdgeOffset = max(0.0, self.visibleSize.height - realBottomItemEdge)
                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: self.visibleSize.height - realBottomItemEdgeOffset), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height))
                if !backgroundFrame.equalTo(bottomItemOverscrollBackground.frame) {
                    bottomItemOverscrollBackground.frame = backgroundFrame
                }
            } else {
                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: self.visibleSize.height), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height))
                if !backgroundFrame.equalTo(bottomItemOverscrollBackground.frame) {
                    bottomItemOverscrollBackground.frame = backgroundFrame
                }
            }
        } else if let bottomItemOverscrollBackground = self.bottomItemOverscrollBackground {
            self.bottomItemOverscrollBackground = nil
            bottomItemOverscrollBackground.removeFromSupernode()
        }
    }
    
    private func updateOverlayHighlight(transition: ContainedViewLayoutTransition) {
        var lowestOverlayNode: ListViewItemNode?
        
        for itemNode in self.itemNodes {
            if itemNode.isHighlightedInOverlay {
                lowestOverlayNode = itemNode
                itemNode.view.superview?.bringSubviewToFront(itemNode.view)
                if let verticalScrollIndicator = self.verticalScrollIndicator {
                    verticalScrollIndicator.view.superview?.bringSubviewToFront(verticalScrollIndicator.view)
                }
            }
        }
        
        if let lowestOverlayNode = lowestOverlayNode {
            let itemHighlightOverlayBackground: ASDisplayNode
            if let current = self.itemHighlightOverlayBackground {
                itemHighlightOverlayBackground = current
            } else {
                itemHighlightOverlayBackground = ASDisplayNode()
                itemHighlightOverlayBackground.frame = CGRect(origin: CGPoint(x: 0.0, y: -self.visibleSize.height), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height * 3.0))
                itemHighlightOverlayBackground.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
                self.itemHighlightOverlayBackground = itemHighlightOverlayBackground
                self.insertSubnode(itemHighlightOverlayBackground, belowSubnode: lowestOverlayNode)
                itemHighlightOverlayBackground.alpha = 0.0
                transition.updateAlpha(node: itemHighlightOverlayBackground, alpha: 1.0)
            }
        } else if let itemHighlightOverlayBackground = self.itemHighlightOverlayBackground {
            self.itemHighlightOverlayBackground = nil
            transition.updateAlpha(node: itemHighlightOverlayBackground, alpha: 0.0, completion: { [weak itemHighlightOverlayBackground] _ in
                itemHighlightOverlayBackground?.removeFromSupernode()
            })
            if let verticalScrollIndicator = self.verticalScrollIndicator {
                verticalScrollIndicator.view.superview?.bringSubviewToFront(verticalScrollIndicator.view)
            }
        }
    }
    
    private func updateScroller(transition: ContainedViewLayoutTransition) {
        self.updateOverlayHighlight(transition: transition)
        
        var topItemFound: Bool = false
        var bottomItemFound: Bool = false
        var topItemEdge: CGFloat = 0.0
        var bottomItemEdge: CGFloat = 0.0
        var completeHeight: CGFloat = 0.0
        
        if !self.itemNodes.isEmpty {
            for i in 0 ..< self.itemNodes.count {
                if let index = self.itemNodes[i].index {
                    if index == 0 {
                        topItemFound = true
                        topItemEdge = self.itemNodes[0].apparentFrame.origin.y
                        break
                    }
                }
            }
            
            var effectiveInsets = self.insets
            if topItemFound && !self.stackFromBottomInsetItemFactor.isZero {
                let additionalInverseTopInset = self.calculateAdditionalTopInverseInset()
                effectiveInsets.top = max(effectiveInsets.top, self.visibleSize.height - additionalInverseTopInset)
            }
            
            completeHeight = effectiveInsets.top + effectiveInsets.bottom
            
            if let index = self.itemNodes[self.itemNodes.count - 1].index, index == self.items.count - 1 {
                bottomItemFound = true
                bottomItemEdge = self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY
            }
            
            topItemEdge -= effectiveInsets.top
            bottomItemEdge += effectiveInsets.bottom
            
            if topItemFound && bottomItemFound {
                for itemNode in self.itemNodes {
                    completeHeight += itemNode.apparentBounds.height
                }
                
                if let keepMinimalScrollHeightWithTopInset = self.keepMinimalScrollHeightWithTopInset {
                    if !self.stackFromBottom {
                        if !keepMinimalScrollHeightWithTopInset.isZero {
                            completeHeight = max(completeHeight, self.getAdjustedContentHeight(effectiveInsets: effectiveInsets))
                        }
                        //completeHeight = max(completeHeight, self.visibleSize.height + keepMinimalScrollHeightWithTopInset)
                        bottomItemEdge = max(bottomItemEdge, topItemEdge + completeHeight)
                    }
                }
                
                if self.stackFromBottom {
                    let previousCompleteHeight = completeHeight
                    let updatedCompleteHeight = max(completeHeight, self.visibleSize.height)
                    let deltaCompleteHeight = updatedCompleteHeight - completeHeight
                    topItemEdge -= deltaCompleteHeight
                    bottomItemEdge -= deltaCompleteHeight
                    completeHeight = updatedCompleteHeight
                    
                    if let _ = self.keepMinimalScrollHeightWithTopInset {
                        completeHeight += effectiveInsets.top + previousCompleteHeight
                    }
                }
            }
        }
        
        self.updateTopItemOverscrollBackground(transition: transition)
        self.updateBottomItemOverscrollBackground()
        self.updateFloatingHeaderNode(transition: transition)
        
        let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
        self.ignoreScrollingEvents = true
        if topItemFound && bottomItemFound {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: completeHeight)
            self.lastContentOffset = CGPoint(x: 0.0, y: -topItemEdge + self.tempTopInset)
            //print("lastContentOffset1 = \(self.lastContentOffset.y)")
            self.scroller.contentOffset = self.lastContentOffset
        } else if topItemFound {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            self.lastContentOffset = CGPoint(x: 0.0, y: -topItemEdge + self.tempTopInset)
            //print("lastContentOffset2 = \(self.lastContentOffset.y), ignoreNextScrollAdjustment: \(self.ignoreNextScrollAdjustment)")
            if self.scroller.contentOffset != self.lastContentOffset {
                self.scroller.contentOffset = self.lastContentOffset
            }
            self.lastContentOffset = self.scroller.contentOffset
            //print("lastContentOffset2.1 = \(self.lastContentOffset.y), ignoreNextScrollAdjustment: \(self.ignoreNextScrollAdjustment)")
        } else if bottomItemFound {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize * 2.0 - bottomItemEdge)
            //print("lastContentOffset3 = \(self.lastContentOffset.y)")
            self.scroller.contentOffset = self.lastContentOffset
        } else if self.itemNodes.isEmpty {
            self.scroller.contentSize = self.visibleSize
            if self.lastContentOffset.y == infiniteScrollSize && self.scroller.contentOffset.y.isZero {
                self.scroller.contentOffset = .zero
                self.lastContentOffset = .zero
                //print("lastContentOffset4 = \(self.lastContentOffset.y)")
            }
        } else {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            if abs(self.scroller.contentOffset.y - infiniteScrollSize) > infiniteScrollSize / 2.0 {
                self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
                //print("lastContentOffset5 = \(self.lastContentOffset.y)")
                self.scroller.contentOffset = self.lastContentOffset
            } else {
                self.lastContentOffset = self.scroller.contentOffset
                //print("lastContentOffset6 = \(self.lastContentOffset.y)")
            }
        }
        self.ignoreScrollingEvents = wasIgnoringScrollingEvents
    }
    
    private func async(_ f: @escaping () -> Void) {
        if self.useMainQueueTransactions {
            if Thread.isMainThread {
                f()
            } else {
                DispatchQueue.main.async(execute: f)
            }
        } else {
            DispatchQueue.global(qos: .userInteractive).async(execute: f)
        }
    }
    
    private func nodeForItem(synchronous: Bool, synchronousLoads: Bool, item: ListViewItem, previousNode: QueueLocalObject<ListViewItemNode>?, index: Int, previousItem: ListViewItem?, nextItem: ListViewItem?, params: ListViewItemLayoutParams, updateAnimationIsAnimated: Bool, updateAnimationIsCrossfade: Bool, customAnimationTransition: ControlledTransition?, completion: @escaping (QueueLocalObject<ListViewItemNode>, ListViewItemNodeLayout, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        if let previousNode = previousNode {
            var controlledTransition: ControlledTransition?
            let updateAnimation: ListViewItemUpdateAnimation
            if let customAnimationTransition {
                controlledTransition = customAnimationTransition
                var duration: Double = insertionAnimationDuration
                switch customAnimationTransition.legacyAnimator.transition {
                case .immediate:
                    duration = 0.0
                case let .animated(durationValue, _):
                    duration = durationValue
                }
                updateAnimation = .System(duration: duration * UIView.animationDurationFactor(), transition: customAnimationTransition)
            } else {
                if updateAnimationIsCrossfade {
                    updateAnimation = .Crossfade
                } else if updateAnimationIsAnimated {
                    let transition = ControlledTransition(duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: .spring, interactive: true)
                    controlledTransition = transition
                    updateAnimation = .System(duration: insertionAnimationDuration * UIView.animationDurationFactor(), transition: transition)
                } else {
                    updateAnimation = .None
                }
            }
            
            if let controlledTransition = controlledTransition {
                previousNode.syncWith({ $0 }).addPendingControlledTransition(transition: controlledTransition)
            }
            
            item.updateNode(async: { f in
                if synchronous {
                    f()
                } else {
                    self.async(f)
                }
            }, node: {
                assert(Queue.mainQueue().isCurrent())
                return previousNode.syncWith({ $0 })
            }, params: params, previousItem: previousItem, nextItem: nextItem, animation: updateAnimation, completion: { (layout, apply) in
                if Thread.isMainThread {
                    if synchronous {
                        completion(previousNode, layout, {
                            return (nil, { info in
                                assert(Queue.mainQueue().isCurrent())
                                previousNode.with({ $0.index = index })
                                apply(info)
                            })
                        })
                    } else {
                        self.async {
                            completion(previousNode, layout, {
                                return (nil, { info in
                                    assert(Queue.mainQueue().isCurrent())
                                    previousNode.with({ $0.index = index })
                                    apply(info)
                                })
                            })
                        }
                    }
                } else {
                    completion(previousNode, layout, {
                        return (nil, { info in
                            assert(Queue.mainQueue().isCurrent())
                            previousNode.with({ $0.index = index })
                            apply(info)
                        })
                    })
                }
            })
        } else {
            item.nodeConfiguredForParams(async: { f in
                if synchronous {
                    f()
                } else {
                    self.async(f)
                }
            }, params: params, synchronousLoads: synchronousLoads, previousItem: previousItem, nextItem: nextItem, completion: { itemNode, apply in
                itemNode.index = index
                completion(QueueLocalObject(queue: Queue.mainQueue(), generate: { return itemNode }), ListViewItemNodeLayout(contentSize: itemNode.contentSize, insets: itemNode.insets), apply)
            })
        }
    }
    
    private func currentState() -> ListViewState {
        var nodes: [ListViewStateNode] = []
        nodes.reserveCapacity(self.itemNodes.count)
        for node in self.itemNodes {
            if let index = node.index {
                nodes.append(.Node(index: index, frame: node.apparentFrame, referenceNode: QueueLocalObject(queue: Queue.mainQueue(), generate: {
                    return node
                }), newNode: nil))
            } else {
                nodes.append(.Placeholder(frame: node.apparentFrame))
            }
        }
        return ListViewState(insets: self.insets, itemOffsetInsets: self.itemOffsetInsets ?? self.insets, visibleSize: self.visibleSize, invisibleInset: self.effectiveInvisibleInset, nodes: nodes, scrollPosition: nil, stationaryOffset: nil, stackFromBottom: self.stackFromBottom)
    }
    
    public func addAfterTransactionsCompleted(_ f: @escaping () -> Void) {
        self.transactionQueue.addTransaction({ transactionCompletion in
            f()
            transactionCompletion()
        })
    }
    
    public func transaction(deleteIndices: [ListViewDeleteItem], insertIndicesAndItems: [ListViewInsertItem], updateIndicesAndItems: [ListViewUpdateItem], options: ListViewDeleteAndInsertOptions, scrollToItem: ListViewScrollToItem? = nil, additionalScrollDistance: CGFloat = 0.0, updateSizeAndInsets: ListViewUpdateSizeAndInsets? = nil, stationaryItemRange: (Int, Int)? = nil, updateOpaqueState: Any?, completion: @escaping (ListViewDisplayedItemRange) -> Void = { _ in }) {
        if deleteIndices.isEmpty && insertIndicesAndItems.isEmpty && updateIndicesAndItems.isEmpty && scrollToItem == nil && updateSizeAndInsets == nil && additionalScrollDistance.isZero {
            if let updateOpaqueState = updateOpaqueState {
                self.opaqueTransactionState = updateOpaqueState
            }
            completion(self.immediateDisplayedItemRange())
            return
        }
        
        self.transactionQueue.addTransaction({ [weak self] transactionCompletion in
            if let strongSelf = self {
                strongSelf.transactionOffset = 0.0
                strongSelf.deleteAndInsertItemsTransaction(deleteIndices: deleteIndices, insertIndicesAndItems: insertIndicesAndItems, updateIndicesAndItems: updateIndicesAndItems, options: options, scrollToItem: scrollToItem, additionalScrollDistance: additionalScrollDistance, updateSizeAndInsets: updateSizeAndInsets, stationaryItemRange: stationaryItemRange, updateOpaqueState: updateOpaqueState, customAnimationTransition: updateSizeAndInsets?.customAnimationTransition, completion: { [weak strongSelf] in
                    completion(strongSelf?.immediateDisplayedItemRange() ?? ListViewDisplayedItemRange(loadedRange: nil, visibleRange: nil))
                    
                    transactionCompletion()
                })
            }
        })
    }

    private func deleteAndInsertItemsTransaction(deleteIndices: [ListViewDeleteItem], insertIndicesAndItems: [ListViewInsertItem], updateIndicesAndItems: [ListViewUpdateItem], options: ListViewDeleteAndInsertOptions, scrollToItem: ListViewScrollToItem?, additionalScrollDistance: CGFloat, updateSizeAndInsets: ListViewUpdateSizeAndInsets?, stationaryItemRange: (Int, Int)?, updateOpaqueState: Any?, customAnimationTransition: ControlledTransition?, completion: @escaping () -> Void) {
        if deleteIndices.isEmpty && insertIndicesAndItems.isEmpty && updateIndicesAndItems.isEmpty && scrollToItem == nil {
            if let updateSizeAndInsets = updateSizeAndInsets, (self.items.count == 0 || (updateSizeAndInsets.size == self.visibleSize && updateSizeAndInsets.insets == self.insets && !options.contains(.ForceUpdate))) {
                self.visibleSize = updateSizeAndInsets.size
                self.insets = updateSizeAndInsets.insets
                self.headerInsets = updateSizeAndInsets.headerInsets ?? self.insets
                self.scrollIndicatorInsets = updateSizeAndInsets.scrollIndicatorInsets ?? self.insets
                self.itemOffsetInsets = updateSizeAndInsets.itemOffsetInsets
                self.ensureTopInsetForOverlayHighlightedItems = updateSizeAndInsets.ensureTopInsetForOverlayHighlightedItems
                
                let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
                self.ignoreScrollingEvents = true
                self.scroller.frame = CGRect(origin: CGPoint(), size: updateSizeAndInsets.size)
                //self.scroller.contentSize = CGSize(width: updateSizeAndInsets.size.width, height: infiniteScrollSize * 2.0)
                //self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
                //print("lastContentOffset7 = \(self.lastContentOffset.y)")
                //self.scroller.contentOffset = self.lastContentOffset
                self.ignoreScrollingEvents = wasIgnoringScrollingEvents
                
                self.updateScroller(transition: .immediate)
                
                if let updateOpaqueState = updateOpaqueState {
                    self.opaqueTransactionState = updateOpaqueState
                }
                
                completion()
                return
            }
        }
        
        if !deleteIndices.isEmpty || !insertIndicesAndItems.isEmpty || !updateIndicesAndItems.isEmpty {
            self.scrolledToItem = nil
        }
        
        let startTime = CACurrentMediaTime()
        var state = self.currentState()
        
        let widthUpdated: Bool
        if let updateSizeAndInsets = updateSizeAndInsets {
            widthUpdated = abs(state.visibleSize.width - updateSizeAndInsets.size.width) > CGFloat.ulpOfOne || abs(state.insets.left - updateSizeAndInsets.insets.left) > CGFloat.ulpOfOne || abs(state.insets.right - updateSizeAndInsets.insets.right) > CGFloat.ulpOfOne || options.contains(.ForceUpdate)
            
            state.visibleSize = updateSizeAndInsets.size
            state.insets = updateSizeAndInsets.insets
        } else {
            widthUpdated = false
        }
        
        let sortedDeleteIndices = deleteIndices.sorted(by: {$0.index < $1.index})
        for deleteItem in sortedDeleteIndices.reversed() {
            self.items.remove(at: deleteItem.index)
        }
        
        let sortedIndicesAndItems = insertIndicesAndItems.sorted(by: { $0.index < $1.index })
        if self.items.count == 0 && !sortedIndicesAndItems.isEmpty {
            if sortedIndicesAndItems[0].index != 0 {
                fatalError("deleteAndInsertItems: invalid insert into empty list")
            }
        }
        
        var previousNodes: [Int: QueueLocalObject<ListViewItemNode>] = [:]
        for insertedItem in sortedIndicesAndItems {
            if insertedItem.index < 0 || insertedItem.index > self.items.count {
                fatalError("insertedItem.index \(insertedItem.index) is out of bounds 0 ... \(self.items.count)")
            }
            self.items.insert(insertedItem.item, at: insertedItem.index)
            if let previousIndex = insertedItem.previousIndex {
                for itemNode in self.itemNodes {
                    if itemNode.index == previousIndex {
                        previousNodes[insertedItem.index] = QueueLocalObject(queue: Queue.mainQueue(), generate: { return itemNode })
                    }
                }
            }
        }
        
        for updatedItem in updateIndicesAndItems {
            self.items[updatedItem.index] = updatedItem.item
            for itemNode in self.itemNodes {
                if itemNode.index == updatedItem.previousIndex {
                    previousNodes[updatedItem.index] = QueueLocalObject(queue: Queue.mainQueue(), generate: { return itemNode })
                    break
                }
            }
        }
        
        if let scrollToItem = scrollToItem {
            state.scrollPosition = (scrollToItem.index, scrollToItem.position)
        }
        let itemsCount = self.items.count
        state.fixScrollPosition(itemsCount)
        
        let actions = {
            var previousFrames: [Int: CGRect] = [:]
            for i in 0 ..< state.nodes.count {
                if let index = state.nodes[i].index {
                    previousFrames[index] = state.nodes[i].frame
                }
            }
            
            var operations: [ListViewStateOperation] = []
            
            var deleteDirectionHints: [Int: ListViewItemOperationDirectionHint] = [:]
            var insertDirectionHints: [Int: ListViewItemOperationDirectionHint] = [:]
            
            var deleteIndexSet = Set<Int>()
            for deleteItem in deleteIndices {
                deleteIndexSet.insert(deleteItem.index)
                if let directionHint = deleteItem.directionHint {
                    deleteDirectionHints[deleteItem.index] = directionHint
                }
            }
            
            var insertedIndexSet = Set<Int>()
            for insertedItem in sortedIndicesAndItems {
                insertedIndexSet.insert(insertedItem.index)
                if let directionHint = insertedItem.directionHint {
                    insertDirectionHints[insertedItem.index] = directionHint
                }
            }
            
            let animated = options.contains(.AnimateInsertion)
            
            var remapDeletion: [Int: Int] = [:]
            var updateAdjacentItemsIndices = Set<Int>()
            
            var i = 0
            while i < state.nodes.count {
                if let index = state.nodes[i].index {
                    var indexOffset = 0
                    for deleteIndex in sortedDeleteIndices {
                        if deleteIndex.index < index {
                            indexOffset += 1
                        } else {
                            break
                        }
                    }
                    
                    if deleteIndexSet.contains(index) {
                        previousFrames.removeValue(forKey: index)
                        state.removeNodeAtIndex(i, direction: deleteDirectionHints[index], animated: animated, operations: &operations)
                    } else {
                        let updatedIndex = index - indexOffset
                        if index != updatedIndex {
                            remapDeletion[index] = updatedIndex
                        }
                        if let previousFrame = previousFrames[index] {
                            previousFrames.removeValue(forKey: index)
                            previousFrames[updatedIndex] = previousFrame
                        }
                        if deleteIndexSet.contains(index - 1) || deleteIndexSet.contains(index + 1) {
                            updateAdjacentItemsIndices.insert(updatedIndex)
                        }
                        
                        switch state.nodes[i] {
                        case let .Node(_, frame, referenceNode, newNode):
                            state.nodes[i] = .Node(index: updatedIndex, frame: frame, referenceNode: referenceNode, newNode: newNode)
                        case .Placeholder:
                            break
                        }
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
            
            if !remapDeletion.isEmpty {
                if self.debugInfo {
                    //print("remapDeletion \(remapDeletion)")
                }
                operations.append(.Remap(remapDeletion))
            }
            
            var remapInsertion: [Int: Int] = [:]
            
            for i in 0 ..< state.nodes.count {
                if let index = state.nodes[i].index {
                    var indexOffset = 0
                    for insertedItem in sortedIndicesAndItems {
                        if insertedItem.index <= index + indexOffset {
                            indexOffset += 1
                        }
                    }
                    if indexOffset != 0 {
                        let updatedIndex = index + indexOffset
                        remapInsertion[index] = updatedIndex
                        
                        if let previousFrame = previousFrames[index] {
                            previousFrames.removeValue(forKey: index)
                            previousFrames[updatedIndex] = previousFrame
                        }
                        
                        switch state.nodes[i] {
                        case let .Node(_, frame, referenceNode, newNode):
                            state.nodes[i] = .Node(index: updatedIndex, frame: frame, referenceNode: referenceNode, newNode: newNode)
                        case .Placeholder:
                            break
                        }
                    }
                }
            }
            
            if !remapInsertion.isEmpty {
                if self.debugInfo {
                    print("remapInsertion \(remapInsertion)")
                }
                operations.append(.Remap(remapInsertion))
                
                var remappedUpdateAdjacentItemsIndices = Set<Int>()
                for index in updateAdjacentItemsIndices {
                    if let remappedIndex = remapInsertion[index] {
                        remappedUpdateAdjacentItemsIndices.insert(remappedIndex)
                    } else {
                        remappedUpdateAdjacentItemsIndices.insert(index)
                    }
                }
                updateAdjacentItemsIndices = remappedUpdateAdjacentItemsIndices
            }
            
            if self.debugInfo {
                //print("state \(state.nodes.map({$0.index ?? -1}))")
            }
            
            for node in state.nodes {
                if let index = node.index {
                    if insertedIndexSet.contains(index - 1) || insertedIndexSet.contains(index + 1) {
                        updateAdjacentItemsIndices.insert(index)
                    }
                }
            }
            
            if let (index, boundary) = stationaryItemRange {
                state.setupStationaryOffset(index, boundary: boundary, frames: previousFrames)
            }
            
            if let _ = scrollToItem {
                state.fixScrollPosition(itemsCount)
            }
            
            if self.debugInfo {
                print("deleteAndInsertItemsTransaction prepare \((CACurrentMediaTime() - startTime) * 1000.0) ms")
            }
            
            self.fillMissingNodes(synchronous: options.contains(.Synchronous), synchronousLoads: options.contains(.PreferSynchronousResourceLoading), animated: animated, customAnimationTransition: updateSizeAndInsets?.customAnimationTransition, inputAnimatedInsertIndices: animated ? insertedIndexSet : Set<Int>(), insertDirectionHints: insertDirectionHints, inputState: state, inputPreviousNodes: previousNodes, inputOperations: operations, inputCompletion: { updatedState, operations in
                
                if self.debugInfo {
                    print("fillMissingNodes completion \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                }
                
                var updateIndices = updateAdjacentItemsIndices
                if widthUpdated {
                    for case let .Node(index, _, _, _) in updatedState.nodes {
                        updateIndices.insert(index)
                    }
                }
                
                /*if !insertedIndexSet.intersection(updateIndices).isEmpty {
                    print("int")
                }*/
                let explicitelyUpdateIndices = Set(updateIndicesAndItems.map({$0.index}))
                /*if !explicitelyUpdateIndices.intersection(updateIndices).isEmpty {
                    print("int")
                }*/
                
                updateIndices.subtract(explicitelyUpdateIndices)
                
                self.updateNodes(synchronous: options.contains(.Synchronous), synchronousLoads: options.contains(.PreferSynchronousResourceLoading), crossfade: options.contains(.AnimateCrossfade), customAnimationTransition: customAnimationTransition, animated: animated, updateIndicesAndItems: updateIndicesAndItems, inputState: updatedState, previousNodes: previousNodes, inputOperations: operations, completion: { updatedState, operations in
                    self.updateAdjacent(synchronous: options.contains(.Synchronous), animated: animated, customAnimationTransition: customAnimationTransition, state: updatedState, updateAdjacentItemsIndices: updateIndices, operations: operations, completion: { state, operations in
                        var updatedState = state
                        var updatedOperations = operations
                        updatedState.removeInvisibleNodes(&updatedOperations)
                        
                        if self.debugInfo {
                            print("updateAdjacent completion \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                        }
                        
                        let stationaryItemIndex = updatedState.stationaryOffset?.0
                        
                        let next = {
                            var updatedOperations = updatedOperations
                            
                            var readySignals: [Signal<Void, NoError>]?
                            
                            if options.contains(.PreferSynchronousResourceLoading) {
                                var currentReadySignals: [Signal<Void, NoError>] = []
                                for i in 0 ..< updatedOperations.count {
                                    if case let .InsertNode(index, offsetDirection, nodeAnimated, node, layout, apply) = updatedOperations[i] {
                                        let (ready, commitApply) = apply()
                                        updatedOperations[i] = .InsertNode(index: index, offsetDirection: offsetDirection, animated: nodeAnimated, node: node, layout: layout, apply: {
                                            return (nil, commitApply)
                                        })
                                        if let ready = ready {
                                            currentReadySignals.append(ready)
                                        }
                                    }
                                }
                                readySignals = currentReadySignals
                            }
                            
                            let beginReplay = { [weak self] in
                                if let strongSelf = self {
                                    strongSelf.replayOperations(animated: animated, animateAlpha: options.contains(.AnimateAlpha), animateCrossfade: options.contains(.AnimateCrossfade), animateFullTransition: options.contains(.AnimateFullTransition), customAnimationTransition: updateSizeAndInsets?.customAnimationTransition, synchronous: options.contains(.Synchronous), synchronousLoads: options.contains(.PreferSynchronousResourceLoading), animateTopItemVerticalOrigin: options.contains(.AnimateTopItemPosition), operations: updatedOperations, requestItemInsertionAnimationsIndices: options.contains(.RequestItemInsertionAnimations) ? insertedIndexSet : Set(), scrollToItem: scrollToItem, additionalScrollDistance: additionalScrollDistance, updateSizeAndInsets: updateSizeAndInsets, stationaryItemIndex: stationaryItemIndex, updateOpaqueState: updateOpaqueState, forceInvertOffsetDirection: options.contains(.InvertOffsetDirection), completion: {
                                        if options.contains(.PreferSynchronousDrawing) {
                                            self?.recursivelyEnsureDisplaySynchronously(true)
                                        }
                                        completion()
                                    })
                                }
                            }
                            
                            if let readySignals = readySignals, !readySignals.isEmpty && false {
                                let readyWithTimeout = combineLatest(readySignals)
                                    |> deliverOnMainQueue
                                    |> timeout(0.2, queue: Queue.mainQueue(), alternate: .single([]))
                                self.waitingForNodesDisposable.set(readyWithTimeout.start(completed: {
                                    beginReplay()
                                }))
                            } else {
                                beginReplay()
                            }
                        }
                        
                        if options.contains(.LowLatency) || options.contains(.Synchronous) {
                            Queue.mainQueue().async {
                                if self.debugInfo {
                                    print("updateAdjacent LowLatency enqueue \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                                }
                                next()
                            }
                        } else {
                            self.dispatchOnVSync {
                                next()
                            }
                        }
                    })
                })
            })
        }
        
        if options.contains(.Synchronous) {
            actions()
        } else {
            self.async(actions)
        }
    }
    
    private func updateAdjacent(synchronous: Bool, animated: Bool, customAnimationTransition: ControlledTransition?, state: ListViewState, updateAdjacentItemsIndices: Set<Int>, operations: [ListViewStateOperation], completion: @escaping (ListViewState, [ListViewStateOperation]) -> Void) {
        if updateAdjacentItemsIndices.isEmpty {
            completion(state, operations)
        } else {
            var updatedUpdateAdjacentItemsIndices = updateAdjacentItemsIndices
            
            let nodeIndex = updateAdjacentItemsIndices.first!
            updatedUpdateAdjacentItemsIndices.remove(nodeIndex)
            
            var continueWithoutNode = true
            
            var i = 0
            for node in state.nodes {
                if case let .Node(index, _, referenceNode, _) = node, index == nodeIndex {
                    if let referenceNode = referenceNode {
                        continueWithoutNode = false
                        var controlledTransition: ControlledTransition?
                        let updateAnimation: ListViewItemUpdateAnimation
                        if let customAnimationTransition {
                            controlledTransition = customAnimationTransition
                            var duration: Double = insertionAnimationDuration
                            switch customAnimationTransition.legacyAnimator.transition {
                            case .immediate:
                                duration = 0.0
                            case let .animated(durationValue, _):
                                duration = durationValue
                            }
                            updateAnimation = .System(duration: duration * UIView.animationDurationFactor(), transition: customAnimationTransition)
                        } else {
                            if animated {
                                let transition = ControlledTransition(duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: .spring, interactive: true)
                                controlledTransition = transition
                                updateAnimation = .System(duration: insertionAnimationDuration * UIView.animationDurationFactor(), transition: transition)
                            } else {
                                updateAnimation = .None
                            }
                        }
                        
                        if let controlledTransition = controlledTransition {
                            referenceNode.syncWith({ $0 }).addPendingControlledTransition(transition: controlledTransition)
                        }
                        
                        self.items[index].updateNode(async: { f in
                            if synchronous {
                                f()
                            } else {
                                self.async(f)
                            }
                        }, node: {
                            assert(Queue.mainQueue().isCurrent())
                            return referenceNode.syncWith({ $0 })
                        }, params: ListViewItemLayoutParams(width: state.visibleSize.width, leftInset: state.insets.left, rightInset: state.insets.right, availableHeight: state.visibleSize.height - state.insets.top - state.insets.bottom), previousItem: index == 0 ? nil : self.items[index - 1], nextItem: index == self.items.count - 1 ? nil : self.items[index + 1], animation: updateAnimation, completion: { layout, apply in
                            var updatedState = state
                            var updatedOperations = operations
                            
                            let heightDelta = layout.size.height - updatedState.nodes[i].frame.size.height
                            
                            updatedOperations.append(.UpdateLayout(index: i, layout: layout, apply: {
                                return (nil, apply)
                            }))
                            
                            if !animated {
                                let previousFrame = updatedState.nodes[i].frame
                                updatedState.nodes[i].frame = CGRect(origin: previousFrame.origin, size: layout.size)
                                if previousFrame.minY < updatedState.insets.top {
                                    for j in 0 ... i {
                                        updatedState.nodes[j].frame = updatedState.nodes[j].frame.offsetBy(dx: 0.0, dy: -heightDelta)
                                    }
                                } else {
                                    if i != updatedState.nodes.count {
                                        for j in i + 1 ..< updatedState.nodes.count {
                                            updatedState.nodes[j].frame = updatedState.nodes[j].frame.offsetBy(dx: 0.0, dy: heightDelta)
                                        }
                                    }
                                }
                            }
                            
                            self.updateAdjacent(synchronous: synchronous, animated: animated, customAnimationTransition: customAnimationTransition, state: updatedState, updateAdjacentItemsIndices: updatedUpdateAdjacentItemsIndices, operations: updatedOperations, completion: completion)
                        })
                    }
                    break
                }
                i += 1
            }
            
            if continueWithoutNode {
                updateAdjacent(synchronous: synchronous, animated: animated, customAnimationTransition: customAnimationTransition, state: state, updateAdjacentItemsIndices: updatedUpdateAdjacentItemsIndices, operations: operations, completion: completion)
            }
        }
    }
    
    private func fillMissingNodes(synchronous: Bool, synchronousLoads: Bool, animated: Bool, customAnimationTransition: ControlledTransition?, inputAnimatedInsertIndices: Set<Int>, insertDirectionHints: [Int: ListViewItemOperationDirectionHint], inputState: ListViewState, inputPreviousNodes: [Int: QueueLocalObject<ListViewItemNode>], inputOperations: [ListViewStateOperation], inputCompletion: @escaping (ListViewState, [ListViewStateOperation]) -> Void) {
        let animatedInsertIndices = inputAnimatedInsertIndices
        var state = inputState
        let previousNodes = inputPreviousNodes
        var operations = inputOperations
        let completion = inputCompletion
        
        if state.nodes.count > 1000 {
            print("state.nodes.count > 1000")
        }
        
        while true {
            if self.items.count == 0 {
                completion(state, operations)
                break
            } else {
                var insertionItemIndexAndDirection: (Int, ListViewInsertionOffsetDirection)?
                
                if self.debugInfo {
                    assert(true)
                }
                
                if let insertionPoint = state.insertionPoint(insertDirectionHints, itemCount: self.items.count) {
                    insertionItemIndexAndDirection = (insertionPoint.index, insertionPoint.direction)
                }
                
                if self.debugInfo {
                    print("insertionItemIndexAndDirection \(String(describing: insertionItemIndexAndDirection))")
                }
                
                if let insertionItemIndexAndDirection = insertionItemIndexAndDirection {
                    let index = insertionItemIndexAndDirection.0
                    let threadId = pthread_self()
                    var tailRecurse = false
                    self.nodeForItem(synchronous: synchronous, synchronousLoads: synchronousLoads, item: self.items[index], previousNode: previousNodes[index], index: index, previousItem: index == 0 ? nil : self.items[index - 1], nextItem: self.items.count == index + 1 ? nil : self.items[index + 1], params: ListViewItemLayoutParams(width: state.visibleSize.width, leftInset: state.insets.left, rightInset: state.insets.right, availableHeight: state.visibleSize.height - state.insets.top - state.insets.bottom), updateAnimationIsAnimated: animated, updateAnimationIsCrossfade: false, customAnimationTransition: customAnimationTransition, completion: { (node, layout, apply) in
                        if pthread_equal(pthread_self(), threadId) != 0 && !tailRecurse {
                            tailRecurse = true
                            state.insertNode(index, node: node, layout: layout, apply: apply, offsetDirection: insertionItemIndexAndDirection.1, animated: animated && animatedInsertIndices.contains(index), operations: &operations, itemCount: self.items.count)
                        } else {
                            var updatedState = state
                            var updatedOperations = operations
                            updatedState.insertNode(index, node: node, layout: layout, apply: apply, offsetDirection: insertionItemIndexAndDirection.1, animated: animated && animatedInsertIndices.contains(index), operations: &updatedOperations, itemCount: self.items.count)
                            self.fillMissingNodes(synchronous: synchronous, synchronousLoads: synchronousLoads, animated: animated, customAnimationTransition: customAnimationTransition, inputAnimatedInsertIndices: animatedInsertIndices, insertDirectionHints: insertDirectionHints, inputState: updatedState, inputPreviousNodes: previousNodes, inputOperations: updatedOperations, inputCompletion: completion)
                        }
                    })
                    if !tailRecurse {
                        tailRecurse = true
                        break
                    }
                } else {
                    completion(state, operations)
                    break
                }
            }
        }
    }
    
    private func updateNodes(synchronous: Bool, synchronousLoads: Bool, crossfade: Bool, customAnimationTransition: ControlledTransition?, animated: Bool, updateIndicesAndItems: [ListViewUpdateItem], inputState: ListViewState, previousNodes: [Int: QueueLocalObject<ListViewItemNode>], inputOperations: [ListViewStateOperation], completion: @escaping (ListViewState, [ListViewStateOperation]) -> Void) {
        var state = inputState
        var operations = inputOperations
        var updateIndicesAndItems = updateIndicesAndItems
        
        while true {
            if updateIndicesAndItems.isEmpty {
                completion(state, operations)
                break
            } else {
                let updateItem = updateIndicesAndItems[0]
                if let previousNode = previousNodes[updateItem.index] {
                    let threadId = pthread_self()
                    var tailRecurse = false
                    self.nodeForItem(synchronous: synchronous, synchronousLoads: synchronousLoads, item: updateItem.item, previousNode: previousNode, index: updateItem.index, previousItem: updateItem.index == 0 ? nil : self.items[updateItem.index - 1], nextItem: updateItem.index == (self.items.count - 1) ? nil : self.items[updateItem.index + 1], params: ListViewItemLayoutParams(width: state.visibleSize.width, leftInset: state.insets.left, rightInset: state.insets.right, availableHeight: state.visibleSize.height - state.insets.top - state.insets.bottom), updateAnimationIsAnimated: animated, updateAnimationIsCrossfade: crossfade, customAnimationTransition: customAnimationTransition, completion: { _, layout, apply in
                        state.updateNodeAtItemIndex(updateItem.index, layout: layout, direction: updateItem.directionHint, isAnimated: animated, apply: apply, operations: &operations)
                        
                        updateIndicesAndItems.remove(at: 0)
                        if pthread_equal(pthread_self(), threadId) != 0 && !tailRecurse {
                            tailRecurse = true
                        } else {
                            self.updateNodes(synchronous: synchronous, synchronousLoads: synchronousLoads, crossfade: crossfade, customAnimationTransition: customAnimationTransition, animated: animated, updateIndicesAndItems: updateIndicesAndItems, inputState: state, previousNodes: previousNodes, inputOperations: operations, completion: completion)
                        }
                    })
                    if !tailRecurse {
                        tailRecurse = true
                        break
                    }
                } else {
                    updateIndicesAndItems.remove(at: 0)
                }
            }
        }
    }
    
    private func referencePointForInsertionAtIndex(_ nodeIndex: Int) -> CGPoint {
        var index = 0
        for itemNode in self.itemNodes {
            if index == nodeIndex {
                return itemNode.apparentFrame.origin
            }
            index += 1
        }
        if self.itemNodes.count == 0 {
            return CGPoint(x: 0.0, y: self.insets.top)
        } else {
            return CGPoint(x: 0.0, y: self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY)
        }
    }
    
    private func insertNodeAtIndex(animated: Bool, animateAlpha: Bool, animateFullTransition: Bool, forceAnimateInsertion: Bool, previousFrame: CGRect?, nodeIndex: Int, offsetDirection: ListViewInsertionOffsetDirection, node: ListViewItemNode, layout: ListViewItemNodeLayout, apply: () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void), timestamp: Double, listInsets: UIEdgeInsets, visibleBounds: CGRect, forceInvertOffsetDirection: Bool) {
        let insertionOrigin = self.referencePointForInsertionAtIndex(nodeIndex)
        
        let nodeOrigin: CGPoint
        switch offsetDirection {
            case .Up:
                nodeOrigin = CGPoint(x: insertionOrigin.x, y: insertionOrigin.y - (animated ? 0.0 : layout.size.height))
            case .Down:
                nodeOrigin = insertionOrigin
        }
        
        let nodeFrame = CGRect(origin: nodeOrigin, size: CGSize(width: layout.size.width, height: layout.size.height))
        
        let previousApparentHeight = node.apparentHeight
        let previousInsets = node.insets
        
        node.contentSize = layout.contentSize
        node.insets = layout.insets
        node.apparentHeight = animated ? 0.0 : layout.size.height
        node.updateFrame(nodeFrame, within: self.visibleSize)
        if let accessoryItemNode = node.accessoryItemNode {
            node.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
        }
        
        let applyContext = ListViewItemApply(isOnScreen: visibleBounds.intersects(nodeFrame), timestamp: timestamp)
        apply().1(applyContext)
        let invertOffsetDirection = forceInvertOffsetDirection
        
        self.itemNodes.insert(node, at: nodeIndex)
        
        var offsetHeight = node.apparentHeight
        var takenAnimation = false
        
        if let _ = previousFrame, animated && node.index != nil && nodeIndex != self.itemNodes.count - 1 {
            let nextNode = self.itemNodes[nodeIndex + 1]
            if nextNode.index == nil && nextNode.subnodes == nil || nextNode.subnodes!.isEmpty {
                let nextHeight = nextNode.apparentHeight
                if abs(nextHeight - previousApparentHeight) < CGFloat.ulpOfOne {
                    if let _ = nextNode.animationForKey("apparentHeight") {
                        node.apparentHeight = previousApparentHeight
                        
                        offsetHeight = 0.0
                        
                        nextNode.updateFrame(nextNode.frame.offsetBy(dx: 0.0, dy: nextHeight), within: self.visibleSize)
                        self.didScrollWithOffset?(nextHeight, .immediate, nextNode, self.isTrackingOrDecelerating)
                        
                        nextNode.apparentHeight = 0.0
                        
                        nextNode.removeApparentHeightAnimation()
                        
                        takenAnimation = true
                        
                        if abs(layout.size.height - previousApparentHeight) > CGFloat.ulpOfOne {
                            node.addApparentHeightAnimation(layout.size.height, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp, invertOffsetDirection: invertOffsetDirection, update: { [weak node] progress, currentValue in
                                if let node = node {
                                    node.animateFrameTransition(progress, currentValue)
                                }
                            })
                            if node.rotated {
                                node.transitionOffset += previousApparentHeight - layout.size.height
                                node.addTransitionOffsetAnimation(0.0, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp)
                            }
                        }
                    }
                }
            }
        }
        
        if node.index == nil {
            var duration = insertionAnimationDuration
            var hasCustomRemoveAnimation = false
            if let value = self.customItemDeleteAnimationDuration(itemNode: node) {
                duration = value
                hasCustomRemoveAnimation = true
            }
            
            if node.animationForKey("height") == nil || !(node is ListViewTempItemNode) {
                node.addHeightAnimation(0.0, duration: duration * UIView.animationDurationFactor(), beginAt: timestamp)
            }
            if node.animationForKey("apparentHeight") == nil || !(node is ListViewTempItemNode) {
                node.addApparentHeightAnimation(0.0, duration: duration * UIView.animationDurationFactor(), beginAt: timestamp, invertOffsetDirection: invertOffsetDirection, update: { [weak node] progress, currentValue in
                    if let node = node {
                        node.animateFrameTransition(progress, currentValue)
                    }
                })
            }
            if !hasCustomRemoveAnimation {
                node.animateRemoved(timestamp, duration: duration * UIView.animationDurationFactor())
            }
        } else if animated {
            if takenAnimation {
                if let previousFrame = previousFrame {
                    if self.debugInfo {
                        assert(true)
                    }
                    
                    let transitionOffsetDelta = nodeFrame.origin.y - previousFrame.origin.y
                    if node.rotated {
                        node.transitionOffset -= transitionOffsetDelta - previousApparentHeight + layout.size.height
                    } else {
                        node.transitionOffset += transitionOffsetDelta
                    }
                    node.addTransitionOffsetAnimation(0.0, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp)
                    if previousInsets != layout.insets {
                        node.insets = previousInsets
                        node.addInsetsAnimationToValue(layout.insets, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp)
                    }
                }
            } else {
                if !nodeFrame.size.height.isEqual(to: node.apparentHeight) {
                    let addAnimation = previousFrame?.height != nodeFrame.size.height
                    node.addApparentHeightAnimation(nodeFrame.size.height, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp, invertOffsetDirection: invertOffsetDirection, update: { [weak node] progress, currentValue in
                        if let node = node, addAnimation {
                            node.animateFrameTransition(progress, currentValue)
                        }
                    })
                }
            
                if let previousFrame = previousFrame {
                    if self.debugInfo {
                        assert(true)
                    }
                    
                    let transitionOffsetDelta = nodeFrame.origin.y - previousFrame.origin.y
                    if node.rotated {
                        node.transitionOffset -= transitionOffsetDelta - previousApparentHeight + layout.size.height
                    } else {
                        node.transitionOffset += transitionOffsetDelta
                    }
                    node.addTransitionOffsetAnimation(0.0, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp)
                    if previousInsets != layout.insets {
                        node.insets = previousInsets
                        node.addInsetsAnimationToValue(layout.insets, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp)
                    }
                } else {
                    if self.debugInfo {
                        assert(true)
                    }
                    if !node.rotated {
                        if !node.insets.top.isZero {
                            node.transitionOffset += node.insets.top
                            node.addTransitionOffsetAnimation(0.0, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), beginAt: timestamp)
                        }
                    }
                    node.animateInsertion(timestamp, duration: (node.updateAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), options: ListViewItemAnimationOptions(short: invertOffsetDirection))
                }
            }
        } else if animateAlpha {
            if previousFrame == nil {
                if forceAnimateInsertion {
                    node.animateInsertion(timestamp, duration: (node.insertionAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor(), options: ListViewItemAnimationOptions(short: true))
                } else if animateFullTransition {
                    node.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                    node.layer.animateScale(from: 0.7, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                } else {
                    node.animateAdded(timestamp, duration: (node.insertionAnimationDuration() ?? insertionAnimationDuration) * UIView.animationDurationFactor())
                }
            }
        }
        
        if node.apparentHeight > CGFloat.ulpOfOne {
            switch offsetDirection {
            case .Up:
                var i = nodeIndex - 1
                while i >= 0 {
                    var frame = self.itemNodes[i].frame
                    frame.origin.y -= offsetHeight
                    self.itemNodes[i].updateFrame(frame, within: self.visibleSize)
                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                    }
                    i -= 1
                }
            case .Down:
                var i = nodeIndex + 1
                while i < self.itemNodes.count {
                    var frame = self.itemNodes[i].frame
                    frame.origin.y += offsetHeight
                    self.itemNodes[i].updateFrame(frame, within: self.visibleSize)
                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                    }
                    i += 1
                }
            }
        }
    }
    
    private func lowestNodeToInsertBelow() -> ASDisplayNode? {
        if let itemNode = self.reorderNode?.itemNode, itemNode.supernode == self {
            //return itemNode
        }
        var lowestHeaderNode: ASDisplayNode?
        lowestHeaderNode = self.verticalScrollIndicator
        var lowestHeaderNodeIndex: Int?
        for (_, headerNode) in self.itemHeaderNodes {
            if let index = self.view.subviews.firstIndex(of: headerNode.view) {
                if lowestHeaderNodeIndex == nil || index < lowestHeaderNodeIndex! {
                    lowestHeaderNodeIndex = index
                    lowestHeaderNode = headerNode
                }
            }
        }
        return lowestHeaderNode
    }
    
    private func topItemVerticalOrigin() -> CGFloat? {
        var topItemFound = false
        
        for i in 0 ..< self.itemNodes.count {
            if let index = itemNodes[i].index {
                if index == 0 {
                    topItemFound = true
                }
                break
            }
        }
        
        if topItemFound {
            return itemNodes[0].apparentFrame.origin.y
        } else {
            return nil
        }
    }
    
    private func bottomItemMaxY() -> CGFloat? {
        var bottomItemFound = false
        
        for i in (0 ..< self.itemNodes.count).reversed() {
            if let index = itemNodes[i].index {
                if index == self.items.count - 1 {
                    bottomItemFound = true
                    break
                }
            }
        }
        
        if bottomItemFound {
            return itemNodes.last!.apparentFrame.maxY
        } else {
            return nil
        }
    }
    
    private func replayOperations(animated: Bool, animateAlpha: Bool, animateCrossfade: Bool, animateFullTransition: Bool, customAnimationTransition: ControlledTransition?, synchronous: Bool, synchronousLoads: Bool, animateTopItemVerticalOrigin: Bool, operations: [ListViewStateOperation], requestItemInsertionAnimationsIndices: Set<Int>, scrollToItem originalScrollToItem: ListViewScrollToItem?, additionalScrollDistance: CGFloat, updateSizeAndInsets: ListViewUpdateSizeAndInsets?, stationaryItemIndex: Int?, updateOpaqueState: Any?, forceInvertOffsetDirection: Bool = false, completion: () -> Void) {
        var scrollToItem: ListViewScrollToItem?
        var isExperimentalSnapToScrollToItem = false
        if let originalScrollToItem = originalScrollToItem {
            scrollToItem = originalScrollToItem
            if self.experimentalSnapScrollToItem {
                self.scrolledToItem = (originalScrollToItem.index, originalScrollToItem.position)
            }
        } else if let scrolledToItem = self.scrolledToItem, self.experimentalSnapScrollToItem {
            var curve: ListViewAnimationCurve = .Default(duration: nil)
            var animated = false
            if let updateSizeAndInsets = updateSizeAndInsets {
                curve = updateSizeAndInsets.curve
                animated = !updateSizeAndInsets.duration.isZero
            }
            scrollToItem = ListViewScrollToItem(index: scrolledToItem.0, position: scrolledToItem.1, animated: animated, curve: curve, directionHint: .Down)
            isExperimentalSnapToScrollToItem = true
        }
        
        weak var highlightedItemNode: ListViewItemNode?
        if let highlightedItemIndex = self.highlightedItemIndex {
            for itemNode in self.itemNodes {
                if itemNode.index == highlightedItemIndex {
                    highlightedItemNode = itemNode
                    break
                }
            }
        }
        
        let timestamp = CACurrentMediaTime()
        
        var sizeOrInsetsUpdated = false
        if let updateSizeAndInsets = updateSizeAndInsets {
            if updateSizeAndInsets.size != self.visibleSize || updateSizeAndInsets.insets != self.insets {
                sizeOrInsetsUpdated = true
                if updateSizeAndInsets.insets.top == 83.0 && updateSizeAndInsets.duration < 0.5 {
                    assert(true)
                }
            }
        }
        
        let listInsets = updateSizeAndInsets?.insets ?? self.insets
        
        if let updateOpaqueState = updateOpaqueState {
            self.opaqueTransactionState = updateOpaqueState
        }
        
        var previousTopItemVerticalOrigin: CGFloat?
        var snapshotView: UIView?
        if animateCrossfade {
            snapshotView = self.view.snapshotView(afterScreenUpdates: false)
        }
        if animateTopItemVerticalOrigin {
            previousTopItemVerticalOrigin = self.topItemVerticalOrigin()
        }
        
        struct PreviousApparentFrame {
            var frame: CGRect
            var insets: UIEdgeInsets
            
            init(frame: CGRect, insets: UIEdgeInsets) {
                self.frame = frame
                self.insets = insets
            }
        }
        
        var previousApparentFrames: [(ListViewItemNode, PreviousApparentFrame)] = []
        for itemNode in self.itemNodes {
            previousApparentFrames.append((itemNode, PreviousApparentFrame(
                frame: itemNode.apparentFrame,
                insets: itemNode.insets
            )))
        }
        
        struct PreviousHeaderNodeFrame {
            var frame: CGRect
            var alpha: CGFloat
            
            init(frame: CGRect, alpha: CGFloat) {
                self.frame = frame
                self.alpha = alpha
            }
        }
        
        var previousHeaderNodeFrames: [(ListViewItemHeaderNode, PreviousHeaderNodeFrame)] = []
        if animateFullTransition {
            for (_, itemHeaderNode) in self.itemHeaderNodes {
                previousHeaderNodeFrames.append((itemHeaderNode, PreviousHeaderNodeFrame(
                    frame: itemHeaderNode.frame,
                    alpha: itemHeaderNode.getEffectiveAlpha()
                )))
            }
        }
        
        var takenPreviousNodes = Set<ListViewItemNode>()
        for operation in operations {
            if case let .InsertNode(_, _, _, node, _, _) = operation {
                takenPreviousNodes.insert(node.syncWith({ $0 }))
            }
        }
        var removedPreviousNodes = Set<ListViewItemNode>()
        
        let lowestNodeToInsertBelow = self.lowestNodeToInsertBelow()
        var hadInserts = false
        var hadChangesToItemNodes = false
        
        let visibleBounds = CGRect(origin: CGPoint(), size: self.visibleSize)
        
        for operation in operations {
            switch operation {
                case let .InsertNode(index, offsetDirection, nodeAnimated, nodeObject, layout, apply):
                    let node = nodeObject.syncWith({ $0 })
                    var previousFrame: CGRect?
                    for (previousNode, frame) in previousApparentFrames {
                        if previousNode === node {
                            previousFrame = frame.frame
                            break
                        }
                    }
                    var forceAnimateInsertion = false
                    if let index = node.index, requestItemInsertionAnimationsIndices.contains(index) {
                        forceAnimateInsertion = true
                    }
                    var updatedPreviousFrame = previousFrame
                    if let previousFrame = previousFrame, previousFrame.minY >= self.visibleSize.height || previousFrame.maxY < 0.0 {
                        updatedPreviousFrame = nil
                    }
                    
                    self.insertNodeAtIndex(animated: nodeAnimated, animateAlpha: animateAlpha, animateFullTransition: animateFullTransition, forceAnimateInsertion: forceAnimateInsertion, previousFrame: updatedPreviousFrame, nodeIndex: index, offsetDirection: offsetDirection, node: node, layout: layout, apply: apply, timestamp: timestamp, listInsets: listInsets, visibleBounds: visibleBounds, forceInvertOffsetDirection: forceInvertOffsetDirection)
                    hadInserts = true
                    hadChangesToItemNodes = true
                    if let _ = updatedPreviousFrame {
                        if let itemNode = self.reorderNode?.itemNode, itemNode.supernode == self {
                            self.insertSubnode(node, belowSubnode: itemNode)
                        } else if let lowestNodeToInsertBelow = lowestNodeToInsertBelow {
                            self.insertSubnode(node, belowSubnode: lowestNodeToInsertBelow)
                        } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                            self.insertSubnode(node, belowSubnode: verticalScrollIndicator)
                        } else {
                            self.addSubnode(node)
                        }
                        if let extractedBackgroundsNode = node.extractedBackgroundNode {
                            self.extractedBackgroundsContainerNode?.addSubnode(extractedBackgroundsNode)
                        }
                    } else {
                        if animated {
                            if let topItemOverscrollBackground = self.topItemOverscrollBackground {
                                self.insertSubnode(node, aboveSubnode: topItemOverscrollBackground)
                            } else if let extractedBackgroundsContainerNode = self.extractedBackgroundsContainerNode {
                                self.insertSubnode(node, aboveSubnode: extractedBackgroundsContainerNode)
                            } else {
                                self.insertSubnode(node, at: 0)
                            }
                            if let extractedBackgroundsNode = node.extractedBackgroundNode {
                                self.extractedBackgroundsContainerNode?.addSubnode(extractedBackgroundsNode)
                            }
                        } else {
                            if let itemNode = self.reorderNode?.itemNode, itemNode.supernode == self {
                                self.insertSubnode(node, belowSubnode: itemNode)
                            } else if let lowestNodeToInsertBelow = lowestNodeToInsertBelow {
                                self.insertSubnode(node, belowSubnode: lowestNodeToInsertBelow)
                            } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                                self.insertSubnode(node, belowSubnode: verticalScrollIndicator)
                            } else {
                                self.addSubnode(node)
                            }
                            if let extractedBackgroundsNode = node.extractedBackgroundNode {
                                self.extractedBackgroundsContainerNode?.addSubnode(extractedBackgroundsNode)
                            }
                        }
                    }
                case let .InsertDisappearingPlaceholder(index, referenceNodeObject, offsetDirection):
                    var height: CGFloat?
                    var previousLayout: ListViewItemNodeLayout?
                    
                    let referenceNode = referenceNodeObject.syncWith({ $0 })
                    hadChangesToItemNodes = true
                    
                    for (node, previousFrame) in previousApparentFrames {
                        if node === referenceNode {
                            height = previousFrame.frame.size.height
                            previousLayout = ListViewItemNodeLayout(contentSize: node.contentSize, insets: node.insets)
                            break
                        }
                    }
                    
                    if let height = height, let previousLayout = previousLayout {
                        if takenPreviousNodes.contains(referenceNode) {
                            let tempNode = ListViewTempItemNode(layerBacked: true)
                            self.insertNodeAtIndex(animated: false, animateAlpha: false, animateFullTransition: false, forceAnimateInsertion: false, previousFrame: nil, nodeIndex: index, offsetDirection: offsetDirection, node: tempNode, layout: ListViewItemNodeLayout(contentSize: CGSize(width: self.visibleSize.width, height: height), insets: UIEdgeInsets()), apply: { return (nil, { _ in }) }, timestamp: timestamp, listInsets: listInsets, visibleBounds: visibleBounds, forceInvertOffsetDirection: forceInvertOffsetDirection)
                        } else {
                            referenceNode.index = nil
                            self.insertNodeAtIndex(animated: false, animateAlpha: false, animateFullTransition: false, forceAnimateInsertion: false, previousFrame: nil, nodeIndex: index, offsetDirection: offsetDirection, node: referenceNode, layout: previousLayout, apply: { return (nil, { _ in }) }, timestamp: timestamp, listInsets: listInsets, visibleBounds: visibleBounds, forceInvertOffsetDirection: forceInvertOffsetDirection)
                            if let verticalScrollIndicator = self.verticalScrollIndicator {
                                self.insertSubnode(referenceNode, belowSubnode: verticalScrollIndicator)
                            } else {
                                self.addSubnode(referenceNode)
                            }
                            if let extractedBackgroundsNode = referenceNode.extractedBackgroundNode {
                                self.extractedBackgroundsContainerNode?.addSubnode(extractedBackgroundsNode)
                            }
                        }
                    } else {
                        assertionFailure()
                    }
                case let .Remap(mapping):
                    for node in self.itemNodes {
                        if let index = node.index {
                            if let mapped = mapping[index] {
                                node.index = mapped
                                hadChangesToItemNodes = true
                            }
                        }
                    }
                case let .Remove(index, offsetDirection):
                    let apparentFrame = self.itemNodes[index].apparentFrame
                    let height = apparentFrame.size.height
                    switch offsetDirection {
                        case .Up:
                            if index != self.itemNodes.count - 1 {
                                for i in index + 1 ..< self.itemNodes.count {
                                    var frame = self.itemNodes[i].frame
                                    frame.origin.y -= height
                                    self.itemNodes[i].updateFrame(frame, within: self.visibleSize)
                                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                                    }
                                }
                            }
                        case .Down:
                            if index != 0 {
                                for i in (0 ..< index).reversed() {
                                    var frame = self.itemNodes[i].frame
                                    frame.origin.y += height
                                    self.itemNodes[i].updateFrame(frame, within: self.visibleSize)
                                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                                    }
                                }
                            }
                    }
                
                    if animateFullTransition {
                        for (previousNode, previousFrame) in previousApparentFrames {
                            if previousNode === self.itemNodes[index] {
                                removedPreviousNodes.insert(previousNode)
                                self.itemNodes[index].frame = previousFrame.frame
                                break
                            }
                        }
                    }
                            
                    self.removeItemNodeAtIndex(index, animateFullTransition: animateFullTransition)
                    hadChangesToItemNodes = true
                case let .UpdateLayout(index, layout, apply):
                    let node = self.itemNodes[index]
                    
                    let previousApparentHeight = node.apparentHeight
                    let previousInsets = node.insets
                    
                    node.contentSize = layout.contentSize
                    node.insets = layout.insets
                    
                    let updatedApparentHeight = node.bounds.size.height
                    let updatedInsets = node.insets
                    
                    var apparentFrame = node.apparentFrame
                    apparentFrame.size.height = updatedApparentHeight
                    
                    let applyContext = ListViewItemApply(isOnScreen: visibleBounds.intersects(apparentFrame), timestamp: timestamp)
                    apply().1(applyContext)
                    let invertOffsetDirection = applyContext.invertOffsetDirection || forceInvertOffsetDirection
                    
                    var offsetRanges = OffsetRanges()
                    
                    if let customAnimationTransition {
                        node.apparentHeight = updatedApparentHeight
                        
                        let apparentHeightDelta = updatedApparentHeight - previousApparentHeight
                        if apparentHeightDelta != 0.0 {
                            var apparentFrame = node.apparentFrame
                            apparentFrame.origin.y += offsetRanges.offsetForIndex(index)
                            if apparentFrame.maxY < self.insets.top {
                                offsetRanges.offset(IndexRange(first: 0, last: index), offset: -apparentHeightDelta)
                            } else {
                                offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: apparentHeightDelta)
                            }
                        }
                        
                        if previousApparentHeight != updatedApparentHeight {
                            customAnimationTransition.legacyAnimator.transition.animateOffsetAdditive(node: node, offset: previousApparentHeight - updatedApparentHeight)
                        }
                    } else if animated {
                        if updatedInsets != previousInsets {
                            node.insets = previousInsets
                            node.addInsetsAnimationToValue(updatedInsets, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                        }
                        
                        if !abs(updatedApparentHeight - previousApparentHeight).isZero {
                            let currentAnimation = node.animationForKey("apparentHeight")
                            if let currentAnimation = currentAnimation, let toFloat = currentAnimation.to as? CGFloat, toFloat.isEqual(to: updatedApparentHeight) {
                                /*node.addApparentHeightAnimation(updatedApparentHeight, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, update: { [weak node] progress, currentValue in
                                    if let node = node {
                                        node.animateFrameTransition(progress, currentValue)
                                    }
                                })
                                node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)*/
                            } else {
                                node.apparentHeight = previousApparentHeight
                                node.animateFrameTransition(0.0, previousApparentHeight)
                                node.addApparentHeightAnimation(updatedApparentHeight, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, invertOffsetDirection: invertOffsetDirection, update: { [weak node] progress, currentValue in
                                    if let node = node {
                                        node.animateFrameTransition(progress, currentValue)
                                    }
                                })
                                
                                if node.rotated {
                                    if currentAnimation == nil {
                                        let insetPart: CGFloat = previousInsets.bottom - layout.insets.bottom
                                        node.transitionOffset += previousApparentHeight - layout.size.height - insetPart
                                        node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                                    } else {
                                        let insetPart: CGFloat = previousInsets.bottom - layout.insets.bottom
                                        node.transitionOffset = previousApparentHeight - layout.size.height - insetPart
                                        node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                                    }
                                }
                            }
                        } else {
                            if node.shouldAnimateHorizontalFrameTransition() {
                                node.addApparentHeightAnimation(updatedApparentHeight, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, update: { [weak node] progress, currentValue in
                                    if let node = node {
                                        node.animateFrameTransition(progress, currentValue)
                                    }
                                })
                            }
                        }
                    } else {
                        node.apparentHeight = updatedApparentHeight
                        
                        let apparentHeightDelta = updatedApparentHeight - previousApparentHeight
                        if apparentHeightDelta != 0.0 {
                            var apparentFrame = node.apparentFrame
                            apparentFrame.origin.y += offsetRanges.offsetForIndex(index)
                            if apparentFrame.maxY < self.insets.top {
                                offsetRanges.offset(IndexRange(first: 0, last: index), offset: -apparentHeightDelta)
                            } else {
                                offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: apparentHeightDelta)
                            }
                        }
                    }
                    
                    if let accessoryItemNode = node.accessoryItemNode {
                        node.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                    }
                    
                    var index = 0
                    for itemNode in self.itemNodes {
                        let offset = offsetRanges.offsetForIndex(index)
                        if offset != 0.0 {
                            var frame = itemNode.frame
                            frame.origin.y += offset
                            itemNode.updateFrame(frame, within: self.visibleSize, transition: customAnimationTransition)
                        }
                        
                        index += 1
                    }
            }
            
            if self.debugInfo {
                //print("operation \(self.itemNodes.map({"\($0.index) \(unsafeAddressOf($0))"}))")
            }
        }
        
        for itemNode in self.itemNodes {
            itemNode.beginPendingControlledTransitions(beginAt: timestamp, forceRestart: false)
        }
        
        if hadInserts, let reorderNode = self.reorderNode, reorderNode.supernode != nil {
            self.view.bringSubviewToFront(reorderNode.view)
            if let verticalScrollIndicator = self.verticalScrollIndicator {
                verticalScrollIndicator.view.superview?.bringSubviewToFront(verticalScrollIndicator.view)
            }
        }
        
        if hadChangesToItemNodes {
            self.assignHeaderSpaceAffinities()
        }
        
        if self.debugInfo {
            //print("replay after \(self.itemNodes.map({"\($0.index) \(unsafeAddressOf($0))"}))")
        }
        
        if let scrollToItem = scrollToItem, !self.areAllItemsOnScreen() || !sizeOrInsetsUpdated {
            self.stopScrolling()
            
            for itemNode in self.itemNodes {
                if let index = itemNode.index, index == scrollToItem.index {
                    let insets = self.insets// updateSizeAndInsets?.insets ?? self.insets
                    
                    var offset: CGFloat
                    switch scrollToItem.position {
                        case let .bottom(additionalOffset):
                            offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY + itemNode.scrollPositioningInsets.bottom + additionalOffset
                        case let .top(additionalOffset):
                            offset = (insets.top + additionalOffset + itemNode.scrollPositioningInsets.top) - itemNode.apparentFrame.minY
                        case let .center(overflow):
                            let contentAreaHeight = self.visibleSize.height - insets.bottom - insets.top
                            switch overflow {
                            case let .custom(getOverflow):
                                let anchorOffset = getOverflow(itemNode)
                                offset = insets.top + floor(contentAreaHeight / 2.0) - itemNode.apparentFrame.minY - anchorOffset
                            case .top, .bottom:
                                if itemNode.apparentFrame.size.height <= contentAreaHeight + CGFloat.ulpOfOne {
                                    offset = insets.top + floor(((self.visibleSize.height - insets.bottom - insets.top) - itemNode.frame.size.height) / 2.0) - itemNode.apparentFrame.minY
                                } else {
                                    switch overflow {
                                    case .top:
                                        offset = insets.top - itemNode.apparentFrame.minY
                                    case .bottom:
                                        offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY
                                    case .custom:
                                        assertionFailure()
                                        offset = insets.top - itemNode.apparentFrame.minY
                                    }
                                }
                            }
                        case .visible:
                            if itemNode.apparentFrame.size.height > self.visibleSize.height - insets.top - insets.bottom {
                                if itemNode.apparentFrame.maxY > self.visibleSize.height - insets.bottom {
                                    offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY + itemNode.scrollPositioningInsets.bottom
                                } else {
                                    offset = 0.0
                                }
                            } else {
                                if itemNode.apparentFrame.maxY > self.visibleSize.height - insets.bottom {
                                    offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY + itemNode.scrollPositioningInsets.bottom
                                } else if itemNode.apparentFrame.minY < insets.top {
                                    offset = insets.top - itemNode.apparentFrame.minY - itemNode.scrollPositioningInsets.top
                                } else {
                                    offset = 0.0
                                }
                            }
                    }
                    
                    for itemNode in self.itemNodes {
                        var frame = itemNode.frame
                        frame.origin.y += offset
                        itemNode.updateFrame(frame, within: self.visibleSize)
                        self.didScrollWithOffset?(-offset, .immediate, itemNode, self.isTrackingOrDecelerating)
                        if let accessoryItemNode = itemNode.accessoryItemNode {
                            itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                        }
                    }
                    
                    break
                }
            }
        } else if let stationaryItemIndex = stationaryItemIndex {
            for itemNode in self.itemNodes {
                if let index = itemNode.index, index == stationaryItemIndex {
                    for (previousNode, previousFrame) in previousApparentFrames {
                        if previousNode === itemNode {
                            let offset = previousFrame.frame.minY - itemNode.frame.minY
                            
                            if abs(offset) > CGFloat.ulpOfOne {
                                for itemNode in self.itemNodes {
                                    var frame = itemNode.frame
                                    frame.origin.y += offset
                                    itemNode.updateFrame(frame, within: self.visibleSize)
                                    if let accessoryItemNode = itemNode.accessoryItemNode {
                                        itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                                    }
                                }
                            }
                            
                            break
                        }
                    }
                    break
                }
            }
        } else if !additionalScrollDistance.isZero {
            if !self.ignoreStopScrolling {
                self.stopScrolling()
            }
        }
        
        self.debugCheckMonotonity()
        
        var sizeAndInsetsOffset: CGFloat = 0.0
        
        var headerNodesTransition: (ContainedViewLayoutTransition, Bool, CGFloat) = (.immediate, false, 0.0)
        
        var deferredUpdateVisible = false
        
        if let updateSizeAndInsets = updateSizeAndInsets {
            if self.insets != updateSizeAndInsets.insets || self.headerInsets != updateSizeAndInsets.headerInsets || !self.visibleSize.height.isEqual(to: updateSizeAndInsets.size.height) {
                let previousVisibleSize = self.visibleSize
                self.visibleSize = updateSizeAndInsets.size
                
                var offsetFix: CGFloat
                let insetDeltaOffsetFix: CGFloat = 0.0
                if (self.isTracking && !self.allowInsetFixWhileTracking) || isExperimentalSnapToScrollToItem {
                    offsetFix = 0.0
                } else if self.snapToBottomInsetUntilFirstInteraction {
                    offsetFix = -updateSizeAndInsets.insets.bottom + self.insets.bottom
                } else {
                    /*if let visualInsets = self.visualInsets, animated, (visualInsets.top == updateSizeAndInsets.insets.top || visualInsets.top == self.insets.top) {
                        offsetFix = 0.0
                    } else {*/
                        offsetFix = updateSizeAndInsets.insets.top - self.insets.top
                    //}
                }
                
                offsetFix += additionalScrollDistance
                
                /*if let topItemNode = self.itemNodes.first(where: { $0.index == 0 }) {
                    let topEdge = self.scroller.contentOffset.y + updateSizeAndInsets.insets.top
                    offsetFix = -(topEdge - topItemNode.apparentFrame.minY)
                }*/
                
                self.insets = updateSizeAndInsets.insets
                self.headerInsets = updateSizeAndInsets.headerInsets ?? self.insets
                self.scrollIndicatorInsets = updateSizeAndInsets.scrollIndicatorInsets ?? self.insets
                self.itemOffsetInsets = updateSizeAndInsets.itemOffsetInsets
                self.ensureTopInsetForOverlayHighlightedItems = updateSizeAndInsets.ensureTopInsetForOverlayHighlightedItems
                self.visibleSize = updateSizeAndInsets.size
                
                for itemNode in self.itemNodes {
                    itemNode.updateFrame(itemNode.frame.offsetBy(dx: 0.0, dy: offsetFix), within: self.visibleSize, transition: customAnimationTransition)
                }
                
                let (snappedTopInset, snapToBoundsOffset) = self.snapToBounds(snapTopItem: scrollToItem != nil && scrollToItem?.directionHint != .Down, stackFromBottom: self.stackFromBottom, updateSizeAndInsets: updateSizeAndInsets, isExperimentalSnapToScrollToItem: isExperimentalSnapToScrollToItem, insetDeltaOffsetFix: insetDeltaOffsetFix)
                
                if !snappedTopInset.isZero && (previousVisibleSize.height.isZero || previousApparentFrames.isEmpty) {
                    offsetFix += snappedTopInset
                    
                    //self.didScrollWithOffset?(-snappedTopInset, .immediate, nil)
                    
                    for itemNode in self.itemNodes {
                        itemNode.updateFrame(itemNode.frame.offsetBy(dx: 0.0, dy: snappedTopInset), within: self.visibleSize)
                    }
                }
                
                var completeOffset = offsetFix
                
                if !snapToBoundsOffset.isZero {
                    self.updateVisibleContentOffset()
                }
                
                sizeAndInsetsOffset = offsetFix
                completeOffset += snapToBoundsOffset
                
                if !updateSizeAndInsets.duration.isZero && !isExperimentalSnapToScrollToItem {
                    for i in 0 ..< previousApparentFrames.count {
                        previousApparentFrames[i].1.frame.origin.y += completeOffset - offsetFix
                    }
                    
                    let animation: CABasicAnimation
                    let animationCurve: ContainedViewLayoutTransitionCurve
                    let animationDuration: Double
                    switch updateSizeAndInsets.curve {
                        case let .Spring(duration):
                            headerNodesTransition = (.animated(duration: duration, curve: .spring), false, -completeOffset)
                            animationCurve = .spring
                            let springAnimation = makeSpringAnimation("sublayerTransform", duration: duration)
                            springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                            springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            springAnimation.isRemovedOnCompletion = true
                            
                            let k = Float(UIView.animationDurationFactor())
                            var speed: Float = 1.0
                            if k != 0 && k != 1 {
                                speed = Float(1.0) / k
                            }
                            if !duration.isZero {
                                springAnimation.speed = speed * Float(springAnimation.duration / duration)
                            }
                            animationDuration = duration
                            
                            springAnimation.isAdditive = true
                            animation = springAnimation
                        case let .Custom(duration, cp1x, cp1y, cp2x, cp2y):
                            headerNodesTransition = (.animated(duration: duration, curve: .custom(cp1x, cp1y, cp2x, cp2y)), false, -completeOffset)
                            animationCurve = .custom(cp1x, cp1y, cp2x, cp2y)
                            let springAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                            springAnimation.timingFunction = CAMediaTimingFunction(controlPoints: cp1x, cp1y, cp2x, cp2y)
                            springAnimation.duration = duration * UIView.animationDurationFactor()
                            springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                            springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            springAnimation.isRemovedOnCompletion = true

                            animationDuration = duration

                            springAnimation.isAdditive = true
                            animation = springAnimation
                        case let .Default(duration):
                            headerNodesTransition = (.animated(duration: max(duration ?? 0.3, updateSizeAndInsets.duration), curve: .easeInOut), false, -completeOffset)
                            animationCurve = .easeInOut
                            animationDuration = duration ?? 0.3
                            let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                            basicAnimation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                            basicAnimation.duration = updateSizeAndInsets.duration * UIView.animationDurationFactor()
                            basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                            basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            basicAnimation.isRemovedOnCompletion = true
                            basicAnimation.isAdditive = true
                            animation = basicAnimation
                    }
                    
                    deferredUpdateVisible = true
                    animation.completion = { [weak self] _ in
                        self?.updateItemNodesVisibilities(onlyPositive: false)
                    }
                    self.layer.add(animation, forKey: nil)
                    if !completeOffset.isZero {
                        for itemNode in self.itemNodes {
                            itemNode.applyAbsoluteOffset(value: CGPoint(x: 0.0, y: -completeOffset), animationCurve: animationCurve, duration: animationDuration)
                        }
                        self.didScrollWithOffset?(-completeOffset, ContainedViewLayoutTransition.animated(duration: animationDuration, curve: animationCurve), nil, self.isTrackingOrDecelerating)
                    }
                } else {
                    self.didScrollWithOffset?(-completeOffset, .immediate, nil, self.isTrackingOrDecelerating)
                }
            } else {
                self.visibleSize = updateSizeAndInsets.size
                
                if !self.snapToBounds(snapTopItem: scrollToItem != nil && scrollToItem?.directionHint != .Down, stackFromBottom: self.stackFromBottom, insetDeltaOffsetFix: 0.0).offset.isZero {
                    self.updateVisibleContentOffset()
                }
            }
            
            if let updatedTopItemVerticalOrigin = self.topItemVerticalOrigin(), let previousTopItemVerticalOrigin = previousTopItemVerticalOrigin, animateTopItemVerticalOrigin, !updatedTopItemVerticalOrigin.isEqual(to: previousTopItemVerticalOrigin) {
                self.stopScrolling()
                
                let completeOffset = updatedTopItemVerticalOrigin - previousTopItemVerticalOrigin
                let duration: Double = 0.4
                
                if let snapshotView = snapshotView {
                    snapshotView.frame = CGRect(origin: CGPoint(x: 0.0, y: completeOffset), size: snapshotView.frame.size)
                    self.view.addSubview(snapshotView)
                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                        snapshotView?.removeFromSuperview()
                    })
                }
                
                let springAnimation = makeSpringAnimation("sublayerTransform", duration: duration)
                springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                springAnimation.isRemovedOnCompletion = true
                
                let k = Float(UIView.animationDurationFactor())
                var speed: Float = 1.0
                if k != 0 && k != 1 {
                    speed = Float(1.0) / k
                }
                springAnimation.speed = speed * Float(springAnimation.duration / duration)
                
                springAnimation.isAdditive = true
                self.layer.add(springAnimation, forKey: nil)

                if !completeOffset.isZero {
                    for itemNode in self.itemNodes {
                        itemNode.applyAbsoluteOffset(value: CGPoint(x: 0.0, y: -completeOffset), animationCurve: .spring, duration: duration)
                    }
                    self.didScrollWithOffset?(-completeOffset, .animated(duration: duration, curve: .spring), nil, self.isTrackingOrDecelerating)
                }
            } else {
                if let snapshotView = snapshotView {
                    snapshotView.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: snapshotView.frame.size)
                    self.view.addSubview(snapshotView)
                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                        snapshotView?.removeFromSuperview()
                    })
                }
            }
            
            let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
            self.ignoreScrollingEvents = true
            if self.scroller.bounds.size != self.visibleSize {
                self.scroller.frame = CGRect(origin: CGPoint(), size: self.visibleSize)
            }
            //self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            
            //self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
            //self.scroller.contentOffset = self.lastContentOffset
            
            //self.lastContentOffset = self.scroller.contentOffset
            //print("lastContentOffset8 = \(self.lastContentOffset.y)")
            
            self.ignoreScrollingEvents = wasIgnoringScrollingEvents
        } else {
            let (snappedTopInset, snapToBoundsOffset) = self.snapToBounds(snapTopItem: scrollToItem != nil && scrollToItem?.directionHint != .Down, stackFromBottom: self.stackFromBottom, updateSizeAndInsets: updateSizeAndInsets, scrollToItem: scrollToItem, insetDeltaOffsetFix: 0.0)

            if !snappedTopInset.isZero && previousApparentFrames.isEmpty {
                self.didScrollWithOffset?(-snappedTopInset, .immediate, nil, self.isTrackingOrDecelerating)
                
                for itemNode in self.itemNodes {
                    itemNode.updateFrame(itemNode.frame.offsetBy(dx: 0.0, dy: snappedTopInset), within: self.visibleSize)
                }
            }

            if !snapToBoundsOffset.isZero {
                self.updateVisibleContentOffset()
            }

            if let snapshotView = snapshotView {
                snapshotView.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: snapshotView.frame.size)
                self.view.addSubview(snapshotView)
                snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                    snapshotView?.removeFromSuperview()
                })
            }
        }
        
        var accessoryNodesTransition: ContainedViewLayoutTransition = .immediate
        if let scrollToItem = scrollToItem, scrollToItem.animated {
            accessoryNodesTransition = .animated(duration: 0.3, curve: .easeInOut)
        }
        
        self.updateAccessoryNodes(transition: accessoryNodesTransition, synchronous: synchronous, currentTimestamp: timestamp, leftInset: listInsets.left, rightInset: listInsets.right)
        
        if let highlightedItemNode = highlightedItemNode {
            if highlightedItemNode.index != self.highlightedItemIndex {
                highlightedItemNode.setHighlighted(false, at: CGPoint(), animated: false)
                self.highlightedItemIndex = nil
                self.selectionTouchLocation = nil
            }
        } else if self.highlightedItemIndex != nil {
            self.highlightedItemIndex = nil
        }
        
        if animateFullTransition {
            for (previousNode, previousFrame) in previousApparentFrames {
                if !takenPreviousNodes.contains(previousNode) && !removedPreviousNodes.contains(previousNode) {
                    if previousFrame.frame.maxY < self.insets.top || previousFrame.frame.minY > self.visibleSize.height - self.insets.bottom {
                        previousNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                        previousNode.layer.animateScale(from: 0.7, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                    } else {
                        let boundsOffset: CGFloat
                        if self.rotated {
                            boundsOffset = previousFrame.insets.bottom - previousNode.insets.bottom
                        } else {
                            boundsOffset = previousFrame.insets.top - previousNode.insets.top
                        }
                        previousNode.layer.animatePosition(from: CGPoint(x: 0.0, y: previousFrame.frame.minY - previousNode.frame.minY + boundsOffset), to: CGPoint(), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
                    }
                }
            }
        }
        
        let applyHeaderNodesFullTransition: () -> Void = {
            if animateFullTransition {
                for (_, itemHeaderNode) in self.itemHeaderNodes {
                    var found = false
                    inner: for (previousHeaderNode, previousFrame) in previousHeaderNodeFrames {
                        if itemHeaderNode === previousHeaderNode && previousHeaderNode.supernode === self {
                            found = true
                            
                            if previousFrame.frame.maxY < self.insets.top || previousFrame.frame.minY > self.visibleSize.height - self.insets.bottom || previousFrame.alpha == 0.0 {
                                itemHeaderNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                                itemHeaderNode.layer.animateScale(from: 0.7, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                            } else {
                                itemHeaderNode.layer.animatePosition(from: CGPoint(x: 0.0, y: previousFrame.frame.minY - itemHeaderNode.frame.minY), to: CGPoint(), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
                            }
                            
                            break inner
                        }
                    }
                    
                    if !found {
                        itemHeaderNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                        itemHeaderNode.layer.animateScale(from: 0.7, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                    }
                }
            }
        }
        
        if let scrollToItem = scrollToItem, scrollToItem.animated {
            if self.itemNodes.count != 0 {
                var offset: CGFloat?
                
                var temporaryPreviousNodes: [ListViewItemNode] = []
                var previousUpperBound: CGFloat?
                var previousLowerBound: CGFloat?
                if case .visible = scrollToItem.position {
                    for (previousNode, previousFrame) in previousApparentFrames {
                        if previousNode.supernode == nil {
                            temporaryPreviousNodes.append(previousNode)
                            previousNode.updateFrame(previousFrame.frame, within: self.visibleSize)
                            if previousUpperBound == nil || previousUpperBound! > previousFrame.frame.minY {
                                previousUpperBound = previousFrame.frame.minY
                            }
                            if previousLowerBound == nil || previousLowerBound! < previousFrame.frame.maxY {
                                previousLowerBound = previousFrame.frame.maxY
                            }
                        } else {
                            if previousNode.canBeUsedAsScrollToItemAnchor {
                                offset = previousNode.apparentFrame.minY - previousFrame.frame.minY
                                break
                            }
                        }
                    }
                } else {
                    for (previousNode, previousFrame) in previousApparentFrames {
                        if previousNode.supernode == nil {
                            temporaryPreviousNodes.append(previousNode)
                            previousNode.updateFrame(previousFrame.frame, within: self.visibleSize)
                            if previousUpperBound == nil || previousUpperBound! > previousFrame.frame.minY {
                                previousUpperBound = previousFrame.frame.minY
                            }
                            if previousLowerBound == nil || previousLowerBound! < previousFrame.frame.maxY {
                                previousLowerBound = previousFrame.frame.maxY
                            }
                        } else {
                            if previousNode.canBeUsedAsScrollToItemAnchor {
                                offset = previousNode.apparentFrame.minY - previousFrame.frame.minY
                            }
                        }
                    }
                
                    if offset == nil {
                        let updatedUpperBound = self.itemNodes[0].apparentFrame.minY
                        let updatedLowerBound = max(self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY, self.visibleSize.height)
                        
                        switch scrollToItem.directionHint {
                            case .Up:
                                if let previousUpperBound = previousUpperBound {
                                    offset = updatedLowerBound - previousUpperBound
                                }
                            case .Down:
                                offset = updatedUpperBound - (previousLowerBound ?? self.visibleSize.height)
                        }
                    }
                }
                
                if let offsetValue = offset {
                    offset = offsetValue - sizeAndInsetsOffset
                }
                
                var previousItemHeaderNodes: [ListViewItemHeaderNode] = []
                let offsetOrZero: CGFloat = offset ?? 0.0
                switch scrollToItem.curve {
                    case let .Spring(duration):
                        headerNodesTransition = (.animated(duration: duration, curve: .spring), headerNodesTransition.1, headerNodesTransition.2 - offsetOrZero)
                    case let .Default(duration):
                        headerNodesTransition = (.animated(duration: duration ?? 0.3, curve: .easeInOut), true, headerNodesTransition.2 - offsetOrZero)
                    case let .Custom(duration, cp1x, cp1y, cp2x, cp2y):
                        headerNodesTransition = (.animated(duration: duration, curve: .custom(cp1x, cp1y, cp2x, cp2y)), headerNodesTransition.1, headerNodesTransition.2 - offsetOrZero)
                }
                for (_, headerNode) in self.itemHeaderNodes {
                    previousItemHeaderNodes.append(headerNode)
                }
                
                self.updateItemHeaders(leftInset: listInsets.left, rightInset: listInsets.right, synchronousLoad: synchronousLoads, transition: headerNodesTransition, animateInsertion: animated || !requestItemInsertionAnimationsIndices.isEmpty, animateFullTransition: animateFullTransition)
                self.onContentsUpdated?(headerNodesTransition.0)
                
                if let offset = offset, !offset.isZero {
                    //self.didScrollWithOffset?(-offset, headerNodesTransition.0, nil)
                    let lowestNodeToInsertBelow = self.lowestNodeToInsertBelow()
                    for itemNode in temporaryPreviousNodes {
                        itemNode.updateFrame(itemNode.frame.offsetBy(dx: 0.0, dy: offset), within: self.visibleSize)
                        if let lowestNodeToInsertBelow = lowestNodeToInsertBelow {
                            self.insertSubnode(itemNode, belowSubnode: lowestNodeToInsertBelow)
                        } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                            self.insertSubnode(itemNode, belowSubnode: verticalScrollIndicator)
                        } else {
                            self.addSubnode(itemNode)
                        }
                        if let extractedBackgroundsNode = itemNode.extractedBackgroundNode {
                            self.extractedBackgroundsContainerNode?.addSubnode(extractedBackgroundsNode)
                        }
                    }
                    
                    var temporaryHeaderNodes: [ListViewItemHeaderNode] = []
                    for headerNode in previousItemHeaderNodes {
                        if headerNode.supernode == nil {
                            headerNode.frame = headerNode.frame.offsetBy(dx: 0.0, dy: offset)
                            temporaryHeaderNodes.append(headerNode)
                            if let verticalScrollIndicator = self.verticalScrollIndicator {
                                self.insertSubnode(headerNode, belowSubnode: verticalScrollIndicator)
                            } else {
                                self.addSubnode(headerNode)
                            }
                        }
                    }
                    
                    let animation: CABasicAnimation
                    let reverseAnimation: CABasicAnimation
                    let animationCurve: ContainedViewLayoutTransitionCurve
                    let animationDuration: Double
                    switch scrollToItem.curve {
                        case let .Spring(duration):
                            animationCurve = .spring
                            animationDuration = duration
                            let springAnimation = makeSpringAnimation("sublayerTransform", duration: duration)
                            springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                            springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            springAnimation.isRemovedOnCompletion = true
                            springAnimation.isAdditive = true
                            springAnimation.fillMode = CAMediaTimingFillMode.forwards
                            if #available(iOS 15.0, *) {
                                springAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                            }
                            
                            let k = Float(UIView.animationDurationFactor())
                            var speed: Float = 1.0
                            if k != 0 && k != 1 {
                                speed = Float(1.0) / k
                            }
                            if !duration.isZero {
                                springAnimation.speed = speed * Float(springAnimation.duration / duration)
                            }
                            
                            let reverseSpringAnimation = makeSpringAnimation("sublayerTransform", duration: duration)
                            reverseSpringAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                            reverseSpringAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            reverseSpringAnimation.isRemovedOnCompletion = true
                            reverseSpringAnimation.isAdditive = true
                            reverseSpringAnimation.fillMode = CAMediaTimingFillMode.forwards
                            
                            reverseSpringAnimation.speed = speed * Float(reverseSpringAnimation.duration / duration)
                            
                            animation = springAnimation
                            reverseAnimation = reverseSpringAnimation
                        case let .Custom(duration, cp1x, cp1y, cp2x, cp2y):
                            animationCurve = .custom(cp1x, cp1y, cp2x, cp2y)
                            animationDuration = duration
                            let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                            basicAnimation.timingFunction = CAMediaTimingFunction(controlPoints: cp1x, cp1y, cp2x, cp2y)
                            basicAnimation.duration = duration * UIView.animationDurationFactor()
                            basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                            basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            basicAnimation.isRemovedOnCompletion = true
                            basicAnimation.isAdditive = true
                            if #available(iOS 15.0, *) {
                                basicAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                            }

                            let reverseBasicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                            reverseBasicAnimation.timingFunction = CAMediaTimingFunction(controlPoints: cp1x, cp1y, cp2x, cp2y)
                            reverseBasicAnimation.duration = duration * UIView.animationDurationFactor()
                            reverseBasicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                            reverseBasicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            reverseBasicAnimation.isRemovedOnCompletion = true
                            reverseBasicAnimation.isAdditive = true
                            if #available(iOS 15.0, *) {
                                reverseBasicAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                            }

                            animation = basicAnimation
                            reverseAnimation = reverseBasicAnimation
                        case let .Default(duration):
                            if let duration = duration {
                                animationCurve = .easeInOut
                                animationDuration = duration
                                let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                basicAnimation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                                basicAnimation.duration = duration * UIView.animationDurationFactor()
                                basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                                basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                basicAnimation.isRemovedOnCompletion = true
                                basicAnimation.isAdditive = true
                                if #available(iOS 15.0, *) {
                                    basicAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                                }
                                
                                let reverseBasicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                reverseBasicAnimation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                                reverseBasicAnimation.duration = duration * UIView.animationDurationFactor()
                                reverseBasicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                                reverseBasicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                reverseBasicAnimation.isRemovedOnCompletion = true
                                reverseBasicAnimation.isAdditive = true
                                if #available(iOS 15.0, *) {
                                    reverseBasicAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                                }
                                
                                animation = basicAnimation
                                reverseAnimation = reverseBasicAnimation
                            } else {
                                animationCurve = .slide
                                animationDuration = duration ?? 0.3
                                
                                let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                basicAnimation.timingFunction = ContainedViewLayoutTransitionCurve.slide.mediaTimingFunction
                                basicAnimation.duration = (duration ?? 0.3) * UIView.animationDurationFactor()
                                basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                                basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                basicAnimation.isRemovedOnCompletion = true
                                basicAnimation.isAdditive = true
                                if #available(iOS 15.0, *) {
                                    basicAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                                }
                                
                                let reverseBasicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                reverseBasicAnimation.timingFunction = ContainedViewLayoutTransitionCurve.slide.mediaTimingFunction
                                reverseBasicAnimation.duration = (duration ?? 0.3) * UIView.animationDurationFactor()
                                reverseBasicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                                reverseBasicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                reverseBasicAnimation.isRemovedOnCompletion = true
                                reverseBasicAnimation.isAdditive = true
                                if #available(iOS 15.0, *) {
                                    reverseBasicAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(UIScreen.main.maximumFramesPerSecond), maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
                                }
                                
                                animation = basicAnimation
                                reverseAnimation = reverseBasicAnimation
                            }
                    }
                    
                    if scrollToItem.displayLink {
                        self.layer.sublayerTransform = CATransform3DMakeTranslation(0.0, -offset, 0.0)
                        let offsetAnimation = ListViewAnimation(from: -offset, to: 0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: listViewAnimationCurveSystem, beginAt: timestamp, update: { [weak self] progress, currentValue in
                            if let strongSelf = self {
                                strongSelf.layer.sublayerTransform = CATransform3DMakeTranslation(0.0, currentValue, 0.0)
                                
                                if progress == 1.0 {
                                    for itemNode in temporaryPreviousNodes {
                                        itemNode.visibility = .none
                                        itemNode.removeFromSupernode()
                                        itemNode.extractedBackgroundNode?.removeFromSupernode()
                                    }
                                    for headerNode in temporaryHeaderNodes {
                                        headerNode.removeFromSupernode()
                                    }
                                }
                            }
                        })
                        self.animations.append(offsetAnimation)
                    } else {
                        animation.completion = { _ in
                            for itemNode in temporaryPreviousNodes {
                                itemNode.visibility = .none
                                itemNode.removeFromSupernode()
                                itemNode.extractedBackgroundNode?.removeFromSupernode()
                            }
                            for headerNode in temporaryHeaderNodes {
                                headerNode.removeFromSupernode()
                            }
                        }
                        self.layer.add(animation, forKey: nil)
                    }

                    for itemNode in self.itemNodes {
                        itemNode.applyAbsoluteOffset(value: CGPoint(x: 0.0, y: -offset), animationCurve: animationCurve, duration: animationDuration)
                    }
                    for itemNode in temporaryPreviousNodes {
                        itemNode.applyAbsoluteOffset(value: CGPoint(x: 0.0, y: -offset), animationCurve: animationCurve, duration: animationDuration)
                    }
                    self.didScrollWithOffset?(-offset, .animated(duration: animationDuration, curve: animationCurve), nil, self.isTrackingOrDecelerating)
                    if let verticalScrollIndicator = self.verticalScrollIndicator {
                        verticalScrollIndicator.layer.add(reverseAnimation, forKey: nil)
                    }
                }
            }
            
            self.updateItemNodesVisibilities(onlyPositive: deferredUpdateVisible)
            
            self.updateScroller(transition: headerNodesTransition.0)
            
            if let topItemOverscrollBackground = self.topItemOverscrollBackground {
                headerNodesTransition.0.animatePositionAdditive(node: topItemOverscrollBackground, offset: CGPoint(x: 0.0, y: -headerNodesTransition.2))
            }
            
            applyHeaderNodesFullTransition()
            
            self.setNeedsAnimations()
            
            self.updateVisibleContentOffset()
            
            if self.debugInfo {
                //let delta = CACurrentMediaTime() - timestamp
                //print("replayOperations \(delta * 1000.0) ms")
            }
            
            completion()
        } else {
            self.updateItemHeaders(leftInset: listInsets.left, rightInset: listInsets.right, synchronousLoad: synchronousLoads, transition: headerNodesTransition, animateInsertion: animated || !requestItemInsertionAnimationsIndices.isEmpty, animateFullTransition: animateFullTransition)
            self.updateItemNodesVisibilities(onlyPositive: deferredUpdateVisible)
            self.onContentsUpdated?(headerNodesTransition.0)
            
            applyHeaderNodesFullTransition()
            
            if animated {
                self.setNeedsAnimations()
            }
            
            self.updateScroller(transition: headerNodesTransition.0)
            
            if let topItemOverscrollBackground = self.topItemOverscrollBackground {
                headerNodesTransition.0.animatePositionAdditive(node: topItemOverscrollBackground, offset: CGPoint(x: 0.0, y: -headerNodesTransition.2))
            }
            
            if !self.useMainQueueTransactions {
                self.updateVisibleContentOffset()
            }
            
            if self.debugInfo {
                //let delta = CACurrentMediaTime() - timestamp
                //print("replayOperations \(delta * 1000.0) ms")
            }
            
            completion()
            
            if self.useMainQueueTransactions {
                self.updateVisibleContentOffset()
            }
        }
    }
    
    private func debugCheckMonotonity() {
        if self.debugInfo {
            var previousMaxY: CGFloat?
            for node in self.itemNodes {
                if let previousMaxY = previousMaxY , abs(previousMaxY - node.apparentFrame.minY) > CGFloat.ulpOfOne {
                    print("monotonity violated")
                    break
                }
                previousMaxY = node.apparentFrame.maxY
            }
        }
    }
    
    private func removeItemNodeAtIndex(_ index: Int, animateFullTransition: Bool) {
        let node = self.itemNodes[index]
        self.itemNodes.remove(at: index)
        
        if animateFullTransition {
            node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false, completion: { [weak node] _ in
                guard let node else {
                    return
                }
                node.visibility = .none
                node.removeFromSupernode()
                node.extractedBackgroundNode?.removeFromSupernode()
                node.accessoryItemNode?.removeFromSupernode()
                node.setAccessoryItemNode(nil, leftInset: self.insets.left, rightInset: self.insets.right)
                node.headerAccessoryItemNode?.removeFromSupernode()
                node.headerAccessoryItemNode = nil
            })
            node.layer.animateScale(from: 1.0, to: 0.001, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        } else {
            node.visibility = .none
            node.removeFromSupernode()
            node.extractedBackgroundNode?.removeFromSupernode()
            node.accessoryItemNode?.removeFromSupernode()
            node.setAccessoryItemNode(nil, leftInset: self.insets.left, rightInset: self.insets.right)
            node.headerAccessoryItemNode?.removeFromSupernode()
            node.headerAccessoryItemNode = nil
        }
    }

    private var nextHeaderSpaceAffinity: Int = 0

    private func assignHeaderSpaceAffinities() {
        var nextTempAffinity = 0

        var existingAffinityIdByAffinity: [Int: Int] = [:]

        for i in 0 ..< self.itemNodes.count {
            let currentItemNode = self.itemNodes[i]

            if let currentItemHeaders = currentItemNode.headers() {
                currentHeadersLoop: for currentHeader in currentItemHeaders {
                    let currentId = currentHeader.id
                    if let currentAffinity = currentItemNode.tempHeaderSpaceAffinities[currentId] {
                        if let existingAffinity = currentItemNode.headerSpaceAffinities[currentId] {
                            existingAffinityIdByAffinity[currentAffinity] = existingAffinity
                        }

                        continue currentHeadersLoop
                    }

                    let currentAffinity = nextTempAffinity
                    nextTempAffinity += 1

                    currentItemNode.tempHeaderSpaceAffinities[currentId] = currentAffinity

                    if let existingAffinity = currentItemNode.headerSpaceAffinities[currentId] {
                        existingAffinityIdByAffinity[currentAffinity] = existingAffinity
                    }

                    groupSearch: for nextIndex in (i + 1) ..< self.itemNodes.count {
                        let nextItemNode = self.itemNodes[nextIndex]

                        var containsSameHeader = false
                        if let nextHeaders = nextItemNode.headers() {
                            nextHeaderSearch: for nextHeader in nextHeaders {
                                if nextHeader.id == currentId && nextHeader.combinesWith(other: currentHeader) {
                                    containsSameHeader = true
                                    break nextHeaderSearch
                                }
                            }
                        }

                        if containsSameHeader {
                            nextItemNode.tempHeaderSpaceAffinities[currentId] = currentAffinity
                        } else {
                            break groupSearch
                        }
                    }
                }
            }
        }

        for i in 0 ..< self.itemNodes.count {
            let itemNode = self.itemNodes[i]
            for (headerId, tempAffinity) in itemNode.tempHeaderSpaceAffinities {
                let affinity: Int
                if let existing = existingAffinityIdByAffinity[tempAffinity] {
                    affinity = existing
                } else {
                    affinity = self.nextHeaderSpaceAffinity
                    existingAffinityIdByAffinity[tempAffinity] = affinity
                    self.nextHeaderSpaceAffinity += 1
                }

                itemNode.headerSpaceAffinities[headerId] = affinity
                itemNode.tempHeaderSpaceAffinities = [:]
            }
        }
    }
    
    private func updateItemHeaders(leftInset: CGFloat, rightInset: CGFloat, synchronousLoad: Bool, transition: (ContainedViewLayoutTransition, Bool, CGFloat) = (.immediate, false, 0.0), animateInsertion: Bool = false, animateFullTransition: Bool = false) {
        self.assignHeaderSpaceAffinities()

        let upperDisplayBound = self.headerInsets.top
        let lowerDisplayBound = self.visibleSize.height - self.insets.bottom
        var visibleHeaderNodes: [VisibleHeaderNodeId] = []
        
        let flashing = self.headerItemsAreFlashing()
        
        func addHeader(id: VisibleHeaderNodeId, upperBound: CGFloat, upperIndex: Int, upperBoundEdge: CGFloat, lowerBound: CGFloat, lowerIndex: Int, item: ListViewItemHeader, hasValidNodes: Bool) {
            let itemHeaderHeight: CGFloat = item.height
            
            var insertItemBelowOtherHeaders = false
            var offsetByHeaderNodeId: ListViewItemNode.HeaderId?
            var didOffsetByHeaderNode = false
            
            var headerFrame: CGRect
            let naturalY: CGFloat
            var stickLocationDistanceFactor: CGFloat = 0.0
            var stickLocationDistance: CGFloat
            switch item.stickDirection {
            case .top:
                naturalY = lowerBound
                headerFrame = CGRect(origin: CGPoint(x: 0.0, y: min(max(upperDisplayBound, upperBound), lowerBound - itemHeaderHeight)), size: CGSize(width: self.visibleSize.width, height: itemHeaderHeight))
                stickLocationDistance = headerFrame.minY - upperBound
                stickLocationDistanceFactor = max(0.0, min(1.0, stickLocationDistance / itemHeaderHeight))
            case .topEdge:
                naturalY = lowerBound
                headerFrame = CGRect(origin: CGPoint(x: 0.0, y: min(max(upperDisplayBound, upperBoundEdge - itemHeaderHeight), lowerBound - itemHeaderHeight)), size: CGSize(width: self.visibleSize.width, height: itemHeaderHeight))
                stickLocationDistance = headerFrame.minY - upperBoundEdge + itemHeaderHeight
                stickLocationDistanceFactor = max(0.0, min(1.0, stickLocationDistance / itemHeaderHeight))
            case .bottom:
                naturalY = lowerBound
                headerFrame = CGRect(origin: CGPoint(x: 0.0, y: max(upperBound, min(lowerBound, lowerDisplayBound) - itemHeaderHeight)), size: CGSize(width: self.visibleSize.width, height: itemHeaderHeight))
                stickLocationDistance = lowerBound - headerFrame.maxY
                stickLocationDistanceFactor = max(0.0, min(1.0, stickLocationDistance / itemHeaderHeight))
                
                if let stackingId = item.stackingId {
                    insertItemBelowOtherHeaders = true
                    
                    var naturalOverlapLowerBound: CGFloat = naturalY
                    do {
                        for (otherId, otherNode) in self.itemHeaderNodes {
                            if otherId.id.space == stackingId.space {
                                if !visibleHeaderNodes.contains(otherId) {
                                    continue
                                }
                                if let otherNaturalOriginY = otherNode.naturalOriginY, otherNaturalOriginY == naturalY {
                                    naturalOverlapLowerBound = otherNaturalOriginY - 7.0 - 20.0
                                    break
                                }
                            }
                        }
                    }
                    
                    for _ in 0 ..< 2 {
                        var mostOverlap: (CGRect, CGFloat, ListViewItemHeaderNode)?
                        for (otherId, otherNode) in self.itemHeaderNodes {
                            if otherId.id.space == stackingId.space {
                                if !visibleHeaderNodes.contains(otherId) {
                                    continue
                                }
                                if headerFrame.intersects(otherNode.frame) {
                                    let intersectionHeight = headerFrame.intersection(otherNode.frame).height
                                    if intersectionHeight > 0.0 {
                                        if let (currentOverlapFrame, _, _) = mostOverlap {
                                            if headerFrame.minY < currentOverlapFrame.minY {
                                                mostOverlap = (otherNode.frame, intersectionHeight, otherNode)
                                            }
                                        } else {
                                            mostOverlap = (otherNode.frame, intersectionHeight, otherNode)
                                        }
                                    }
                                }
                            }
                        }
                        if let (mostOverlap, _, otherNode) = mostOverlap {
                            let originalY = headerFrame.origin.y
                            headerFrame.origin.y = min(headerFrame.origin.y, mostOverlap.minY - 7.0 - 20.0)
                            headerFrame.origin.y = max(upperBound, headerFrame.origin.y)
                            offsetByHeaderNodeId = otherNode.item?.id
                            didOffsetByHeaderNode = originalY != headerFrame.origin.y
                        }
                    }
                    
                    stickLocationDistance = naturalOverlapLowerBound - headerFrame.maxY
                    stickLocationDistanceFactor = max(0.0, min(1.0, stickLocationDistance / itemHeaderHeight))
                }
            }
            
            visibleHeaderNodes.append(id)
            
            let initialHeaderNodeAlpha = self.itemHeaderNodesAlpha
            let headerNode: ListViewItemHeaderNode
            if let current = self.itemHeaderNodes[id] {
                headerNode = current
                switch transition.0 {
                    case .immediate:
                        let previousFrame = headerNode.frame
                        headerNode.updateFrame(headerFrame, within: self.visibleSize)
                        if headerNode.offsetByHeaderNodeId != nil && offsetByHeaderNodeId != nil && headerNode.offsetByHeaderNodeId != offsetByHeaderNodeId {
                            let _ = didOffsetByHeaderNode
                            if !previousFrame.isEmpty {
                                ContainedViewLayoutTransition.animated(duration: 0.35, curve: .spring).animatePositionAdditive(node: headerNode, offset: CGPoint(x: 0.0, y: previousFrame.minY - headerFrame.minY))
                            }
                        }
                    case let .animated(duration, curve):
                        let previousFrame = headerNode.frame
                        headerNode.updateFrame(headerFrame, within: self.visibleSize)
                        var offsetY = headerFrame.minY - previousFrame.minY + transition.2
                        var offsetX: CGFloat = 0.0
                        if headerNode.isRotated {
                            offsetY = -offsetY
                            offsetX = headerFrame.width - previousFrame.width
                        }
                        let offset = CGPoint(x: offsetX, y: offsetY)
                        switch curve {
                            case .linear:
                                headerNode.layer.animateBoundsOriginAdditive(from: offset, to: CGPoint(), duration: duration, mediaTimingFunction: CAMediaTimingFunction(name: CAMediaTimingFunctionName.linear))
                            case .spring, .customSpring:
                                transition.0.animateOffsetAdditive(node: headerNode, offset: offset)
                            case let .custom(p1, p2, p3, p4):
                                headerNode.layer.animateBoundsOriginAdditive(from: offset, to: CGPoint(), duration: duration, mediaTimingFunction: CAMediaTimingFunction(controlPoints: p1, p2, p3, p4))
                            case .easeInOut:
                                if transition.1 {
                                    headerNode.layer.animateBoundsOriginAdditive(from: offset, to: CGPoint(), duration: duration, mediaTimingFunction: ContainedViewLayoutTransitionCurve.slide.mediaTimingFunction)
                                } else {
                                    headerNode.layer.animateBoundsOriginAdditive(from: offset, to: CGPoint(), duration: duration, mediaTimingFunction: CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut))
                                }
                        }
                }
                
                if headerNode.item !== item {
                    item.updateNode(headerNode, previous: nil, next: nil)
                    headerNode.item = item
                }
                headerNode.updateLayoutInternal(size: headerFrame.size, leftInset: leftInset, rightInset: rightInset, transition: animateInsertion ? .immediate : transition.0)
                headerNode.updateInternalStickLocationDistanceFactor(stickLocationDistanceFactor, animated: true)
                headerNode.internalStickLocationDistance = stickLocationDistance
                if !hasValidNodes && !headerNode.alpha.isZero {
                    if animateInsertion {
                        headerNode.animateRemoved(duration: 0.2)
                    }
                } else if hasValidNodes && headerNode.alpha.isZero {
                    headerNode.alpha = initialHeaderNodeAlpha
                    if animateInsertion {
                        headerNode.animateAdded(duration: 0.2)
                    }
                }
                headerNode.updateStickDistanceFactor(stickLocationDistanceFactor, distance: stickLocationDistance, transition: transition.0)
            } else {
                headerNode = item.node(synchronousLoad: synchronousLoad)
                headerNode.alpha = initialHeaderNodeAlpha
                if headerNode.item !== item {
                    item.updateNode(headerNode, previous: nil, next: nil)
                    headerNode.item = item
                }
                headerNode.updateFlashingOnScrolling(flashing, animated: false)
                headerNode.frame = headerFrame
                headerNode.updateLayoutInternal(size: headerFrame.size, leftInset: leftInset, rightInset: rightInset, transition: .immediate)
                headerNode.updateInternalStickLocationDistanceFactor(stickLocationDistanceFactor, animated: false)
                self.itemHeaderNodes[id] = headerNode
                if insertItemBelowOtherHeaders {
                    var lowestHeaderNode: ASDisplayNode?
                    var lowestHeaderNodeIndex: Int?
                    for (_, headerNode) in self.itemHeaderNodes {
                        if let index = self.view.subviews.firstIndex(of: headerNode.view) {
                            if lowestHeaderNodeIndex == nil || index < lowestHeaderNodeIndex! {
                                lowestHeaderNodeIndex = index
                                lowestHeaderNode = headerNode
                            }
                        }
                    }
                    if let lowestHeaderNode {
                        self.insertSubnode(headerNode, belowSubnode: lowestHeaderNode)
                    } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                        self.insertSubnode(headerNode, belowSubnode: verticalScrollIndicator)
                    } else {
                        self.addSubnode(headerNode)
                    }
                } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                    self.insertSubnode(headerNode, belowSubnode: verticalScrollIndicator)
                } else {
                    self.addSubnode(headerNode)
                }
                if animateInsertion {
                    headerNode.alpha = initialHeaderNodeAlpha
                    headerNode.animateAdded(duration: 0.2)
                }
                headerNode.updateStickDistanceFactor(stickLocationDistanceFactor, distance: stickLocationDistance, transition: .immediate)
            }
            headerNode.offsetByHeaderNodeId = offsetByHeaderNodeId
            headerNode.naturalOriginY = naturalY
            var maxIntersectionHeight: (CGFloat, Int)?
            for i in upperIndex ... lowerIndex {
                let itemNode = self.itemNodes[i]
                let itemNodeFrame = itemNode.apparentFrame
                let intersectionHeight: CGFloat = itemNodeFrame.intersection(headerFrame).height

                if let (currentMaxIntersectionHeight, _) = maxIntersectionHeight {
                    if currentMaxIntersectionHeight < intersectionHeight {
                        maxIntersectionHeight = (intersectionHeight, i)
                    }
                } else {
                    maxIntersectionHeight = (intersectionHeight, i)
                }
            }
            if let (_, i) = maxIntersectionHeight {
                let itemNode = self.itemNodes[i]
                let itemNodeFrame = itemNode.apparentFrame

                if itemNodeFrame.intersects(headerFrame) {
                    var updated = false
                    if let previousItemNode = headerNode.attachedToItemNode {
                        if previousItemNode !== itemNode {
                            previousItemNode.attachedHeaderNodes.removeAll(where: { $0 === headerNode })
                            updated = true
                        }
                    } else {
                        updated = true
                    }
                    if updated {
                        headerNode.attachedToItemNode = itemNode
                        itemNode.attachedHeaderNodes.append(headerNode)
                        itemNode.attachedHeaderNodesUpdated()
                    }
                }
            } else {
                if let previousItemNode = headerNode.attachedToItemNode {
                    previousItemNode.attachedHeaderNodes.removeAll(where: { $0 === headerNode })
                    headerNode.attachedToItemNode = nil
                }
            }
        }

        var previousHeaderBySpace: [AnyHashable: (id: VisibleHeaderNodeId, upperBound: CGFloat, upperBoundIndex: Int, upperBoundEdge: CGFloat, lowerBound: CGFloat, lowerBoundIndex: Int, item: ListViewItemHeader, hasValidNodes: Bool)] = [:]
        
        for phase in 0 ..< 2 {
            for i in 0 ..< self.itemNodes.count {
                let itemNode = self.itemNodes[i]
                let itemFrame = itemNode.apparentFrame
                let itemTopInset = itemNode.insets.top
                var validItemHeaderSpaces: [AnyHashable] = []
                if let itemHeaders = itemNode.headers() {
                    outerItemHeaders: for itemHeader in itemHeaders {
                        if phase == 0 {
                            if itemHeader.stackingId != nil {
                                continue outerItemHeaders
                            }
                        } else {
                            if itemHeader.stackingId == nil {
                                continue outerItemHeaders
                            }
                        }
                        
                        guard let affinity = itemNode.headerSpaceAffinities[itemHeader.id] else {
                            assertionFailure()
                            continue
                        }
                        
                        let headerId = VisibleHeaderNodeId(id: itemHeader.id, affinity: affinity)
                        
                        validItemHeaderSpaces.append(itemHeader.id.space)
                        
                        var itemMaxY: CGFloat
                        if itemHeader.stickOverInsets {
                            itemMaxY = itemFrame.maxY
                        } else {
                            itemMaxY = itemFrame.maxY - (self.rotated ? itemNode.insets.top : itemNode.insets.bottom)
                        }
                        
                        if let (previousHeaderId, previousUpperBound, previousUpperIndex, previousUpperBoundEdge, previousLowerBound, previousLowerIndex, previousHeaderItem, hasValidNodes) = previousHeaderBySpace[itemHeader.id.space] {
                            if previousHeaderId == headerId {
                                previousHeaderBySpace[itemHeader.id.space] = (previousHeaderId, previousUpperBound, previousUpperIndex, previousUpperBoundEdge, itemMaxY, i, previousHeaderItem, hasValidNodes || itemNode.index != nil)
                            } else {
                                addHeader(id: previousHeaderId, upperBound: previousUpperBound, upperIndex: previousUpperIndex, upperBoundEdge: previousUpperBoundEdge, lowerBound: previousLowerBound, lowerIndex: previousLowerIndex, item: previousHeaderItem, hasValidNodes: hasValidNodes)
                                
                                previousHeaderBySpace[itemHeader.id.space] = (headerId, itemFrame.minY, i, itemFrame.minY + itemTopInset, itemMaxY, i, itemHeader, itemNode.index != nil)
                            }
                        } else {
                            previousHeaderBySpace[itemHeader.id.space] = (headerId, itemFrame.minY, i, itemFrame.minY + itemTopInset, itemMaxY, i, itemHeader, itemNode.index != nil)
                        }
                    }
                }
                
                for (space, previousHeader) in previousHeaderBySpace {
                    if validItemHeaderSpaces.contains(space) {
                        continue
                    }
                    
                    let (previousHeaderId, previousUpperBound, previousUpperIndex, previousUpperBoundEdge, previousLowerBound, previousLowerIndex, previousHeaderItem, hasValidNodes) = previousHeader
                    
                    addHeader(id: previousHeaderId, upperBound: previousUpperBound, upperIndex: previousUpperIndex, upperBoundEdge: previousUpperBoundEdge, lowerBound: previousLowerBound, lowerIndex: previousLowerIndex, item: previousHeaderItem, hasValidNodes: hasValidNodes)
                    
                    previousHeaderBySpace.removeValue(forKey: space)
                }
            }
        }

        for (space, previousHeader) in previousHeaderBySpace {
            let (previousHeaderId, previousUpperBound, previousUpperIndex, previousUpperBoundEdge, previousLowerBound, previousLowerIndex, previousHeaderItem, hasValidNodes) = previousHeader

            addHeader(id: previousHeaderId, upperBound: previousUpperBound, upperIndex: previousUpperIndex, upperBoundEdge: previousUpperBoundEdge, lowerBound: previousLowerBound, lowerIndex: previousLowerIndex, item: previousHeaderItem, hasValidNodes: hasValidNodes)

            previousHeaderBySpace.removeValue(forKey: space)
        }
        
        let currentIds = Set(self.itemHeaderNodes.keys)
        for id in currentIds.subtracting(Set(visibleHeaderNodes)) {
            if let headerNode = self.itemHeaderNodes.removeValue(forKey: id) {
                if animateFullTransition {
                    headerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false, completion: { [weak headerNode] _ in
                        guard let headerNode else {
                            return
                        }
                        headerNode.removeFromSupernode()
                    })
                    headerNode.layer.animateScale(from: 1.0, to: 0.001, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
                } else {
                    headerNode.removeFromSupernode()
                }
            }
        }
    }
    
    private func updateItemNodesVisibilities(onlyPositive: Bool) {
        let insets: UIEdgeInsets = self.visualInsets ?? self.insets
        let visibilityRect = CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height - insets.top - insets.bottom))
        for itemNode in self.itemNodes {
            let itemFrame = itemNode.apparentFrame
            var visibility: ListViewItemNodeVisibility = .none
            if visibilityRect.intersects(itemFrame) {
                let itemContentFrame = itemNode.apparentContentFrame
                let intersection = itemContentFrame.intersection(visibilityRect)
                let fraction = intersection.height / itemContentFrame.height
                
                let subRect = visibilityRect.intersection(itemFrame).offsetBy(dx: 0.0, dy: -itemFrame.minY)
                
                visibility = .visible(fraction, subRect)
            }
            var updateVisibility = false
            if !onlyPositive {
                updateVisibility = true
            }
            if case .visible = visibility {
                updateVisibility = true
            }
            if updateVisibility {
                if visibility != itemNode.visibility {
                    itemNode.visibility = visibility
                }
            }
        }
    }
    
    private func updateAccessoryNodes(transition: ContainedViewLayoutTransition, synchronous: Bool, currentTimestamp: Double, leftInset: CGFloat, rightInset: CGFloat) {
        var totalVisibleHeight: CGFloat = 0.0
        var index = -1
        let count = self.itemNodes.count
        for itemNode in self.itemNodes {
            index += 1
            totalVisibleHeight += itemNode.apparentHeight
            
            guard let itemNodeIndex = itemNode.index else {
                continue
            }
            
            if let accessoryItem = self.items[itemNodeIndex].accessoryItem {
                let previousItem: ListViewItem? = itemNodeIndex == 0 ? nil : self.items[itemNodeIndex - 1]
                let previousAccessoryItem = previousItem?.accessoryItem
                
                if (previousAccessoryItem == nil || !previousAccessoryItem!.isEqualToItem(accessoryItem)) {
                    if itemNode.accessoryItemNode == nil {
                        var didStealAccessoryNode = false
                        if index != count - 1 {
                            for i in index + 1 ..< count {
                                let nextItemNode = self.itemNodes[i]
                                if let nextItemNodeIndex = nextItemNode.index {
                                    let nextItem = self.items[nextItemNodeIndex]
                                    if let nextAccessoryItem = nextItem.accessoryItem , nextAccessoryItem.isEqualToItem(accessoryItem) {
                                        if let nextAccessoryItemNode = nextItemNode.accessoryItemNode {
                                            didStealAccessoryNode = true
                                            
                                            var previousAccessoryItemNodeOrigin = nextAccessoryItemNode.frame.origin
                                            let previousParentOrigin = nextItemNode.frame.origin
                                            previousAccessoryItemNodeOrigin.x += previousParentOrigin.x
                                            previousAccessoryItemNodeOrigin.y += previousParentOrigin.y
                                            previousAccessoryItemNodeOrigin.y -= nextItemNode.bounds.origin.y
                                            previousAccessoryItemNodeOrigin.y -= nextAccessoryItemNode.transitionOffset.y
                                            nextAccessoryItemNode.transitionOffset = CGPoint()
                                            
                                            nextAccessoryItemNode.removeFromSupernode()
                                            itemNode.addAccessoryItemNode(nextAccessoryItemNode)
                                            
                                            itemNode.setAccessoryItemNode(nextAccessoryItemNode, leftInset: leftInset, rightInset: rightInset)
                                            self.itemNodes[i].setAccessoryItemNode(nil, leftInset: leftInset, rightInset: rightInset)
                                            
                                            var updatedAccessoryItemNodeOrigin = nextAccessoryItemNode.frame.origin
                                            let updatedParentOrigin = itemNode.apparentFrame.origin
                                            updatedAccessoryItemNodeOrigin.x += updatedParentOrigin.x
                                            updatedAccessoryItemNodeOrigin.y += updatedParentOrigin.y
                                            updatedAccessoryItemNodeOrigin.y -= itemNode.bounds.origin.y
                                            
                                            let deltaHeight = itemNode.frame.size.height - nextItemNode.frame.size.height
                                            nextAccessoryItemNode.animateTransitionOffset(CGPoint(x: 0.0, y: updatedAccessoryItemNodeOrigin.y - previousAccessoryItemNodeOrigin.y - deltaHeight), beginAt: currentTimestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: listViewAnimationCurveSystem)
                                            
                                        }
                                    } else {
                                        break
                                    }
                                }
                            }
                        }
                        
                        if !didStealAccessoryNode {
                            let accessoryNode = accessoryItem.node(synchronous: synchronous)
                            itemNode.addAccessoryItemNode(accessoryNode)
                            itemNode.setAccessoryItemNode(accessoryNode, leftInset: leftInset, rightInset: rightInset)
                        }
                    }
                } else {
                    itemNode.accessoryItemNode?.removeFromSupernode()
                    itemNode.setAccessoryItemNode(nil, leftInset: leftInset, rightInset: rightInset)
                }
            }
            
            if let headerAccessoryItem = self.items[itemNodeIndex].headerAccessoryItem {
                let previousItem: ListViewItem? = itemNodeIndex == 0 ? nil : self.items[itemNodeIndex - 1]
                let previousHeaderAccessoryItem = previousItem?.headerAccessoryItem
                
                if (previousHeaderAccessoryItem == nil || !previousHeaderAccessoryItem!.isEqualToItem(headerAccessoryItem)) {
                    if itemNode.headerAccessoryItemNode == nil {
                        var didStealHeaderAccessoryNode = false
                        if index != count - 1 {
                            for i in index + 1 ..< count {
                                let nextItemNode = self.itemNodes[i]
                                if let nextItemNodeIndex = nextItemNode.index {
                                    let nextItem = self.items[nextItemNodeIndex]
                                    if let nextHeaderAccessoryItem = nextItem.headerAccessoryItem , nextHeaderAccessoryItem.isEqualToItem(headerAccessoryItem) {
                                        if let nextHeaderAccessoryItemNode = nextItemNode.headerAccessoryItemNode {
                                            didStealHeaderAccessoryNode = true
                                            
                                            var previousHeaderAccessoryItemNodeOrigin = nextHeaderAccessoryItemNode.frame.origin
                                            let previousParentOrigin = nextItemNode.frame.origin
                                            previousHeaderAccessoryItemNodeOrigin.x += previousParentOrigin.x
                                            previousHeaderAccessoryItemNodeOrigin.y += previousParentOrigin.y
                                            previousHeaderAccessoryItemNodeOrigin.y -= nextItemNode.bounds.origin.y
                                            previousHeaderAccessoryItemNodeOrigin.y -= nextHeaderAccessoryItemNode.transitionOffset.y
                                            nextHeaderAccessoryItemNode.transitionOffset = CGPoint()
                                            
                                            nextHeaderAccessoryItemNode.removeFromSupernode()
                                            itemNode.addSubnode(nextHeaderAccessoryItemNode)
                                            itemNode.headerAccessoryItemNode = nextHeaderAccessoryItemNode
                                            self.itemNodes[i].headerAccessoryItemNode = nil
                                            
                                            var updatedHeaderAccessoryItemNodeOrigin = nextHeaderAccessoryItemNode.frame.origin
                                            let updatedParentOrigin = itemNode.frame.origin
                                            updatedHeaderAccessoryItemNodeOrigin.x += updatedParentOrigin.x
                                            updatedHeaderAccessoryItemNodeOrigin.y += updatedParentOrigin.y
                                            updatedHeaderAccessoryItemNodeOrigin.y -= itemNode.bounds.origin.y
                                            
                                            let deltaHeight = itemNode.frame.size.height - nextItemNode.frame.size.height
                                            
                                            nextHeaderAccessoryItemNode.animateTransitionOffset(CGPoint(x: 0.0, y: updatedHeaderAccessoryItemNodeOrigin.y - previousHeaderAccessoryItemNodeOrigin.y - deltaHeight), beginAt: currentTimestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: listViewAnimationCurveSystem)
                                        }
                                    } else {
                                        break
                                    }
                                }
                            }
                        }
                        
                        if !didStealHeaderAccessoryNode {
                            let headerAccessoryNode = headerAccessoryItem.node(synchronous: synchronous)
                            itemNode.addSubnode(headerAccessoryNode)
                            itemNode.headerAccessoryItemNode = headerAccessoryNode
                        }
                    }
                } else {
                    itemNode.headerAccessoryItemNode?.removeFromSupernode()
                    itemNode.headerAccessoryItemNode = nil
                }
            }
        }
        
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            var topIndexAndBoundary: (Int, CGFloat, CGFloat)?
            var bottomIndexAndBoundary: (Int, CGFloat, CGFloat)?
            for itemNode in self.itemNodes {
                if itemNode.apparentFrame.maxY >= self.insets.top, let index = itemNode.index {
                    topIndexAndBoundary = (index, itemNode.apparentFrame.minY, itemNode.apparentFrame.height)
                    break
                }
            }
            for itemNode in self.itemNodes.reversed() {
                if itemNode.apparentFrame.minY <= self.visibleSize.height - self.insets.bottom, let index = itemNode.index {
                    bottomIndexAndBoundary = (index, itemNode.apparentFrame.maxY, itemNode.apparentFrame.height)
                    break
                }
            }

            var scrollingIndicatorStateValue: ScrollingIndicatorState?
            if let topIndexAndBoundaryValue = topIndexAndBoundary, let bottomIndexAndBoundaryValue = bottomIndexAndBoundary {
                let scrollingIndicatorState = ScrollingIndicatorState(
                    insets: self.insets,
                    topItem: ScrollingIndicatorState.Item(
                        index: topIndexAndBoundaryValue.0,
                        offset: topIndexAndBoundaryValue.1,
                        height: topIndexAndBoundaryValue.2
                    ),
                    bottomItem: ScrollingIndicatorState.Item(
                        index: bottomIndexAndBoundaryValue.0,
                        offset: bottomIndexAndBoundaryValue.1,
                        height: bottomIndexAndBoundaryValue.2
                    ),
                    itemCount: self.items.count
                )
                scrollingIndicatorStateValue = scrollingIndicatorState

                let averageRangeItemHeight: CGFloat = 44.0
                
                var upperItemsHeight = floor(averageRangeItemHeight * CGFloat(scrollingIndicatorState.topItem.index))
                var approximateContentHeight = CGFloat(scrollingIndicatorState.itemCount) * averageRangeItemHeight
                if scrollingIndicatorState.topItem.index >= 0 && self.items[scrollingIndicatorState.topItem.index].approximateHeight.isZero {
                    upperItemsHeight -= averageRangeItemHeight
                    approximateContentHeight -= averageRangeItemHeight
                }
                
                var convertedTopBoundary: CGFloat
                if scrollingIndicatorState.topItem.offset < self.insets.top {
                    convertedTopBoundary = (scrollingIndicatorState.topItem.offset - scrollingIndicatorState.insets.top) * averageRangeItemHeight / scrollingIndicatorState.topItem.height
                } else {
                    convertedTopBoundary = scrollingIndicatorState.topItem.offset - scrollingIndicatorState.insets.top
                }
                convertedTopBoundary -= upperItemsHeight
                
                let approximateOffset = -convertedTopBoundary
                
                var convertedBottomBoundary: CGFloat = 0.0
                if scrollingIndicatorState.bottomItem.offset > self.visibleSize.height - self.insets.bottom {
                    convertedBottomBoundary = ((self.visibleSize.height - scrollingIndicatorState.insets.bottom) - scrollingIndicatorState.bottomItem.offset) * averageRangeItemHeight / scrollingIndicatorState.bottomItem.height
                } else {
                    convertedBottomBoundary = (self.visibleSize.height - scrollingIndicatorState.insets.bottom) - scrollingIndicatorState.bottomItem.offset
                }
                convertedBottomBoundary += CGFloat(scrollingIndicatorState.bottomItem.index + 1) * averageRangeItemHeight
                
                let approximateVisibleHeight = max(0.0, convertedBottomBoundary - approximateOffset)
                
                let approximateScrollingProgress = approximateOffset / (approximateContentHeight - approximateVisibleHeight)
                
                let indicatorSideInset: CGFloat = 3.0
                var indicatorTopInset: CGFloat = 3.0
                if self.verticalScrollIndicatorFollowsOverscroll {
                    if scrollingIndicatorState.topItem.index == 0 {
                        indicatorTopInset = max(scrollingIndicatorState.topItem.offset + 3.0 - self.insets.top, 3.0)
                    }
                }
                let indicatorBottomInset: CGFloat = 3.0
                let minIndicatorContentHeight: CGFloat = 12.0
                let minIndicatorHeight: CGFloat = 6.0
                
                let visibleHeightWithoutIndicatorInsets = self.visibleSize.height - self.scrollIndicatorInsets.top - self.scrollIndicatorInsets.bottom - indicatorTopInset - indicatorBottomInset
                let indicatorHeight: CGFloat
                if approximateContentHeight <= 0 {
                    indicatorHeight = 0.0
                } else {
                    indicatorHeight = max(minIndicatorContentHeight, floor(visibleHeightWithoutIndicatorInsets * (self.visibleSize.height - scrollingIndicatorState.insets.top - scrollingIndicatorState.insets.bottom) / approximateContentHeight))
                }
                
                let upperBound = self.scrollIndicatorInsets.top + indicatorTopInset
                let lowerBound = self.visibleSize.height - self.scrollIndicatorInsets.bottom - indicatorTopInset - indicatorBottomInset - indicatorHeight
                
                let indicatorOffset = ceilToScreenPixels(upperBound * (1.0 - approximateScrollingProgress) + lowerBound * approximateScrollingProgress)
                
                var indicatorFrame = CGRect(origin: CGPoint(x: self.rotated ? indicatorSideInset : (self.visibleSize.width - 3.0 - indicatorSideInset), y: indicatorOffset), size: CGSize(width: 3.0, height: indicatorHeight))
                if indicatorFrame.minY < self.scrollIndicatorInsets.top + indicatorTopInset {
                    indicatorFrame.size.height -= self.scrollIndicatorInsets.top + indicatorTopInset - indicatorFrame.minY
                    indicatorFrame.origin.y = self.scrollIndicatorInsets.top + indicatorTopInset
                    indicatorFrame.size.height = max(minIndicatorHeight, indicatorFrame.height)
                }
                if indicatorFrame.maxY > self.visibleSize.height - (self.scrollIndicatorInsets.bottom + indicatorTopInset + indicatorBottomInset) {
                    indicatorFrame.size.height -= indicatorFrame.maxY - (self.visibleSize.height - (self.scrollIndicatorInsets.bottom + indicatorTopInset))
                    indicatorFrame.size.height = max(minIndicatorHeight, indicatorFrame.height)
                    indicatorFrame.origin.y = self.visibleSize.height - (self.scrollIndicatorInsets.bottom + indicatorBottomInset) - indicatorFrame.height
                }
                
                if indicatorFrame.origin.y.isNaN {
                   indicatorFrame.origin.y = indicatorTopInset
                }
                
                if indicatorHeight >= visibleHeightWithoutIndicatorInsets {
                    verticalScrollIndicator.isHidden = true
                    verticalScrollIndicator.frame = indicatorFrame
                } else {
                    if verticalScrollIndicator.isHidden {
                        verticalScrollIndicator.isHidden = false
                        verticalScrollIndicator.frame = indicatorFrame
                    } else {
                        verticalScrollIndicator.frame = indicatorFrame
                    }
                }
            } else {
                verticalScrollIndicator.isHidden = true
            }

            self.updateScrollingIndicator?(scrollingIndicatorStateValue, transition)
        }
    }
    
    private func enqueueUpdateVisibleItems(synchronous: Bool) {
        if !self.enqueuedUpdateVisibleItems {
            self.enqueuedUpdateVisibleItems = true
            
            self.transactionQueue.addTransaction({ [weak self] completion in
                if let strongSelf = self {
                    strongSelf.transactionOffset = 0.0
                    strongSelf.updateVisibleItemsTransaction(synchronous: synchronous, completion: {
                        var repeatUpdate = false
                        if let strongSelf = self {
                            repeatUpdate = abs(strongSelf.transactionOffset) > 0.00001
                            strongSelf.transactionOffset = 0.0
                            strongSelf.enqueuedUpdateVisibleItems = false
                        }
                        
                        completion()
                    
                        if repeatUpdate {
                            strongSelf.enqueueUpdateVisibleItems(synchronous: false)
                        }
                    })
                }
            })
        }
    }
    
    private func updateVisibleItemsTransaction(synchronous: Bool, completion: @escaping () -> Void) {
        if self.items.count == 0 && self.itemNodes.count == 0 {
            completion()
            return
        }
        var i = 0
        while i < self.itemNodes.count {
            let node = self.itemNodes[i]
            if node.index == nil && node.apparentHeight <= CGFloat.ulpOfOne {
                self.removeItemNodeAtIndex(i, animateFullTransition: false)
            } else {
                i += 1
            }
        }
        
        let state = self.currentState()
        
        let begin: () -> Void = {
            self.fillMissingNodes(synchronous: synchronous, synchronousLoads: false, animated: false, customAnimationTransition: nil, inputAnimatedInsertIndices: [], insertDirectionHints: [:], inputState: state, inputPreviousNodes: [:], inputOperations: []) { state, operations in
                var updatedState = state
                var updatedOperations = operations
                updatedState.removeInvisibleNodes(&updatedOperations)
                if synchronous {
                    self.replayOperations(animated: false, animateAlpha: false, animateCrossfade: false, animateFullTransition: false, customAnimationTransition: nil, synchronous: false, synchronousLoads: false, animateTopItemVerticalOrigin: false, operations: updatedOperations, requestItemInsertionAnimationsIndices: Set(), scrollToItem: nil, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemIndex: nil, updateOpaqueState: nil, completion: completion)
                } else {
                    self.dispatchOnVSync {
                        self.replayOperations(animated: false, animateAlpha: false, animateCrossfade: false, animateFullTransition: false, customAnimationTransition: nil, synchronous: false, synchronousLoads: false, animateTopItemVerticalOrigin: false, operations: updatedOperations, requestItemInsertionAnimationsIndices: Set(), scrollToItem: nil, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemIndex: nil, updateOpaqueState: nil, completion: completion)
                    }
                }
            }
        }
        if synchronous {
            begin()
        } else {
            self.async {
                begin()
            }
        }
    }
    
    public func updateVisibleItemRange(force: Bool = false) {
        let currentRange = self.immediateDisplayedItemRange()
        
        if currentRange != self.internalDisplayedItemRange || force {
            self.displayedItemRange = currentRange
            self.internalDisplayedItemRange = currentRange
            self.displayedItemRangeChanged(currentRange, self.opaqueTransactionState)
        }
    }
    
    private func immediateDisplayedItemRange() -> ListViewDisplayedItemRange {
        var loadedRange: ListViewItemRange?
        var visibleRange: ListViewVisibleItemRange?
        if self.itemNodes.count != 0 {
            var firstIndex: (nodeIndex: Int, index: Int)?
            var lastIndex: (nodeIndex: Int, index: Int)?
            
            var i = 0
            while i < self.itemNodes.count {
                if let index = self.itemNodes[i].index {
                    firstIndex = (i, index)
                    break
                }
                i += 1
            }
            i = self.itemNodes.count - 1
            while i >= 0 {
                if let index = self.itemNodes[i].index {
                    lastIndex = (i, index)
                    break
                }
                i -= 1
            }
            if let firstIndex = firstIndex, let lastIndex = lastIndex {
                var firstVisibleIndex: (Int, Bool)?
                for i in firstIndex.nodeIndex ... lastIndex.nodeIndex {
                    if let index = self.itemNodes[i].index {
                        let frame = self.itemNodes[i].apparentFrame
                        if frame.maxY >= self.insets.top && frame.minY < self.visibleSize.height + self.insets.bottom {
                            firstVisibleIndex = (index, frame.minY >= self.insets.top - 10.0)
                            break
                        }
                    }
                }
                
                if let firstVisibleIndex = firstVisibleIndex {
                    var lastVisibleIndex: Int?
                    for i in (firstIndex.nodeIndex ... lastIndex.nodeIndex).reversed() {
                        if let index = self.itemNodes[i].index {
                            let frame = self.itemNodes[i].apparentFrame
                            if frame.maxY >= self.insets.top && frame.minY < self.visibleSize.height - self.insets.bottom {
                                lastVisibleIndex = index
                                break
                            }
                        }
                    }
                    
                    if let lastVisibleIndex = lastVisibleIndex {
                        visibleRange = ListViewVisibleItemRange(firstIndex: firstVisibleIndex.0, firstIndexFullyVisible: firstVisibleIndex.1, lastIndex: lastVisibleIndex)
                    }
                }
                
                loadedRange = ListViewItemRange(firstIndex: firstIndex.index, lastIndex: lastIndex.index)
            }
        }
        
        return ListViewDisplayedItemRange(loadedRange: loadedRange, visibleRange: visibleRange)
    }
    
    private func updateAnimations() {
        self.inVSync = true
        let actionsForVSync = self.actionsForVSync
        self.actionsForVSync.removeAll()
        for action in actionsForVSync {
            action()
        }
        self.inVSync = false
        
        let timestamp: Double = CACurrentMediaTime()
        
        var continueAnimations = false
        
        if !self.actionsForVSync.isEmpty {
            continueAnimations = true
        }
        
        var i = 0
        var animationCount = self.animations.count
        while i < animationCount {
            let animation = self.animations[i]
            animation.applyAt(timestamp)
            
            if animation.completeAt(timestamp) {
                self.animations.remove(at: i)
                animationCount -= 1
                i -= 1
            } else {
                continueAnimations = true
            }
            
            i += 1
        }
        
        var offsetRanges = OffsetRanges()
        
        var scrollingForReorder = false
        if self.autoScrollWhenReordering, let reorderOffset = self.reorderNode?.currentOffset(), !self.itemNodes.isEmpty {
            let effectiveInsets = self.visualInsets ?? self.insets
            
            var offset: CGFloat = 6.0
            if let reorderScrollStartTimestamp = self.reorderScrollStartTimestamp, reorderScrollStartTimestamp + 2.0 < timestamp {
                offset *= 1.5
            }
            if reorderOffset < effectiveInsets.top + 10.0 {
                if self.itemNodes[0].apparentFrame.minY < effectiveInsets.top {
                    continueAnimations = true
                    offsetRanges.offset(IndexRange(first: 0, last: Int.max), offset: offset)
                    scrollingForReorder = true
                }
            } else if reorderOffset > self.visibleSize.height - effectiveInsets.bottom - 10.0 {
                if self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY > self.visibleSize.height - effectiveInsets.bottom {
                    continueAnimations = true
                    if self.reorderScrollStartTimestamp == nil {
                        self.reorderScrollStartTimestamp = timestamp
                    }
                    offsetRanges.offset(IndexRange(first: 0, last: Int.max), offset: -offset)
                    scrollingForReorder = true
                }
            }
        }
        if scrollingForReorder {
            if self.reorderScrollStartTimestamp == nil {
                self.reorderScrollStartTimestamp = timestamp
            }
        } else {
            self.reorderScrollStartTimestamp = nil
        }
        
        var requestUpdateVisibleItems = false
        var index = 0
        while index < self.itemNodes.count {
            let itemNode = self.itemNodes[index]
            
            let previousApparentHeight = itemNode.apparentHeight
            var invertOffsetDirection = false
            if itemNode.animate(timestamp: timestamp, invertOffsetDirection: &invertOffsetDirection) {
                continueAnimations = true
            }
            let updatedApparentHeight = itemNode.apparentHeight
            let apparentHeightDelta = updatedApparentHeight - previousApparentHeight
            if abs(apparentHeightDelta) > CGFloat.ulpOfOne {
                itemNode.updateFrame(itemNode.frame, within: self.visibleSize)
                
                let visualInsets = self.dynamicVisualInsets?() ?? self.visualInsets ?? self.insets
                
                if itemNode.apparentFrame.maxY <= visualInsets.top {
                    offsetRanges.offset(IndexRange(first: 0, last: index), offset: -apparentHeightDelta)
                } else if invertOffsetDirection /*&& itemNode.frame.height < self.visibleSize.height*/ {
                    if self.scroller.contentOffset.y < 1.0 {
                        /*let overflowOffset = visualInsets.top - (itemNode.apparentFrame.minY - apparentHeightDelta)
                        let remainingOffset = apparentHeightDelta - overflowOffset
                        offsetRanges.offset(IndexRange(first: 0, last: index), offset: -remainingOffset)
                        
                        var offsetDelta = overflowOffset
                        if offsetDelta < 0.0 {
                            let maxDelta = visualInsets.top - itemNode.apparentFrame.maxY
                            if maxDelta > offsetDelta {
                                let remainingOffset = maxDelta - offsetDelta
                                offsetRanges.offset(IndexRange(first: 0, last: index), offset: remainingOffset)
                                offsetDelta = maxDelta
                            }
                        }
                        
                        offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: offsetDelta)*/
                        
                        var offsetDelta = apparentHeightDelta
                        if offsetDelta < 0.0 {
                            let maxDelta = visualInsets.top - itemNode.apparentFrame.maxY
                            if maxDelta > offsetDelta {
                                let remainingOffset = maxDelta - offsetDelta
                                offsetRanges.offset(IndexRange(first: 0, last: index), offset: remainingOffset)
                                offsetDelta = maxDelta
                            }
                        }
                        
                        offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: offsetDelta)
                    } else {
                        offsetRanges.offset(IndexRange(first: 0, last: index), offset: -apparentHeightDelta)
                    }
                } else {
                    var offsetDelta = apparentHeightDelta
                    if offsetDelta < 0.0 {
                        let maxDelta = visualInsets.top - itemNode.apparentFrame.maxY
                        if maxDelta > offsetDelta {
                            let remainingOffset = maxDelta - offsetDelta
                            offsetRanges.offset(IndexRange(first: 0, last: index), offset: remainingOffset)
                            offsetDelta = maxDelta
                        }
                    }
                    
                    offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: offsetDelta)
                }
                
                if let accessoryItemNode = itemNode.accessoryItemNode {
                    itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: self.insets.left, rightInset: self.insets.right)
                }
            }
            
            if itemNode.index == nil && updatedApparentHeight <= CGFloat.ulpOfOne {
                requestUpdateVisibleItems = true
            }
            
            index += 1
        }
        
        for (_, headerNode) in self.itemHeaderNodes {
            if headerNode.animate(timestamp) {
                continueAnimations = true
            }
        }
        
        if !offsetRanges.offsets.isEmpty {
            requestUpdateVisibleItems = true
            var index = 0
            for itemNode in self.itemNodes {
                let offset = offsetRanges.offsetForIndex(index)
                if offset != 0.0 {
                    itemNode.updateFrame(itemNode.frame.offsetBy(dx: 0.0, dy: offset), within: self.visibleSize)
                    self.didScrollWithOffset?(-offset, .immediate, itemNode, self.isTrackingOrDecelerating)
                }
                
                index += 1
            }
            
            if !self.snapToBounds(snapTopItem: false, stackFromBottom: self.stackFromBottom, insetDeltaOffsetFix: 0.0).offset.isZero {
                self.updateVisibleContentOffset()
            }
        }
        
        self.debugCheckMonotonity()
        
        if !continueAnimations {
            self.pauseAnimations()
        }
        
        if requestUpdateVisibleItems {
            self.enqueueUpdateVisibleItems(synchronous: false)
        }
        
        if scrollingForReorder {
            if  let reorderScrollUpdateTimestamp = self.reorderScrollUpdateTimestamp, timestamp < reorderScrollUpdateTimestamp + 0.05 {
                return
            }
            self.reorderScrollUpdateTimestamp = timestamp
            self.checkItemReordering(force: true)
        }
    }
    
    override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.interruptAccessibilitySpeechIfNeeded()
        let touchesPosition = touches.first!.location(in: self.view)
        
        if let index = self.itemIndexAtPoint(touchesPosition) {
            for i in 0 ..< self.itemNodes.count {
                if self.itemNodes[i].preventsTouchesToOtherItems {
                    if index != self.itemNodes[i].index {
                        self.itemNodes[i].touchesToOtherItemsPrevented()
                        return
                    }
                    break
                }
            }
        }
        
        let offset = self.visibleContentOffset()
        switch offset {
            case let .known(value) where value <= 10.0:
                self.beganTrackingAtTopOrigin = true
            default:
                self.beganTrackingAtTopOrigin = false
        }
        
        self.touchesPosition = touchesPosition
        
        var processSelection = true
        if let itemNodeHitTest = self.itemNodeHitTest, !itemNodeHitTest(touchesPosition) {
            processSelection = false
        }
        
        if processSelection {
            self.selectionTouchLocation = touches.first!.location(in: self.view)
            self.selectionTouchDelayTimer?.invalidate()
            self.selectionLongTapDelayTimer?.invalidate()
            self.selectionLongTapDelayTimer = nil
            let timer = Timer(timeInterval: 0.08, target: ListViewTimerProxy { [weak self] in
                if let strongSelf = self, strongSelf.selectionTouchLocation != nil {
                    strongSelf.clearHighlightAnimated(false)
                    
                    if let index = strongSelf.itemIndexAtPoint(strongSelf.touchesPosition) {
                        var canBeSelectedOrLongTapped = false
                        for itemNode in strongSelf.itemNodes {
                            var canBeSelected = itemNode.canBeSelected
                            if canBeSelected {
                                if !itemNode.isLayerBacked {
                                    if !itemNode.visibleForSelection(at: strongSelf.view.convert(strongSelf.touchesPosition, to: itemNode.view)) {
                                        canBeSelected = false
                                    }
                                }
                            }
                            if itemNode.index == index && (strongSelf.items[index].selectable && canBeSelected) || itemNode.canBeLongTapped {
                                canBeSelectedOrLongTapped = true
                            }
                        }
                        
                        if canBeSelectedOrLongTapped {
                            strongSelf.highlightedItemIndex = index
                            for itemNode in strongSelf.itemNodes {
                                let itemNodeFrame = itemNode.frame
                                let itemNodeBounds = itemNode.bounds
                                let itemPoint = strongSelf.touchesPosition.offsetBy(dx: -itemNodeFrame.minX + itemNodeBounds.minX, dy: -itemNodeFrame.minY + itemNodeBounds.minY)
                                
                                var canBeSelected = itemNode.canBeSelected
                                if canBeSelected {
                                    if !itemNode.isLayerBacked {
                                        if !itemNode.visibleForSelection(at: itemPoint) {
                                            canBeSelected = false
                                        }
                                    }
                                }
                                
                                if itemNode.index == index && canBeSelected {
                                    if true {
                                        if !itemNode.isLayerBacked {
                                            strongSelf.reorderItemNodeToFront(itemNode)
                                            for (_, headerNode) in strongSelf.itemHeaderNodes {
                                                strongSelf.reorderHeaderNodeToFront(headerNode)
                                            }
                                        }
                                        if strongSelf.items[index].selectable {
                                            itemNode.setHighlighted(true, at: itemPoint, animated: false)
                                        }
                                        
                                        if itemNode.canBeLongTapped {
                                            let timer = Timer(timeInterval: 0.3, target: ListViewTimerProxy {
                                                if let strongSelf = self, strongSelf.highlightedItemIndex == index {
                                                    for itemNode in strongSelf.itemNodes {
                                                        if itemNode.index == index && itemNode.canBeLongTapped {
                                                            itemNode.longTapped()
                                                            strongSelf.clearHighlightAnimated(true)
                                                            strongSelf.selectionTouchLocation = nil
                                                            break
                                                        }
                                                    }
                                                }
                                            }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
                                            strongSelf.selectionLongTapDelayTimer = timer
                                            RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
                                        }
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
            }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
            self.selectionTouchDelayTimer = timer
            RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
        }
        super.touchesBegan(touches, with: event)
        
        self.updateScroller(transition: .immediate)
    }
    
    public func clearHighlightAnimated(_ animated: Bool) {
        if let highlightedItemIndex = self.highlightedItemIndex {
            for itemNode in self.itemNodes {
                if itemNode.index == highlightedItemIndex {
                    itemNode.setHighlighted(false, at: CGPoint(), animated: animated)
                    break
                }
            }
        }
        self.highlightedItemIndex = nil
    }
    
    public func updateNodeHighlightsAnimated(_ animated: Bool) {
        let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.35, curve: .spring) : .immediate
        self.updateOverlayHighlight(transition: transition)
    }
    
    public func itemIndexAtPoint(_ point: CGPoint) -> Int? {
        var point = point
        if self.useSingleDimensionTouchPoint {
            point.x = 0.0
        }
        for itemNode in self.itemNodes {
            if itemNode.apparentContentFrame.contains(point) {
                return itemNode.index
            }
        }
        return nil
    }
    
    public func itemNodeAtIndex(_ index: Int) -> ListViewItemNode? {
        for itemNode in self.itemNodes {
            if itemNode.index == index {
                return itemNode
            }
        }
        return nil
    }
    
    public func indexOf(itemNode: ListViewItemNode) -> Int? {
        for listItemNode in self.itemNodes {
            if itemNode === listItemNode {
                return listItemNode.index
            }
        }
        return nil
    }
    
    public func forEachItemNode(_ f: (ASDisplayNode) -> Void) {
        for itemNode in self.itemNodes {
            if itemNode.index != nil {
                f(itemNode)
            }
        }
    }
    
    public func forEachRemovedItemNode(_ f: (ASDisplayNode) -> Void) {
        for itemNode in self.itemNodes {
            if itemNode.index == nil {
                f(itemNode)
            }
        }
    }

    public func enumerateItemNodes(_ f: (ASDisplayNode) -> Bool) {
        for itemNode in self.itemNodes {
            if itemNode.index != nil {
                if !f(itemNode) {
                    break
                }
            }
        }
    }
    
    public func forEachVisibleItemNode(_ f: (ASDisplayNode) -> Void) {
        for itemNode in self.itemNodes {
            if itemNode.index != nil && itemNode.frame.maxY > self.insets.top && itemNode.frame.minY < self.visibleSize.height - self.insets.bottom {
                f(itemNode)
            }
        }
    }
    
    public func forEachItemHeaderNode(_ f: (ListViewItemHeaderNode) -> Void) {
        for (_, itemNode) in self.itemHeaderNodes {
            f(itemNode)
        }
    }
    
    public func forEachAccessoryItemNode(_ f: (ListViewAccessoryItemNode) -> Void) {
        for itemNode in self.itemNodes {
            if let accessoryItemNode = itemNode.accessoryItemNode {
                f(accessoryItemNode)
            }
        }
    }
    
    public func ensureItemNodeVisible(_ node: ListViewItemNode, animated: Bool = true, overflow: CGFloat = 0.0, allowIntersection: Bool = false, atTop: Bool = false, curve: ListViewAnimationCurve = .Default(duration: 0.25)) {
        if let index = node.index {
            if node.apparentHeight > self.visibleSize.height - self.insets.top - self.insets.bottom {
                if atTop {
                    if node.frame.maxY > self.visibleSize.height - self.insets.bottom {
                        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(-overflow), animated: animated, curve: curve, directionHint: ListViewScrollToItemDirectionHint.Down), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                    } else if node.frame.minY < self.insets.top && overflow > 0.0 {
                        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(-overflow), animated: animated, curve: curve, directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                    }
                } else {
                    if node.frame.maxY > self.visibleSize.height - self.insets.bottom {
                        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.bottom(-overflow), animated: animated, curve: curve, directionHint: ListViewScrollToItemDirectionHint.Down), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                    } else if node.frame.minY < self.insets.top && overflow > 0.0 {
                        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(-overflow), animated: animated, curve: curve, directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                    }
                }
            } else {
                if self.experimentalSnapScrollToItem {
                    self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.visible, animated: animated, curve: ListViewAnimationCurve.Default(duration: nil), directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                } else {
                    if node.frame.minY < self.insets.top + overflow {
                        if !allowIntersection || node.frame.maxY < self.insets.top {
                            let position: ListViewScrollPosition
                            if allowIntersection {
                                position = .center(.top)
                            } else {
                                position = .top(overflow)
                            }
                            self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: position, animated: animated, curve: curve, directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                        }
                    } else if node.frame.maxY > self.visibleSize.height - self.insets.bottom - overflow {
                        if !allowIntersection || node.frame.minY > self.visibleSize.height - self.insets.bottom {
                            let position: ListViewScrollPosition
                            if allowIntersection {
                                position = .center(.bottom)
                            } else {
                                position = .bottom(-overflow)
                            }
                            self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: position, animated: animated, curve: curve, directionHint: ListViewScrollToItemDirectionHint.Down), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                        }
                    }
                }
            }
        }
    }
    
    public func ensureItemNodeVisibleAtTopInset(_ node: ListViewItemNode) {
        if let index = node.index {
            if node.frame.minY != self.insets.top {
                self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(0.0), animated: true, curve: ListViewAnimationCurve.Default(duration: 0.25), directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
            }
        }
    }
    
    public func itemNodeRelativeOffset(_ node: ListViewItemNode) -> CGFloat? {
        if let _ = node.index {
            return node.frame.minY - self.insets.top
        }
        return nil
    }
    
    public func itemNodeVisibleInsideInsets(_ node: ListViewItemNode) -> Bool {
        if let _ = node.index {
            if node.frame.maxY > self.insets.top && node.frame.minY < self.visibleSize.height - self.insets.bottom {
                return true
            }
        }
        return false
    }

    override open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let selectionTouchLocation = self.selectionTouchLocation {
            let location = touches.first!.location(in: self.view)
            let distance = CGPoint(x: selectionTouchLocation.x - location.x, y: selectionTouchLocation.y - location.y)
            let maxMovementDistance: CGFloat = 4.0
            if distance.x * distance.x + distance.y * distance.y > maxMovementDistance * maxMovementDistance {
                self.selectionTouchLocation = nil
                self.selectionTouchDelayTimer?.invalidate()
                self.selectionLongTapDelayTimer?.invalidate()
                self.selectionTouchDelayTimer = nil
                self.selectionLongTapDelayTimer = nil
                self.clearHighlightAnimated(false)
            }
        }
        
        super.touchesMoved(touches, with: event)
    }
    
    public func cancelSelection() {
        if let _ = self.selectionTouchLocation {
            self.clearHighlightAnimated(true)
            self.selectionTouchLocation = nil
        }
    }
    
    override open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let isSecondary: Bool
        if #available(iOS 13.4, *) {
            isSecondary = event?.buttonMask == .secondary
        } else {
            isSecondary = false
        }
        
        if let selectionTouchLocation = self.selectionTouchLocation {
            let index = self.itemIndexAtPoint(selectionTouchLocation)
            
            if isSecondary {
                if let index = index {
                    if self.items[index].selectable {
                        self.highlightedItemIndex = index
                        for itemNode in self.itemNodes {
                            if itemNode.index == index {
                                itemNode.secondaryAction(at: selectionTouchLocation)
                                self.items[index].performSecondaryAction(listView: self)
                                break
                            }
                        }
                    }
                }
            } else {
                if index != self.highlightedItemIndex {
                    self.clearHighlightAnimated(false)
                }
                
                if let index = index {
                    if self.items[index].selectable {
                        self.highlightedItemIndex = index
                        for itemNode in self.itemNodes {
                            if itemNode.index == index {
                                if itemNode.canBeSelected {
                                    if !itemNode.isLayerBacked {
                                        self.reorderItemNodeToFront(itemNode)
                                        for (_, headerNode) in self.itemHeaderNodes {
                                            self.reorderHeaderNodeToFront(headerNode)
                                        }
                                    }
                                    let itemNodeFrame = itemNode.frame
                                    itemNode.setHighlighted(true, at: selectionTouchLocation.offsetBy(dx: -itemNodeFrame.minX, dy: -itemNodeFrame.minY), animated: false)
                                } else {
                                    self.highlightedItemIndex = nil
                                    itemNode.tapped()
                                }
                                break
                            }
                        }
                    }
                }
            }
        }
                
        if !isSecondary, let highlightedItemIndex = self.highlightedItemIndex {
            for itemNode in self.itemNodes {
                if itemNode.index == highlightedItemIndex {
                    itemNode.selected()
                    break
                }
            }
            self.items[highlightedItemIndex].selected(listView: self)
        }
        self.selectionTouchLocation = nil
        
        super.touchesEnded(touches, with: event)
    }
    
    override open func touchesCancelled(_ touches: Set<UITouch>?, with event: UIEvent?) {
        self.selectionTouchLocation = nil
        self.selectionTouchDelayTimer?.invalidate()
        self.selectionTouchDelayTimer = nil
        self.selectionLongTapDelayTimer?.invalidate()
        self.selectionLongTapDelayTimer = nil
        self.clearHighlightAnimated(false)
        
        super.touchesCancelled(touches, with: event)
    }
    
    @objc func trackingGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                self.interruptAccessibilitySpeechIfNeeded()
                self.isTracking = true
                self.trackingOffset = 0.0
            case .changed:
                self.touchesPosition = recognizer.location(in: self.view)
            case .ended, .cancelled:
                self.isTracking = false
            default:
                break
        }
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    public func withTransaction(_ f: @escaping () -> Void) {
        self.transactionQueue.addTransaction { completion in
            f()
            completion()
        }
    }

    fileprivate func internalHitTest(_ point: CGPoint, with event: UIEvent?) -> Bool {
        if self.limitHitTestToNodes {
            var foundHit = false
            for itemNode in self.itemNodes {
                if itemNode.frame.contains(point) {
                    foundHit = true
                    break
                }
            }
            if !foundHit {
                return false
            }
        }
        return true
    }
    
    fileprivate func headerHitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for (_, headerNode) in self.itemHeaderNodes {
            let headerNodeFrame = headerNode.frame
            if headerNodeFrame.contains(point) {
                return headerNode.hitTest(self.view.convert(point, to: headerNode.view), with: event)
            }
        }
        return nil
    }
    
    private func reorderItemNodeToFront(_ itemNode: ListViewItemNode) {
        itemNode.view.superview?.bringSubviewToFront(itemNode.view)
        if let itemHighlightOverlayBackground = self.itemHighlightOverlayBackground {
            itemHighlightOverlayBackground.view.superview?.bringSubviewToFront(itemHighlightOverlayBackground.view)
        }
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            verticalScrollIndicator.view.superview?.bringSubviewToFront(verticalScrollIndicator.view)
        }
    }
    
    private func reorderHeaderNodeToFront(_ headerNode: ListViewItemHeaderNode) {
        headerNode.view.superview?.bringSubviewToFront(headerNode.view)
        if let itemHighlightOverlayBackground = self.itemHighlightOverlayBackground {
            itemHighlightOverlayBackground.view.superview?.bringSubviewToFront(itemHighlightOverlayBackground.view)
        }
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            verticalScrollIndicator.view.superview?.bringSubviewToFront(verticalScrollIndicator.view)
        }
    }
    
    public func scrollToOffsetFromTop(_ offset: CGFloat, animated: Bool) -> Bool {
        for itemNode in self.itemNodes {
            if itemNode.index == 0 {
                if self.scroller.contentOffset.y != offset + self.tempTopInset {
                    self.stopScrolling()
                    if animated {
                        self.scroller.setContentOffset(CGPoint(x: 0.0, y: offset + self.tempTopInset), animated: animated)
                    } else {
                        self.scroller.contentOffset = CGPoint(x: 0.0, y: offset + self.tempTopInset)
                    }
                }
                return true
            }
        }
        return false
    }
    
    public var accessibilityPageScrolledString: ((String, String) -> String)?
    public var accessibilityPageScrolledRangeString: ((String, String, String) -> String)?
    public var accessibilityPageScrolledUsesVisibleRange = true
    public var accessibilityLayoutChangedOnScroll = true
    public var accessibilityStatusAnnouncementOnScroll = false
    public var accessibilityInterruptSpeechOnUserAction = false
    public var accessibilityNavigationOrder: ListViewAccessibilityNavigationOrder = .natural
    public var accessibilityDirectionalAnnouncement: ((Int, Int) -> String?)?
    private var accessibilityDirectionalSnapshotId: Int = 0
    private var accessibilityPreviousFocusedDirectionalState: (snapshotId: Int, directionalIndex: Int)?
    private var accessibilityPendingFocusExitResetToken: Int = 0
    private var accessibilityDirectionalTrackedSignature: [String] = []
    private var accessibilityLastReportedVisibleRange: ListViewVisibleItemRange?
    private var accessibilityAutoAdvanceInProgress = false
    private var accessibilityLastCenteredElementIdentifier: ObjectIdentifier?
    private var accessibilityElementFocusedObserver: NSObjectProtocol?
    private var accessibilityLastSystemFocusedSignature: String?
    private var accessibilityLastSystemFocusedSourceViewIdentifier: ObjectIdentifier?
    private var accessibilityLastSystemFocusedIndex: Int?
    private var accessibilityRecoveryInProgress = false
    private var accessibilityFocusContainmentCheckToken: Int = 0
    private var accessibilityLastInListFocusTimestamp: CFTimeInterval = 0.0
    private var accessibilityFocusLeftListFailureCount: Int = 0
    private var accessibilityBoundaryRecenterInProgress = false
    private var accessibilityLastBoundaryRecenterTimestamp: CFTimeInterval = 0.0
    private var accessibilityIgnoreOffscreenUntil: CFTimeInterval = 0.0
    // Баг 1: список чатов переиспользует VO-машинерию повёрнутой истории
    // (scroll-to-focused + boundary-page-scroll), и она порождает каскады
    // авто-прокруток, зачитывающие случайные чаты (при появлении экрана и при
    // свайпе у края). Для ПЛОСКОГО списка чатов это вредно: ручная навигация —
    // всегда ±1, а любые нелинейные перескоки VO — это re-anchor/каскад, к
    // которому НЕ нужно подскролливать (нативный VO сам прокрутит). Когда флаг
    // включён (только ChatListNode, не история): (1) scroll-to-focused только
    // для линейных ±1 переходов, (2) boundary-page-scroll полностью отключён.
    public var accessibilityUsesNativeScrollForNonSequentialFocus: Bool = false
    // Баг 2: история выставляет true, когда в самый низ дописаны trailing-кнопки
    // («Написать сообщение»/«Отменить ответ»). Тогда boundary-page-scroll при
    // движении вперёд (к новейшему) отключается, чтобы VO дошёл до кнопки.
    public var accessibilitySuppressTrailingBoundaryScroll: Bool = false
    // Баг 2: реальные VO-элементы (того же пулового типа, что и сообщения),
    // дописываемые ПОСЛЕ новейшего сообщения — кнопки «Написать сообщение»/
    // «Отменить ответ». Подкласс (история) поставляет их через провайдер; они
    // получают синтетический localIndex ниже минимального, поэтому после
    // reverse встают последними swipe-стопами. Активация делегируется в
    // `sourceView.accessibilityActivate()`.
    public var accessibilityTrailingPooledElementsProvider: (() -> [ListViewAccessibilityTrailingElement])?
    private var accessibilitySyntheticTrailingIndices: Set<Int> = []
    private var accessibilityLastLoggedArraySnapshot: [String] = []
    private var accessibilityLastLoggedGlobalPosition: Int?
    // Element pool keyed by the list item's stable *local index* rather than
    // by the transient UIView pointer holding the item. Keying by UIView was
    // the source of a subtle accessibility regression: ListView recycles
    // item nodes (and therefore their backing UIViews) as the user scrolls,
    // so right after a programmatic silent-scroll, the same UIView might
    // already be rendering a *different* chat. Looking the element up by
    // UIView pointer then returned the *same* FocusTrackingAccessibilityElement
    // instance and rewrote its label/frame to reflect the new chat, while
    // VoiceOver — which tracks focus by element identity — believed the
    // user was still on their previously focused element. Visually that
    // looked like "the cursor sticks to the bottom of the screen and
    // announces whichever item just slid under it" (exactly what shows up
    // in the user-captured logs as repeated `elementY=[712..788]` with the
    // cursor label changing chat after chat). Keying by item index makes
    // the element identity travel with the item across view reuse.
    private var accessibilityDirectionalElementPool: [Int: [FocusTrackingAccessibilityElement]] = [:]
    private var accessibilityEdgeScrollPending = false
    private var accessibilityLastProgrammaticEdgeScrollTimestamp: CFTimeInterval = 0.0
    private var accessibilityBoundaryAutoScrollTimestamp: CFTimeInterval = 0.0

    /// Returns (firstAbsoluteIndex, lastAbsoluteIndex, totalCount) for a given set of visible local item indices.
    public var accessibilityAbsoluteScrollInfo: (([Int]) -> (first: Int, last: Int, total: Int)?)?
    
    /// When VoiceOver is on and the user scrolls with three fingers, this closure can return text to be announced for the message at the bottom of the visible area. Used by chat to read aloud the bottom message content.
    public var accessibilityAnnouncementForBottomVisibleItem: ((ListViewItemNode) -> String?)?

    /// When set, a 3-finger VoiceOver scroll announces this string (e.g. the date of the top visible row) via `.pageScrolled` instead of reading a row, and suppresses the post-scroll focus re-centring. Chat history sets this; other lists leave it nil.
    public var accessibilityScrollPositionAnnouncement: (() -> String?)?

    /// Returns true if the given (now-focused) accessibility object is a
    /// legitimate place for the VoiceOver cursor to land *outside* this list —
    /// e.g. the chat's text input field, which VoiceOver reaches naturally when
    /// the user swipes past the last message. When it returns true the
    /// focus-containment machinery does NOT drag the cursor back into the list,
    /// so the user can move from the last message onto the input (and the input
    /// raises the keyboard itself). Leave nil to always recover focus.
    public var accessibilityIsLegitimateFocusEscape: ((Any) -> Bool)?

    /// Был ли VO-фокус внутри списка в последние 1.5 с (тот же порог, что у
    /// recovery). Нужен хосту (ChatControllerNode) в классификаторе
    /// легитимных уходов: побег в навбар СРАЗУ из ленты — это, как правило,
    /// iOS-овский «выпад» за край (свайп за последний элемент), его должны
    /// обработать forward-escape-редирект или recovery; уход спустя паузу —
    /// осознанное касание навбара пользователем.
    public var accessibilityFocusWasRecentlyInList: Bool {
        return CACurrentMediaTime() - self.accessibilityLastInListFocusTimestamp < 1.5
    }

    /// Host-provided handler invoked when the VoiceOver cursor escapes the list
    /// going FORWARD (past the newest message) but iOS sends it to the wrong
    /// place (the navigation-bar title) instead of the bottom input area. The
    /// host moves focus onto the input itself — e.g. raising the keyboard via
    /// `ensureFocused()` for the text field, or posting focus to the "Join
    /// group" button — and returns true if it handled the redirect. When it
    /// returns true the containment machinery does NOT yank the cursor back
    /// into the list. The trailing pooled compose element lives in the array
    /// but VoiceOver sometimes skips it straight to the navbar; this redirect
    /// makes the "swipe past last message → input" transition deterministic
    /// and (for the text field) raises the keyboard.
    public var accessibilityForwardEscapeHandler: (() -> Bool)?

    /// Screen-space vertical centre of the most recently focused in-list
    /// element. Used to gate the forward-escape redirect: only redirect to the
    /// bottom input when the last focused message was in the BOTTOM portion of
    /// the list (i.e. near the newest message) and focus escaped upward to the
    /// navbar. Swiping backward off the OLDEST (top) message reaches the navbar
    /// legitimately and must be left untouched.
    private var accessibilityLastFocusedScreenMidY: CGFloat?
    private var accessibilityLastInListFocusAtTrailingEdge = false

    /// When true, this list ignores VoiceOver focus notifications entirely.
    /// Set by a controller that is leaving the screen (e.g. the chat list while
    /// pushing into a chat) so its still-in-window list doesn't fight the
    /// incoming screen for the cursor. Cleared when it becomes topmost again.
    public var accessibilityFocusHandlingSuspended: Bool = false

    /// Subclass hook for vetoing the off-screen-uiview scroll path in
    /// `handleSystemAccessibilityFocusNotification`. Default: allow.
    ///
    /// `ChatHistoryListNodeImpl` overrides this to reject scroll requests
    /// whose target `localIndex` is far from the user's last live-focused
    /// bubble. This blocks the "_ASDisplayView matched to a far item →
    /// scroll-to-far-item" cascade that otherwise yanks the chat to the
    /// far end of the buffer when VoiceOver loses anchor at the edge of
    /// the bounded sliding window.
    open func accessibilityShouldAllowScrollToItem(at localIndex: Int) -> Bool {
        return true
    }

    public func updateAccessibilityDirectionalElements(_ elements: [Any]) {
        guard self.accessibilityDirectionalAnnouncement != nil else {
            self.accessibilityPreviousFocusedDirectionalState = nil
            self.accessibilityPendingFocusExitResetToken &+= 1
            self.accessibilityDirectionalTrackedSignature = []
            return
        }

        var trackedSignature: [String] = []
        for element in elements {
            guard let element = element as? FocusTrackingAccessibilityElement else { continue }
            let sourceViewSignature: String
            if let sourceView = element.sourceView {
                sourceViewSignature = String(ObjectIdentifier(sourceView).hashValue)
            } else {
                sourceViewSignature = "no-source-view"
            }
            let identifier = element.accessibilityIdentifier ?? ""
            let label = element.accessibilityLabel ?? ""
            let value = element.accessibilityValue ?? ""
            let traits = UInt64(element.accessibilityTraits.rawValue)
            // Do not include frame values here: frame changes while scrolling and should not reset
            // directional focus state unless actual accessible sequence changed.
            trackedSignature.append("\(sourceViewSignature)|\(identifier)|\(label)|\(value)|\(traits)")
        }

        let hasTrackedSequenceChanged = trackedSignature != self.accessibilityDirectionalTrackedSignature
        if hasTrackedSequenceChanged {
            self.accessibilityDirectionalSnapshotId &+= 1
            self.accessibilityPreviousFocusedDirectionalState = nil
            self.accessibilityPendingFocusExitResetToken &+= 1
            self.accessibilityDirectionalTrackedSignature = trackedSignature
        }
        let snapshotId = self.accessibilityDirectionalSnapshotId
        var trackedCount = 0
        for element in elements {
            guard let element = element as? FocusTrackingAccessibilityElement else { continue }
            element.directionalSnapshotId = snapshotId
            element.directionalFocusIndex = trackedCount
            element.focused = { [weak self] snapshotId, directionalIndex in
                self?.handleAccessibilityElementFocused(snapshotId: snapshotId, directionalIndex: directionalIndex)
            }
            element.focusLost = { [weak self] snapshotId, directionalIndex in
                self?.handleAccessibilityElementFocusLost(snapshotId: snapshotId, directionalIndex: directionalIndex)
            }
            trackedCount += 1
        }
    }
    
    public func accessibilityClippingFrameInScreenCoordinates() -> CGRect? {
        let visibleBoundsRect = CGRect(
            x: 0.0,
            y: self.rotated ? self.insets.bottom : self.insets.top,
            width: self.visibleSize.width,
            height: max(0.0, self.visibleSize.height - self.insets.top - self.insets.bottom)
        )
        guard visibleBoundsRect.width > 1.0, visibleBoundsRect.height > 1.0 else {
            return nil
        }
        return UIAccessibility.convertToScreenCoordinates(visibleBoundsRect, in: self.view)
    }

    private func handleAccessibilityElementFocused(snapshotId: Int, directionalIndex: Int) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        guard snapshotId == self.accessibilityDirectionalSnapshotId else { return }
        self.accessibilityPendingFocusExitResetToken &+= 1

        guard let previousState = self.accessibilityPreviousFocusedDirectionalState else {
            self.accessibilityPreviousFocusedDirectionalState = (snapshotId: snapshotId, directionalIndex: directionalIndex)
            return
        }
        self.accessibilityPreviousFocusedDirectionalState = (snapshotId: snapshotId, directionalIndex: directionalIndex)
        guard previousState.snapshotId == snapshotId else { return }
        guard previousState.directionalIndex != directionalIndex,
              let accessibilityDirectionalAnnouncement = self.accessibilityDirectionalAnnouncement else { return }
        if abs(previousState.directionalIndex - directionalIndex) == 1 {
            self.logVoiceOverDirectionalSwipeTransition(
                snapshotId: snapshotId,
                fromDirectionalIndex: previousState.directionalIndex,
                toDirectionalIndex: directionalIndex
            )
        }
        guard let announcement = accessibilityDirectionalAnnouncement(previousState.directionalIndex, directionalIndex),
              !announcement.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func handleAccessibilityElementFocusLost(snapshotId: Int, directionalIndex: Int) {
        guard snapshotId == self.accessibilityDirectionalSnapshotId else { return }
        guard let previousState = self.accessibilityPreviousFocusedDirectionalState,
              previousState.snapshotId == snapshotId,
              previousState.directionalIndex == directionalIndex else { return }
        self.accessibilityPendingFocusExitResetToken &+= 1
        let resetToken = self.accessibilityPendingFocusExitResetToken
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.accessibilityPendingFocusExitResetToken == resetToken else { return }
            guard let currentState = self.accessibilityPreviousFocusedDirectionalState,
                  currentState.snapshotId == snapshotId,
                  currentState.directionalIndex == directionalIndex else { return }
            self.accessibilityPreviousFocusedDirectionalState = nil
        }
    }

    private func handleSystemAccessibilityFocusNotification(_ notification: Notification) {
        guard UIAccessibility.isVoiceOverRunning else {
            return
        }
        guard self.accessibilityDirectionalAnnouncement != nil else {
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=no-directional-announcement")
            return
        }
        // The owning controller is leaving the screen (e.g. chat list pushing
        // into a chat). Don't react to focus changes — otherwise this list
        // chases the cursor while the new screen is still loading.
        if self.accessibilityFocusHandlingSuspended {
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=suspended")
            return
        }
        // This is a *global* NotificationCenter handler — every materialised
        // ListView receives it, including a chat history node that is leaving
        // the screen during a push/pop. An off-screen node must not react to
        // focus changes: otherwise the outgoing chat's list fights the
        // incoming one for the cursor (the "cursor jumps to a random message
        // before the new screen finishes loading" symptom). Bail out unless
        // this list is actually on screen.
        if self.view.window == nil || self.isHidden || self.alpha <= 0.01 {
            return
        }
        // During a push/pop both the outgoing and incoming chat lists are
        // briefly in the window at once. The outgoing one is slid off-screen
        // (or covered), so additionally require that the list's content frame
        // still meaningfully intersects its own window before reacting.
        if let window = self.view.window,
           let clipFrame = self.accessibilityClippingFrameInScreenCoordinates() {
            let windowFrame = window.convert(window.bounds, to: nil)
            let intersection = clipFrame.intersection(windowFrame)
            if intersection.isNull || intersection.width < 1.0 || intersection.height < 1.0 {
                return
            }
        }

        let focusedAny = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey]
        if focusedAny == nil {
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=nil-focused-element")
            return
        }
        if let focusedAny, !self.isAccessibilityObjectInsideListView(focusedAny) {
            // **Cheap hierarchy check FIRST.** If the focused element is not
            // even a descendant of this list view, focus genuinely left the
            // list (context menu, reply/forward input panel, navbar, …) — bail
            // immediately.
            //
            // The previous order called the expensive
            // `isAccessibilityObjectInsideCurrentListSequence` first, which
            // rebuilds the entire `customAccessibilityElements` array (promote
            // every materialised bubble + recursive `suppressCompetingLeaves`)
            // on EVERY focus move. While a context menu or the reply-panel
            // close button was focused, iOS fires focus notifications
            // repeatedly, so the list rebuilt its array dozens of times in a
            // row — the `promoted=42` storm in the logs and the visible hang
            // when opening the menu via deep-press. Every in-sequence element's
            // source view is a descendant of the list, so checking the view
            // hierarchy first never misclassifies a real list item.
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=focus-left-list type=\(type(of: focusedAny))")
            self.scheduleAccessibilityFocusContainmentCheck(reason: "system-focus-left-list")
            return
        }
        // Фокус ВНУТРИ списка: обновляем признаки «фокус был в ленте» СРАЗУ,
        // не дожидаясь основного учёта ниже — тот часто не выполняется (выходы
        // на пустом массиве во время churn'а при подскроллах, неудачный
        // матчинг). Из-за этого таймстамп протухал на секунды при непрерывных
        // свайпах (sinceInList=9.4 в логах), побег курсора в навбар считался
        // «осознанным» (вайтлист legitimate-escape), и recovery не запускался —
        // курсор застревал на «Назад».
        if let focusedAny {
            self.accessibilityLastInListFocusTimestamp = CACurrentMediaTime()
            var earlyFocusedFrame = CGRect.null
            if let focusedView = focusedAny as? UIView {
                earlyFocusedFrame = UIAccessibility.convertToScreenCoordinates(focusedView.bounds, in: focusedView)
            } else if let focusedNSObject = focusedAny as? NSObject {
                earlyFocusedFrame = focusedNSObject.accessibilityFrame
            }
            if !earlyFocusedFrame.isNull {
                self.accessibilityLastFocusedScreenMidY = earlyFocusedFrame.midY
            }
        }
        if let focusedView = focusedAny as? UIView,
           self.isAccessibilityObjectInsideListView(focusedView),
           let clipFrame = self.accessibilityClippingFrameInScreenCoordinates() {
            let focusedScreenFrame = UIAccessibility.convertToScreenCoordinates(focusedView.bounds, in: focusedView)
            if !focusedScreenFrame.isNull && !focusedScreenFrame.intersects(clipFrame) {
                if CACurrentMediaTime() < self.accessibilityIgnoreOffscreenUntil || self.accessibilityBoundaryRecenterInProgress {
                    voAccessibilityLog("[VO-STATE] focus-handler-skip reason=offscreen-ignored ttl=\(String(format: "%.0f", (self.accessibilityIgnoreOffscreenUntil - CACurrentMediaTime()) * 1000))ms")
                    return
                }
                // Variant Y: when the focused UIView is one of our
                // own `ListViewItemNode` views and it's off-screen,
                // scroll the list to bring it into view.
                //
                // Historical context: this branch used to be a hard
                // `return` because the proxy-based accessibility model
                // (`FocusTrackingAccessibilityElement` per entry) had a
                // duplicate accessibility element for every visible
                // bubble (proxy AND promoted bubble view at the same
                // real frame). Reacting to UIView focus events with a
                // scroll caused a ping-pong between the proxy and the
                // bubble. With variant Y the proxies are gone — the
                // bubble's own UIView IS the canonical accessibility
                // leaf for the row, so scrolling to it on focus
                // doesn't have a sibling to fight with.
                //
                // We restrict the scroll to focused views that we
                // recognise as one of our materialised item nodes
                // (`self.itemNodes.first(where: { ... })`). Any other
                // off-screen UIView focus (e.g. a chat list item under
                // the proxy-based path, or some unrelated descendant
                // of ListView) still falls through to the no-op
                // return. `scrollVoiceOverFocusToItem` already
                // debounces via `accessibilityIgnoreOffscreenUntil`
                // and skips when the row is sufficiently on-screen,
                // so repeated transient focus events don't pile up
                // scroll transactions.
                // Match the focused view against item nodes — either the
                // item node's own view IS the focused element (chat-list
                // case: each row is a single accessibility element), or
                // the focused element is a *descendant* view inside the
                // item node (chat-history case: a message bubble is an
                // accessibility container whose child elements are the
                // focus targets). Walking up to the enclosing item node
                // is what lets the off-screen-focus scroll handler work
                // for container-style cells.
                if let itemNode = self.itemNodes.first(where: { $0.view === focusedView || focusedView.isDescendant(of: $0.view) }),
                   let localIndex = itemNode.index {
                    // Bogus-fallback guard. After a swipe at the edge of the
                    // variant-Y sliding window, VoiceOver can land focus on
                    // a parent `_ASDisplayView` that happens to be one of
                    // the item nodes — even one that is far from where the
                    // user has been navigating (observed: localIndex=0 while
                    // the user is around li=47). Reacting with a
                    // `scrollVoiceOverFocusToItem` for that bogus focus
                    // yanks the list to the far end of the buffer.
                    //
                    // Guard: if the item was *explicitly hidden* from
                    // accessibility (`accessibilityElementsHidden = true`),
                    // it can't be an intentional VoiceOver target. We do
                    // NOT also test `!isAccessibilityElement` — that is
                    // false for every container-style cell (chat-history
                    // bubbles) and would wrongly block their scroll. The
                    // subclass-level distance veto
                    // (`accessibilityShouldAllowScrollToItem`) is the
                    // other line of defence.
                    let viewHidden = itemNode.view.accessibilityElementsHidden
                    if viewHidden {
                        voAccessibilityLog("[VO-STATE] focus-scroll-skip reason=hidden-item localIndex=\(localIndex) viewHidden=\(viewHidden)")
                        return
                    }
                    // Дальний прыжок: сфокусированная вьюшка ВНЕ экрана и далеко
                    // (по индексу) от места, где реально шёл курсор. Реальная
                    // навигация свайпами двигается на ±1-2 индекса, а касание
                    // пальцем всегда попадает в ВИДИМЫЙ элемент (эта ветка — только
                    // для невидимых). Значит это fallback-фиксация iOS на
                    // устаревшем _ASDisplayView; скролл по ней утаскивал ленту к
                    // дальнему концу буфера («касание верха/низа экрана
                    // откидывает в начало/конец чата»). Subclass-veto
                    // (`accessibilityShouldAllowScrollToItem`) в base-engine-режиме
                    // отключён, поэтому страхуемся здесь по данным base engine.
                    if let lastFocusedIndex = self.accessibilityLastSystemFocusedIndex, abs(localIndex - lastFocusedIndex) > 2 {
                        voAccessibilityLog("[VO-STATE] focus-scroll-skip reason=far-jump localIndex=\(localIndex) last=\(lastFocusedIndex)")
                        return
                    }
                    if !self.accessibilityShouldAllowScrollToItem(at: localIndex) {
                        voAccessibilityLog("[VO-STATE] focus-scroll-skip reason=subclass-veto localIndex=\(localIndex)")
                        return
                    }
                    voAccessibilityLog("[VO-STATE] focus-scroll-triggered-by-uiview localIndex=\(localIndex) type=\(type(of: focusedView))")
                    self.scrollVoiceOverFocusToItem(at: localIndex)
                    return
                }
                voAccessibilityLog("[VO-STATE] focus-handler-skip reason=offscreen-uiview-ignored type=\(type(of: focusedView))")
                return
            }
        }
        guard let focusedAny, let focusedData = self.accessibilityDebugData(from: focusedAny) else {
            if let focusedAny {
                voDebugLog("[VO-SWIPE-DEBUG] system-focus unsupported-focused-type=\(type(of: focusedAny))")
            } else {
                voAccessibilityLog("[VO-STATE] focus-handler-skip reason=nil-focused-after-checks")
            }
            return
        }

        let elementsAny = self.customAccessibilityElements() ?? []
        let elements = elementsAny.compactMap { $0 as? UIAccessibilityElement }
        guard !elements.isEmpty else {
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=empty-elements")
            return
        }

        let elementData: [(index: Int, element: UIAccessibilityElement, data: (identifier: String, label: String, value: String, traits: UInt64, frame: CGRect, kind: String))] = elements.enumerated().compactMap { index, element in
            guard let data = self.accessibilityDebugData(from: element) else {
                return nil
            }
            return (index, element, data)
        }
        guard !elementData.isEmpty else {
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=empty-element-data visibleCount=\(elements.count)")
            return
        }
        let focusedSourceViewIdentifier: ObjectIdentifier?
        if let focusedView = focusedAny as? UIView {
            focusedSourceViewIdentifier = ObjectIdentifier(focusedView)
        } else if let focusedElement = focusedAny as? FocusTrackingAccessibilityElement, let sourceView = focusedElement.sourceView {
            focusedSourceViewIdentifier = ObjectIdentifier(sourceView)
        } else {
            focusedSourceViewIdentifier = nil
        }

        let toIndex: Int?
        let matchKind: String
        // 1) Element-identity match.
        //
        // Because `reuseOrCreateDirectionalElement` now keys the pool by
        // `localIndex` (the list item's stable identity), the very same
        // FocusTrackingAccessibilityElement instance that VoiceOver picked
        // up on the previous focus notification should still be present in
        // the freshly-built array — even if the underlying UIView has in
        // the meantime been reassigned to a different chat by ListView's
        // node recycler. Matching by instance therefore preserves focus on
        // the user's original item across recycling, which is what fixes
        // the "cursor glued to bottom of the screen while labels cycle
        // chat after chat" symptom observed in the logs.
        if let focusedTrackedElement = focusedAny as? FocusTrackingAccessibilityElement,
           let exactInstanceCandidate = elementData.first(where: { item in
               guard let trackedElement = item.element as? FocusTrackingAccessibilityElement else {
                   return false
               }
               return trackedElement === focusedTrackedElement
           }) {
            toIndex = exactInstanceCandidate.index
            matchKind = "exact-instance"
        } else if let focusedSourceViewIdentifier, let sourceViewCandidate = elementData.first(where: { item in
            guard let trackedElement = item.element as? FocusTrackingAccessibilityElement,
                  let sourceView = trackedElement.sourceView else {
                return false
            }
            return ObjectIdentifier(sourceView) == focusedSourceViewIdentifier
        }) {
            toIndex = sourceViewCandidate.index
            matchKind = "source-view"
        } else {
            let focusedStableKey = self.accessibilityDebugStableKey(from: focusedData)
            let exactCandidates = elementData.filter { self.accessibilityDebugStableKey(from: $0.data) == focusedStableKey }
            if exactCandidates.count == 1 {
                toIndex = exactCandidates[0].index
                matchKind = "exact"
            } else if exactCandidates.count > 1 {
                toIndex = exactCandidates.min(by: { self.accessibilityDebugFrameDistance($0.data.frame, focusedData.frame) < self.accessibilityDebugFrameDistance($1.data.frame, focusedData.frame) })?.index
                matchKind = "exact-nearest"
            } else {
                // Fallback: VoiceOver sometimes reports focused source as UIView (_ASDisplayView), so
                // match by nearest frame in screen coordinates.
                toIndex = elementData.min(by: { self.accessibilityDebugFrameDistance($0.data.frame, focusedData.frame) < self.accessibilityDebugFrameDistance($1.data.frame, focusedData.frame) })?.index
                matchKind = "nearest"
            }
        }
        guard let toIndex else {
            voAccessibilityLog("[VO-STATE] focus-handler-skip reason=nil-toIndex match=\(matchKind) visibleCount=\(elements.count)")
            return
        }
        // Remember where (vertically, on screen) the focused element sits so
        // the forward-escape redirect can tell a "swipe past the newest
        // message" (bottom) from a "swipe before the oldest message" (top).
        self.accessibilityLastFocusedScreenMidY = focusedData.frame.isNull ? nil : focusedData.frame.midY
        self.accessibilityLastSystemFocusedIndex = toIndex
        self.accessibilityLastInListFocusTimestamp = CACurrentMediaTime()
        // Был ли фокус на ПОСЛЕДНЕМ элементе массива (дальше по свайпу вперёд
        // элементов нет). Отличает настоящий «свайп за новейшее сообщение»
        // (нужен forward-escape-редирект на панель ввода) от ошибочного
        // ре-анкора iOS посреди истории (нужен recovery обратно в ленту).
        self.accessibilityLastInListFocusAtTrailingEdge = (toIndex >= elements.count - 1)
        self.accessibilityFocusLeftListFailureCount = 0

        // Deterministic scroll-into-view pass. After the
        // expanded-inclusion fix in `customAccessibilityElements` the
        // accessibility array reliably contains buffered items around the
        // visible window, which means VoiceOver can legitimately land on an
        // element whose real frame is partly or fully off-screen. Whenever
        // that happens we immediately scroll the list so that the focused
        // element is brought back inside the visible rect — the same
        // behaviour users get on UITableView. This replaces the fragile
        // "predict the next step at the array edge and silent-scroll
        // towards it" heuristic with a simpler invariant: whatever element
        // VoiceOver chooses to focus, it is visible.
        // Bring the focused element into view if it landed in the expanded
        // buffer zone but outside the strictly visible rect. We do NOT
        // return here any more (previously we did): after scrolling we
        // still want to run the boundary-advance check below so that the
        // list keeps materialising fresh items ahead of the cursor. With
        // element-identity pinning, VoiceOver's focus stays on the same
        // item across both the scroll-into-view pass *and* the buffer
        // extension, so it is safe — and actually necessary — to run
        // both in the same notification cycle.
        // Resolve `fromIndex` *before* triggering scroll so we can
        // detect phantom reversals (see anti-debounce block below) and
        // skip the wasted scroll-to-item.
        var fromIndex: Int?
        if let previousSourceViewIdentifier = self.accessibilityLastSystemFocusedSourceViewIdentifier {
            fromIndex = elementData.first(where: { item in
                guard let trackedElement = item.element as? FocusTrackingAccessibilityElement,
                      let sourceView = trackedElement.sourceView else {
                    return false
                }
                return ObjectIdentifier(sourceView) == previousSourceViewIdentifier
            })?.index
        }
        if fromIndex == nil, let previousSignature = self.accessibilityLastSystemFocusedSignature {
            fromIndex = elementData.first(where: { self.accessibilityDebugStableKey(from: $0.data) == previousSignature })?.index
        }
        self.accessibilityLastSystemFocusedSourceViewIdentifier = {
            guard let focusedElement = elementData.first(where: { $0.index == toIndex })?.element as? FocusTrackingAccessibilityElement,
                  let sourceView = focusedElement.sourceView else {
                return nil
            }
            return ObjectIdentifier(sourceView)
        }()
        self.accessibilityLastSystemFocusedSignature = self.accessibilityDebugStableKey(from: focusedData)

        if let focusedElement = elementData.first(where: { $0.index == toIndex })?.element as? UIAccessibilityElement {
            // Prefer the index-based scroll (UITableView-style
            // `scrollToRow(at:)`) over geometric `screenFrame` math.
            // Falls back to the geometric path for non-pooled elements.
            if let trackedElement = focusedElement as? FocusTrackingAccessibilityElement,
               let pinnedLocalIndex = trackedElement.pinnedLocalIndex {
                // Баг 1 (список чатов): скроллим к фокусу только при линейных ±1
                // переходах (ручная навигация свайпами). Нелинейные перескоки VO
                // (re-anchor при появлении экрана, после boundary-scroll, rotor)
                // НЕ подскролливаем — иначе запускается каскад с зачитыванием
                // случайных чатов. Нативный VO сам прокрутит при необходимости.
                let isNonSequential = (fromIndex == nil) || abs(toIndex - (fromIndex ?? toIndex)) > 1
                if self.accessibilityUsesNativeScrollForNonSequentialFocus && isNonSequential {
                    voAccessibilityLog("[VO-STATE] focus-scroll-suppressed-nonsequential toIndex=\(toIndex) localIndex=\(pinnedLocalIndex) from=\(String(describing: fromIndex))")
                } else {
                    self.scrollVoiceOverFocusToItem(at: pinnedLocalIndex)
                    voAccessibilityLog("[VO-STATE] focus-scroll-triggered-by-index toIndex=\(toIndex) localIndex=\(pinnedLocalIndex) visibleCount=\(elements.count) match=\(matchKind)")
                }
            } else {
                let scrollFrame = focusedElement.accessibilityFrame
                if self.scrollAccessibilityFocusIntoViewIfNeeded(screenFrame: scrollFrame) {
                    voAccessibilityLog("[VO-STATE] focus-scroll-triggered toIndex=\(toIndex) visibleCount=\(elements.count) match=\(matchKind)")
                }
            }
        }

        if let fromIndex, abs(toIndex - fromIndex) == 1 {
            var rows: [String] = []
            rows.reserveCapacity(elements.count)
            for item in elementData {
                let index = item.index
                let marker: String
                if index == fromIndex {
                    marker = "FROM"
                } else if index == toIndex {
                    marker = "TO"
                } else {
                    marker = ""
                }
                let summary = self.accessibilityDebugSummary(data: item.data)
                if marker.isEmpty {
                    rows.append("[\(index)] \(summary)")
                } else {
                    rows.append("[\(index) \(marker)] \(summary)")
                }
            }
            voDebugLog("[VO-SWIPE-DEBUG] system-focus-step from=\(fromIndex) to=\(toIndex) count=\(elements.count)")
            voDebugLog("[VO-SWIPE-DEBUG] system-visible-elements: \(rows.joined(separator: " || "))")
            let cursorDescription = elementData.first(where: { $0.index == toIndex })?.data.label ?? ""
            self.logAccessibilitySwipeMetrics(
                fromIndex: fromIndex,
                toIndex: toIndex,
                visibleElementsCount: elements.count,
                cursorDescription: cursorDescription
            )
                    voAccessibilityLog("[VO-STATE] cursor-log-source=system-step from=\(fromIndex) to=\(toIndex) visibleCount=\(elements.count)")
            // VoiceOver always walks the accessibilityElements array in ascending index
            // order regardless of our accessibilityNavigationOrder flag (that flag only
            // controls the order we *expose* elements in). So the direction of VO motion
            // is simply the sign of toIndex - fromIndex. If the next step in that same
            // direction would leave the visible array, VO is about to escape the list.
            let voDirection = toIndex - fromIndex
            let projectedNextIndex = toIndex + voDirection
            let nextStepLeavesArray = projectedNextIndex < 0 || projectedNextIndex >= elements.count
            let atTrailingEdge = (voDirection > 0 && toIndex == elements.count - 1)
            let atLeadingEdge = (voDirection < 0 && toIndex == 0)
            let atEdge = atTrailingEdge || atLeadingEdge
            // Eagerly extend the render buffer *one step* ahead of the
            // user's position. Triggering only at the hard edge (`atEdge`)
            // was unreliable because VoiceOver can request the next
            // element immediately on the same runloop iteration that
            // carried the user onto the last array slot — if our
            // materialisation hasn't produced a follow-up element by
            // then, VO promotes focus to the next sibling container
            // (navbar). By firing when the *next* swipe would land on
            // the edge we always have a fresh item ready when VoiceOver
            // actually asks for it.
            //
            // Safe to combine with `scrollAccessibilityFocusIntoViewIfNeeded`
            // now that focus identity is pinned to the stable element
            // instance (see `reuseOrCreateDirectionalElement` keyed by
            // localIndex): the buffer extension does not re-anchor
            // focus, so there is no double-scroll / leaping-cursor
            // conflict.
            let nextIsEdge = (voDirection > 0 && (toIndex + 1) >= elements.count - 1) ||
                             (voDirection < 0 && (toIndex - 1) <= 0)
            if atEdge || nextStepLeavesArray || nextIsEdge {
                let edgeIndex: Int = toIndex
                var visibleHeightForBoundary: CGFloat = .greatestFiniteMagnitude
                if let edgeItem = elementData.first(where: { $0.index == edgeIndex }),
                   let clipFrame = self.accessibilityClippingFrameInScreenCoordinates() {
                    let visibleHeight = edgeItem.data.frame.intersection(clipFrame).height
                    visibleHeightForBoundary = visibleHeight
                }
                voAccessibilityLog("[VO-STATE] boundary-page-scroll step=1-detected toIndex=\(toIndex) edgeIndex=\(edgeIndex) atEdge=\(atEdge) voDirection=\(voDirection) edgeVisH=\(Int(visibleHeightForBoundary.isFinite ? visibleHeightForBoundary : -1)) visibleCount=\(elements.count) globalPos=\(self.accessibilityLastLoggedGlobalPosition ?? -1)")
                // Capture the identity of the element the user is focused on *right now*
                // so that after the silent scroll we can deterministically re-anchor
                // VoiceOver focus onto the "next" element in the user's traversal
                // direction — without relying on VoiceOver's own focus tracking,
                // which is geometry-anchored and gets confused by our programmatic
                // scroll (the symptom observed in the logs: the cursor label keeps
                // changing while `position` stays stuck, then focus leaves the list
                // altogether when the accessibility array shrinks to zero).
                let focusedKey = self.accessibilityDebugStableKey(from: focusedData)
                let focusedFrame = focusedData.frame
                let _ = self.advanceAtBoundaryIfNeeded(
                    toIndex: edgeIndex,
                    visibleHeight: visibleHeightForBoundary,
                    visibleCount: elements.count,
                    voDirection: voDirection,
                    focusedStableKey: focusedKey,
                    focusedFrame: focusedFrame,
                    atEdge: atEdge || nextStepLeavesArray
                )
            }
        } else {
            let summary = self.accessibilityDebugSummary(data: focusedData)
            voDebugLog("[VO-SWIPE-DEBUG] system-focus kind=\(focusedData.kind) match=\(matchKind) to=\(toIndex) summary=\(summary)")
            if let fromIndex, fromIndex == toIndex {
                voAccessibilityLog("[VO-STATE] cursor-log-source=system-nonstep-skipped-same-index from=\(fromIndex) to=\(toIndex) visibleCount=\(elements.count)")
                return
            }
            let cursorDescription = elementData.first(where: { $0.index == toIndex })?.data.label ?? ""
            self.logAccessibilitySwipeMetrics(
                fromIndex: fromIndex ?? toIndex,
                toIndex: toIndex,
                visibleElementsCount: elements.count,
                cursorDescription: cursorDescription
            )
            voAccessibilityLog("[VO-STATE] cursor-log-source=system-nonstep from=\(String(describing: fromIndex)) to=\(toIndex) visibleCount=\(elements.count)")
        }
    }

    private func logAccessibilitySwipeMetrics(fromIndex: Int, toIndex: Int, visibleElementsCount: Int, cursorDescription: String) {
        let logicalPosition: Int
        if self.accessibilityNavigationOrder == .reversed {
            logicalPosition = max(0, visibleElementsCount - toIndex - 1)
        } else {
            logicalPosition = max(0, toIndex)
        }

        let (resolvedVisibleRange, rangeIndices) = self.currentAccessibilityRangeIndices()
        let totalChats: Int
        if let absoluteInfo = self.accessibilityAbsoluteScrollInfo?(rangeIndices) {
            totalChats = absoluteInfo.total
        } else {
            totalChats = self.items.count
        }

        var behind = logicalPosition
        if let resolvedVisibleRange {
            let globalPosition = max(0, resolvedVisibleRange.first + logicalPosition)
            behind = min(max(0, totalChats - 1), globalPosition)
        }
        let ahead = max(0, totalChats - behind - 1)

        var sanitized = cursorDescription.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if sanitized.count > 120 {
            sanitized = String(sanitized.prefix(120)) + "..."
        }
        self.accessibilityLastLoggedGlobalPosition = behind
        voAccessibilityLog("[VO-CURSOR] position=\(behind) behind=\(behind) ahead=\(ahead) total=\(totalChats) cursor='\(sanitized)'")
    }

    private func logAccessibilityArrayDiffIfNeeded(_ elements: [Any]) {
        let snapshot: [String] = elements.compactMap { any in
            guard let element = any as? UIAccessibilityElement else {
                return nil
            }
            let id = element.accessibilityIdentifier ?? ""
            let label = (element.accessibilityLabel ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let value = (element.accessibilityValue ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return "\(id)|\(label)|\(value)"
        }
        guard snapshot != self.accessibilityLastLoggedArraySnapshot else {
            return
        }

        let oldSet = Set(self.accessibilityLastLoggedArraySnapshot)
        let newSet = Set(snapshot)
        let addedLabels = Array(newSet.subtracting(oldSet)).prefix(3).map { value -> String in
            let parts = value.split(separator: "|")
            if parts.count > 1 {
                return String(parts[1].prefix(40))
            }
            return String(value.prefix(40))
        }
        let removedLabels = Array(oldSet.subtracting(newSet)).prefix(3).map { value -> String in
            let parts = value.split(separator: "|")
            if parts.count > 1 {
                return String(parts[1].prefix(40))
            }
            return String(value.prefix(40))
        }

        let (_, rangeIndices) = self.currentAccessibilityRangeIndices()
        let totalChats = self.accessibilityAbsoluteScrollInfo?(rangeIndices)?.total ?? self.items.count
        let uiElements = elements.compactMap { $0 as? UIAccessibilityElement }
        let oldCount = self.accessibilityLastLoggedArraySnapshot.count
        voAccessibilityLog("[VO-STATE] array-changed old=\(oldCount) new=\(snapshot.count) total=\(totalChats)")
        voAccessibilityLog("[VO-ARRAY] changed old=\(oldCount) new=\(snapshot.count) totalChats=\(totalChats) added=\(addedLabels) removed=\(removedLabels)")
        self.accessibilityLastLoggedArraySnapshot = snapshot
        self.logCursorAfterArrayChangeIfNeeded(totalChats: totalChats, oldCount: oldCount, newCount: snapshot.count, elements: uiElements)
    }

    private func logCursorAfterArrayChangeIfNeeded(totalChats: Int, oldCount: Int, newCount: Int, elements: [UIAccessibilityElement]) {
        guard UIAccessibility.isVoiceOverRunning else {
            return
        }
        guard !elements.isEmpty else {
            return
        }
        if let focusedObject = UIAccessibility.focusedElement(using: nil),
           self.isAccessibilityObjectInsideCurrentListSequence(focusedObject),
           let focusedData = self.accessibilityDebugData(from: focusedObject) {
            let elementData: [(index: Int, data: (identifier: String, label: String, value: String, traits: UInt64, frame: CGRect, kind: String))] = elements.enumerated().compactMap { index, element in
                guard let data = self.accessibilityDebugData(from: element) else {
                    return nil
                }
                return (index, data)
            }
            if !elementData.isEmpty {
                let focusedStableKey = self.accessibilityDebugStableKey(from: focusedData)
                let toIndex: Int?
                if let exact = elementData.first(where: { self.accessibilityDebugStableKey(from: $0.data) == focusedStableKey }) {
                    toIndex = exact.index
                } else {
                    toIndex = elementData.min(by: { self.accessibilityDebugFrameDistance($0.data.frame, focusedData.frame) < self.accessibilityDebugFrameDistance($1.data.frame, focusedData.frame) })?.index
                }
                if let toIndex {
                    let cursorDescription = elementData.first(where: { $0.index == toIndex })?.data.label ?? ""
                    self.logAccessibilitySwipeMetrics(
                        fromIndex: toIndex,
                        toIndex: toIndex,
                        visibleElementsCount: elements.count,
                        cursorDescription: cursorDescription
                    )
                    voAccessibilityLog("[VO-STATE] cursor-log-source=array-system-focus to=\(toIndex) visibleCount=\(elements.count)")
                }
            }
        }
    }

    private func advanceAtBoundaryIfNeeded(
        toIndex: Int,
        visibleHeight: CGFloat,
        visibleCount: Int,
        voDirection: Int,
        focusedStableKey: String,
        focusedFrame: CGRect,
        atEdge: Bool
    ) -> Bool {
        voAccessibilityLog("[VO-STATE] boundary-check toIndex=\(toIndex) voDir=\(voDirection) atEdge=\(atEdge) visibleHeight=\(Int(visibleHeight.rounded())) visibleCount=\(visibleCount) pending=\(self.accessibilityEdgeScrollPending)")

        // Баг 1: для плоского списка чатов boundary-page-scroll (подгрузка по
        // краю — нужна повёрнутой истории) вреден: свайп у края прокручивает
        // список и запускает каскад re-anchor'ов с зачитыванием случайных чатов.
        // Списку это не нужно — отключаем.
        if self.accessibilityUsesNativeScrollForNonSequentialFocus {
            return false
        }

        // Баг 2 (история): когда в самом низу истории есть наши trailing-кнопки
        // («Написать сообщение»/«Отменить ответ»), boundary-page-scroll при
        // движении ВПЕРЁД (к новейшему сообщению) мешает VO дойти до них: он
        // делает silent-scroll у новейшего сообщения, дёргает курсор и VO
        // уходит в навбар, минуя кнопку. Новее новейшего ничего нет — скролл
        // там бесполезен. Отключаем его при voDirection > 0, чтобы VO спокойно
        // перешёл с последнего сообщения на кнопку (следующий элемент массива).
        if self.accessibilitySuppressTrailingBoundaryScroll, voDirection > 0 {
            voAccessibilityLog("[VO-STATE] boundary-skip reason=trailing-button voDir=\(voDirection)")
            return false
        }

        // Gating is purely event-/state-based — no time thresholds:
        //   • `pendingOk` is a *proper* mutex that remains held through the
        //     full scroll → re-query → explicit focus post cycle, so a
        //     follow-up focus notification generated by our own
        //     `UIAccessibility.post(.layoutChanged,…)` cannot re-enter this
        //     method and cause a cascade.
        //   • `countOk` is a geometric invariant: we need at least two
        //     visible elements to make a meaningful decision; if the user is
        //     literally *at* the edge (`atEdge=true`) one element is
        //     sufficient, otherwise we would rather wait for the list to
        //     repopulate than risk a blind scroll.
        // У КРАЯ (atEdge) мьютекс игнорируем: pending в этот момент, как
        // правило, взведён подскроллом-в-видимость из ЭТОГО ЖЕ цикла
        // нотификации, и из-за него расширение буфера хронически скипалось
        // (логи: «boundary-check atEdge=true pending=true» раз за разом) —
        // массив не рос, следующий свайп вываливался за конец и VO
        // заворачивал курсор на первый элемент экрана («Назад»). Лёгкая
        // рывковость двойного скролла у края несравнимо лучше улёта курсора.
        let pendingOk = !self.accessibilityEdgeScrollPending || atEdge
        let minCount = atEdge ? 1 : 2
        let countOk = visibleCount >= minCount
        let voStep = voDirection >= 0 ? 1 : -1
        guard voDirection != 0 else {
            voAccessibilityLog("[VO-STATE] boundary-skip reason=voDirection-zero")
            return false
        }

        if !(pendingOk && countOk) {
            voAccessibilityLog("[VO-STATE] boundary-skip pendingOk=\(pendingOk) countOk=\(countOk) atEdge=\(atEdge)")
            return false
        }

        self.accessibilityEdgeScrollPending = true
        self.accessibilityIgnoreOffscreenUntil = CACurrentMediaTime() + 0.2
        voAccessibilityLog("[VO-STATE] boundary-page-scroll step=2-scroll-triggered edgeIndex=\(toIndex) voDir=\(voDirection)")

        // Buffer-extension pass. The scroll is executed *synchronously*
        // here — we do NOT defer it through DispatchQueue.main.async as
        // before — because the focus notification that triggered us may
        // have been the very last one VoiceOver posts before deciding
        // the current container has no more elements and promoting focus
        // to a sibling (navbar). By the time a deferred block runs, VO
        // has already escaped.
        //
        // With the localIndex-keyed element pool and the instance-match
        // path in `handleSystemAccessibilityFocusNotification`, the
        // focused element's identity travels with the item across the
        // scroll — we therefore deliberately DO NOT post focus onto a
        // "next" element the way the previous implementation did.
        // Re-anchoring focus by hand caused the cursor to visibly leap
        // forward without the user swiping. Letting VoiceOver follow
        // its own focused instance keeps one swipe == one item, which
        // is what the user expects.
        let scrolled = self.performAccessibilityEdgeScroll(voDirection: voStep)
        _ = focusedStableKey
        _ = focusedFrame
        voAccessibilityLog("[VO-STATE] boundary-page-scroll step=3-buffer-extended scrolled=\(scrolled)")

        // Release the mutex after two run-loop ticks. The subsequent
        // focus notifications (which VoiceOver emits in response to the
        // synchronous layout change) are matched against our localIndex-
        // pinned element instances and do not need to be silenced.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.accessibilityEdgeScrollPending = false
            }
        }
        voDebugLog("[VO-BOUNDARY-DEBUG] boundary-advance-trigger voDirection=\(voDirection) visibleHeight=\(Int(visibleHeight.rounded()))")
        return true
    }

    private func performAccessibilityEdgeScroll(voDirection: Int) -> Bool {
        // Map the VoiceOver array direction to a physical scroll direction.
        // For a non-rotated list (chat list, settings, …) VoiceOver walking
        // "downwards" on-screen corresponds to voDirection < 0 when the list
        // uses reversed navigation order (chat list) and voDirection > 0
        // otherwise. Either way, if the user just reached the bottom edge of
        // the visible window we need to scroll content upwards (i.e. .down
        // in ListViewScrollDirection semantics) so that the next items
        // materialise at the bottom.
        let scrollDirection: ListViewScrollDirection
        if voDirection < 0 {
            scrollDirection = self.rotated ? .up : .down
        } else {
            scrollDirection = self.rotated ? .down : .up
        }
        // A modest one-row step keeps the visible accessibility window
        // stable. Larger steps were tried and caused the array to shrink
        // faster than it refilled, because more off-screen items got pruned
        // than newly materialised ones were added back.
        let visibleArea = self.visibleSize.height - self.insets.top - self.insets.bottom
        let approxRowHeight: CGFloat = 76.0
        let maxStep: CGFloat = max(approxRowHeight, visibleArea * 0.18)
        let distance = floor(min(maxStep, approxRowHeight))
        voAccessibilityLog("[VO-STATE] boundary-page-scroll silent-scroll direction=\(scrollDirection) distance=\(Int(distance)) visibleArea=\(Int(visibleArea)) voDirection=\(voDirection)")
        let result = self.scrollWithDirection(scrollDirection, distance: distance, centerVoiceOverFocus: false, postScrollStatus: false)
        self.accessibilityLastProgrammaticEdgeScrollTimestamp = CACurrentMediaTime()
        // Force a *synchronous* materialisation pass so that brand-new item
        // nodes at the trailing edge (and therefore their accessibility
        // counterparts) are available on the very next
        // `customAccessibilityElements` query — otherwise VoiceOver may
        // reach the list's edge before the default, vsync-deferred update
        // lands and escape to the next container (typically the navbar).
        self.enqueueUpdateVisibleItems(synchronous: true)
        return result
    }

    // Deterministic "scroll the focused accessibility element into view" pass.
    //
    // Companion of the expanded-inclusion change in
    // `customAccessibilityElements`: now that the accessibility array also
    // contains items that are part of the render buffer but strictly
    // off-screen, VoiceOver can legitimately land on an element whose
    // accessibilityFrame is partially or fully outside the visible window.
    // In that situation we do what UITableView does natively — scroll the
    // list just enough to expose the focused element — which lets VoiceOver
    // progress through the entire list without ever encountering an "empty"
    // array and without relying on timing heuristics.
    @discardableResult
    private func scrollAccessibilityFocusIntoViewIfNeeded(screenFrame: CGRect) -> Bool {
        guard !self.accessibilityEdgeScrollPending,
              !self.accessibilityBoundaryRecenterInProgress else {
            return false
        }
        guard let clipFrame = self.accessibilityClippingFrameInScreenCoordinates() else {
            return false
        }
        guard !screenFrame.isNull, screenFrame.height > 0.5, screenFrame.width > 0.5 else {
            return false
        }

        // Small bias so the element lands one-ish point inside the visible
        // area rather than flush with its edge. Prevents oscillation on
        // sub-pixel boundaries.
        let margin: CGFloat = 2.0
        let clipHeight = max(clipFrame.height, 1.0)

        let extendsBelow = screenFrame.maxY > clipFrame.maxY - margin
        let extendsAbove = screenFrame.minY < clipFrame.minY + margin
        if !extendsBelow && !extendsAbove {
            // Already fully inside the visible window.
            return false
        }

        // Choose alignment so the focused row lands as a "natural reading
        // start" inside the clip rather than hugging whichever edge it
        // touched.  Three cases:
        //
        //  • element bigger than the clip — always pin its TOP to clip
        //    top, so VoiceOver speech and the focus indicator both start
        //    at the beginning of the message.
        //  • element fits and is below the clip — pin its TOP to clip
        //    top too: the user has just swiped to the next message, they
        //    expect to see it from the start, not from its tail.
        //  • element fits and is above the clip — pin its BOTTOM to clip
        //    bottom: the user has swiped to a previous (rotated chat:
        //    older) message, the natural cue is that the prior message
        //    appears at the bottom of the screen and the user reads
        //    upwards.
        //
        // The previous min-edge-only logic (just nudge the offending edge
        // into the clip) left tall message bubbles ~10% visible after a
        // swipe, which is the symptom in the user's logs.
        let scrollDirection: ListViewScrollDirection
        let rawDistance: CGFloat
        let elementTallerThanClip = screenFrame.height > clipHeight - margin
        if extendsBelow {
            // Move content up so the element comes into view from below.
            scrollDirection = self.rotated ? .up : .down
            if elementTallerThanClip || extendsAbove {
                // Tall element (or already partly above) — top-to-top.
                rawDistance = (screenFrame.minY - clipFrame.minY) + margin
            } else {
                // Short element — top-to-top still feels best for VO swipe
                // navigation: each swipe = one full message at the top.
                rawDistance = (screenFrame.minY - clipFrame.minY) + margin
            }
        } else {
            // extendsAbove only.  Move content down so the element comes
            // into view from above.
            scrollDirection = self.rotated ? .down : .up
            if elementTallerThanClip {
                // Tall element — pin its top to clip top so reading starts
                // at the beginning.
                rawDistance = (clipFrame.minY - screenFrame.minY) + margin
            } else {
                // Short element — bottom-to-bottom keeps the previous-
                // message reading flow consistent.
                rawDistance = (clipFrame.maxY - screenFrame.maxY) + margin
            }
        }
        // Generous safety cap.  The previous `clipHeight * 2` was tuned
        // for chat-list-sized rows (~76pt) and choked chat history's
        // 800–1500pt message bubbles, leaving them barely visible after
        // each VoiceOver swipe.  With the localIndex-keyed proxy pool
        // (see `reuseOrCreateDirectionalElement`) view recycling no
        // longer collapses focus identity, so a much larger cap is safe.
        let scrollCap = clipHeight * 10.0
        let cappedDistance = min(rawDistance, scrollCap)
        let distance = ceil(max(cappedDistance, 1.0))
        guard distance >= 1.0 else {
            return false
        }
        let wasCapped = cappedDistance < rawDistance - 0.5

        voAccessibilityLog("[VO-STATE] scroll-focus-into-view direction=\(scrollDirection) distance=\(Int(distance))\(wasCapped ? " (capped from \(Int(rawDistance)))" : "") elementY=[\(Int(screenFrame.minY))..\(Int(screenFrame.maxY))] elementH=\(Int(screenFrame.height)) clipY=[\(Int(clipFrame.minY))..\(Int(clipFrame.maxY))] clipH=\(Int(clipHeight)) tallerThanClip=\(elementTallerThanClip)")

        self.accessibilityEdgeScrollPending = true
        // Suppress the "focus is offscreen" hot-path for a short window: the
        // programmatic scroll we are about to issue will itself generate a
        // focus notification (VoiceOver re-reports the element at its new
        // coordinates) and we don't want to recurse into either scroll or
        // boundary-advance handling while layout settles.
        self.accessibilityIgnoreOffscreenUntil = CACurrentMediaTime() + 0.2
        let scrolled = self.scrollWithDirection(scrollDirection, distance: distance, centerVoiceOverFocus: false, postScrollStatus: false)
        self.accessibilityLastProgrammaticEdgeScrollTimestamp = CACurrentMediaTime()
        // Force a *synchronous* materialisation pass so newly revealed item
        // nodes are part of the accessibility array before VoiceOver
        // re-queries it — otherwise the array appears to "shrink" after a
        // scroll (items leave at one edge faster than they arrive at the
        // other) and eventually reaches zero, at which point VoiceOver
        // escapes the list.
        self.enqueueUpdateVisibleItems(synchronous: true)
        // Release the mutex after two run-loop ticks so that the focus
        // notification produced by the scroll itself is ignored.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.accessibilityEdgeScrollPending = false
            }
        }
        return scrolled
    }

    private func isAccessibilityObjectInsideListView(_ object: Any) -> Bool {
        if let view = object as? UIView {
            return view === self.view || view.isDescendant(of: self.view)
        }
        if let element = object as? UIAccessibilityElement {
            if let containerView = element.accessibilityContainer as? UIView {
                return containerView === self.view || containerView.isDescendant(of: self.view)
            }
            if let containerNode = element.accessibilityContainer as? ASDisplayNode {
                let containerView = containerNode.view
                return containerView === self.view || containerView.isDescendant(of: self.view)
            }
        }
        return false
    }

    private func accessibilitySourceViewIdentifier(from object: Any) -> ObjectIdentifier? {
        if let view = object as? UIView {
            return ObjectIdentifier(view)
        }
        if let focusedElement = object as? FocusTrackingAccessibilityElement, let sourceView = focusedElement.sourceView {
            return ObjectIdentifier(sourceView)
        }
        return nil
    }

    private func isAccessibilityObjectInsideCurrentListSequence(_ object: Any) -> Bool {
        if self.isAccessibilityObjectInsideListView(object) {
            return true
        }
        guard let focusedSourceViewIdentifier = self.accessibilitySourceViewIdentifier(from: object) else {
            return false
        }
        guard let elementsAny = self.customAccessibilityElements(), !elementsAny.isEmpty else {
            return false
        }
        for element in elementsAny {
            guard let trackedElement = element as? FocusTrackingAccessibilityElement,
                  let sourceView = trackedElement.sourceView else {
                continue
            }
            if ObjectIdentifier(sourceView) == focusedSourceViewIdentifier {
                return true
            }
        }
        return false
    }

    private func recoverAccessibilityFocusToList(aroundIndex: Int?, reason: String) {
        guard !self.accessibilityRecoveryInProgress else {
            return
        }
        self.accessibilityRecoveryInProgress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.accessibilityRecoveryInProgress = false
            }
            guard UIAccessibility.isVoiceOverRunning else {
                return
            }
            guard let elementsAny = self.customAccessibilityElements(), !elementsAny.isEmpty else {
                return
            }
            let elements = elementsAny.compactMap { $0 as? UIAccessibilityElement }
            guard !elements.isEmpty else {
                return
            }
            let candidateStableKeys = elements.map { element in
                self.accessibilityDebugStableKey(
                    from: (
                        identifier: element.accessibilityIdentifier ?? "",
                        label: element.accessibilityLabel ?? "",
                        value: element.accessibilityValue ?? "",
                        traits: UInt64(element.accessibilityTraits.rawValue),
                        frame: element.accessibilityFrame,
                        kind: "UIAccessibilityElement"
                    )
                )
            }
            guard let targetIndex = resolvedAccessibilityRecoveryIndex(
                preferredStableKey: self.accessibilityLastSystemFocusedSignature,
                aroundIndex: aroundIndex,
                candidateStableKeys: candidateStableKeys
            ) else {
                return
            }
            let targetElement = elements[targetIndex]
            self.accessibilityLastSystemFocusedSignature = self.accessibilityDebugStableKey(
                from: (
                    identifier: targetElement.accessibilityIdentifier ?? "",
                    label: targetElement.accessibilityLabel ?? "",
                    value: targetElement.accessibilityValue ?? "",
                    traits: UInt64(targetElement.accessibilityTraits.rawValue),
                    frame: targetElement.accessibilityFrame,
                    kind: "UIAccessibilityElement"
                )
            )
            if let focusTarget = targetElement as? FocusTrackingAccessibilityElement, let sourceView = focusTarget.sourceView {
                self.accessibilityLastSystemFocusedSourceViewIdentifier = ObjectIdentifier(sourceView)
            } else {
                self.accessibilityLastSystemFocusedSourceViewIdentifier = nil
            }
            voDebugLog("[VO-SWIPE-DEBUG] recover-focus reason=\(reason) targetIndex=\(targetIndex)")
            UIAccessibility.post(notification: .layoutChanged, argument: targetElement)
        }
    }

    private func scheduleAccessibilityFocusContainmentCheck(reason: String) {
        guard UIAccessibility.isVoiceOverRunning else {
            return
        }
        guard self.accessibilityDirectionalAnnouncement != nil else {
            return
        }
        if self.accessibilityBoundaryRecenterInProgress {
            return
        }
        // ВАЖНО: раньше при открытом «окне тишины» (accessibilityIgnoreOffscreenUntil,
        // ставится на 0.2с нашими же подскроллами) проверка НЕ планировалась вовсе.
        // Но именно во время подскролла iOS теряет фокус и ре-анкорит его в навбар
        // (на «Назад») — и спасать курсор было некому: ни редирект, ни recovery не
        // запускались, курсор оставался в навбаре («свайп за край — улетел в навбар»).
        // Теперь проверку планируем ЗА пределы окна.
        var checkDelay: Double = 0.12
        let ignoreRemaining = self.accessibilityIgnoreOffscreenUntil - CACurrentMediaTime()
        if ignoreRemaining > 0.0 {
            checkDelay = ignoreRemaining + 0.12
        }

        self.accessibilityFocusContainmentCheckToken &+= 1
        let checkToken = self.accessibilityFocusContainmentCheckToken

        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak self] in
            guard let self else {
                return
            }
            guard self.accessibilityFocusContainmentCheckToken == checkToken else {
                return
            }
            guard UIAccessibility.isVoiceOverRunning else {
                return
            }
            // Re-check the ignore window *inside* the deferred block: it may
            // have opened (edge-scroll / off-screen handling) after this check
            // was scheduled. Раньше здесь был полный выход — застрявший в
            // навбаре курсор оставался навсегда; теперь перепланируем проверку
            // за пределы нового окна (токен защищает от дублей).
            if CACurrentMediaTime() < self.accessibilityIgnoreOffscreenUntil {
                self.scheduleAccessibilityFocusContainmentCheck(reason: reason)
                return
            }
            guard let focusedObject = UIAccessibility.focusedElement(using: nil) else {
                return
            }

            if self.isAccessibilityObjectInsideCurrentListSequence(focusedObject) && self.isAccessibilityObjectVisibleInsideCurrentListSequence(focusedObject) {
                self.accessibilityFocusLeftListFailureCount = 0
                return
            }
            // The cursor legitimately moved to an allowed element outside the
            // list — typically the chat's text input field, which VoiceOver
            // reaches when the user swipes past the last message. Do NOT drag
            // it back: that was the previous symptom (cursor bounced from the
            // input to the title bar). Let it stay on the input.
            if self.accessibilityIsLegitimateFocusEscape?(focusedObject) == true {
                self.accessibilityFocusLeftListFailureCount = 0
                return
            }
            // Уход фокуса на таб-бар — всегда осознанное действие пользователя
            // (свайп за последний элемент списка или прямое касание вкладки).
            // Ошибочные ре-анкоры iOS, ради которых существует recovery, ведут
            // в центр списка или в навбар, но не в таб-бар. Без этого гейта
            // recovery в течение 1.5 с после ухода из списка утаскивал курсор
            // обратно — вкладки нельзя было пройти свайпом, только ощупыванием.
            if self.isAccessibilityObjectInsideTabBar(focusedObject) {
                self.accessibilityFocusLeftListFailureCount = 0
                voAccessibilityLog("[VO-STATE] focus-escape-to-tabbar — recovery skipped")
                return
            }
            // Right after our own edge scroll, give VoiceOver a short window
            // to land on the next row before attempting recovery.
            if CACurrentMediaTime() - self.accessibilityLastProgrammaticEdgeScrollTimestamp < 0.15 {
                self.accessibilityFocusLeftListFailureCount = 0
                return
            }
            // Forward-escape redirect. The user swiped FORWARD past the newest
            // message; iOS sent the cursor to the navbar title (ChatTitleView)
            // instead of the bottom input area, because the trailing pooled
            // compose element — though present in the array — is sometimes
            // skipped. If the host gave us an input target, move focus onto the
            // input instead of yanking it back into the list.
            //
            // Gate geometrically so a BACKWARD swipe off the oldest (top)
            // message still reaches the navbar: only redirect when (a) the last
            // focused message was in the BOTTOM portion of the list (near the
            // newest message) and (b) focus escaped UPWARD (above the list
            // centre — i.e. to the navbar), with the input target sitting at
            // the bottom.
            // ВАЖНО: редирект только если фокус был в ленте СОВСЕМ недавно
            // (тот же порог 1.5 с, что и у recovery ниже). Без этого гейта
            // lastFocusedMidY «протухал»: спустя минуты после ухода курсора из
            // ленты (пользователь стоит на «Назад» в навбаре) свайп на
            // заголовок чата всё ещё распознавался как «побег за новейшее
            // сообщение» и курсор утаскивался на кнопку «Написать сообщение» —
            // заголовок (онлайн/участники) был недостижим, курсор «зацикливался».
            // Плюс гейт «фокус был на ПОСЛЕДНЕМ элементе массива»: редирект на
            // панель ввода уместен только когда дальше по свайпу реально ничего
            // нет (конец чата). Посреди истории уход в навбар — это ошибочный
            // ре-анкор iOS во время подскролла; там правильный ответ — recovery
            // обратно на сообщение (ниже), а не прыжок на «Написать сообщение».
            if let clip = self.accessibilityClippingFrameInScreenCoordinates(),
               let lastFocusedMidY = self.accessibilityLastFocusedScreenMidY,
               lastFocusedMidY > clip.midY,
               self.accessibilityLastInListFocusAtTrailingEdge,
               CACurrentMediaTime() - self.accessibilityLastInListFocusTimestamp < 1.5,
               let handler = self.accessibilityForwardEscapeHandler {
                let escapedFrame: CGRect
                if let focusedView = focusedObject as? UIView {
                    escapedFrame = UIAccessibility.convertToScreenCoordinates(focusedView.bounds, in: focusedView)
                } else if let focusedNSObject = focusedObject as? NSObject {
                    escapedFrame = focusedNSObject.accessibilityFrame
                } else {
                    escapedFrame = .null
                }
                let escapedAbove = escapedFrame.isNull || escapedFrame.midY < clip.midY
                if escapedAbove, handler() {
                    self.accessibilityFocusLeftListFailureCount = 0
                    voAccessibilityLog("[VO-STATE] forward-escape-redirect-to-input lastFocusedMidY=\(Int(lastFocusedMidY)) clipMidY=\(Int(clip.midY))")
                    return
                }
            }
            
            // Recover only when focus was in this list very recently to avoid stealing
            // focus from intentional navigation to other controls.
            let recentlyFocusedList = CACurrentMediaTime() - self.accessibilityLastInListFocusTimestamp < 1.5
            guard recentlyFocusedList else {
                self.accessibilityFocusLeftListFailureCount = 0
                return
            }
            self.accessibilityFocusLeftListFailureCount = 0
            voAccessibilityLog("[VO-STATE] recover-focus-triggered reason=\(reason) lastFocusedIndex=\(String(describing: self.accessibilityLastSystemFocusedIndex))")
            self.recoverAccessibilityFocusToList(aroundIndex: self.accessibilityLastSystemFocusedIndex, reason: reason)
        }
    }

    // Ищем таб-бар вверх по цепочке superview от сфокусированного объекта:
    // TabBarNode помечает себя accessibilityTraits = [.tabBar], а фокус
    // обычно стоит на его дочернем узле-вкладке.
    private func isAccessibilityObjectInsideTabBar(_ object: Any) -> Bool {
        var currentView: UIView?
        if let view = object as? UIView {
            currentView = view
        } else if let node = object as? ASDisplayNode, node.isNodeLoaded {
            // VoiceOver может отдать в фокус сам узел (ноды попадают в
            // accessibilityElements контейнеров как есть) — идём от его view.
            currentView = node.view
        } else if let element = object as? UIAccessibilityElement {
            if let containerView = element.accessibilityContainer as? UIView {
                currentView = containerView
            } else if let containerNode = element.accessibilityContainer as? ASDisplayNode {
                currentView = containerNode.view
            }
        }
        while let view = currentView {
            if view.accessibilityTraits.contains(.tabBar) {
                return true
            }
            currentView = view.superview
        }
        return false
    }

    private func isAccessibilityObjectVisibleInsideCurrentListSequence(_ object: Any) -> Bool {
        guard let clipFrame = self.accessibilityClippingFrameInScreenCoordinates() else {
            return true
        }
        if let data = self.accessibilityDebugData(from: object) {
            if data.frame.isNull {
                return true
            }
            return data.frame.intersects(clipFrame)
        }
        if let view = object as? UIView {
            let frame = UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
            if frame.isNull {
                return true
            }
            return frame.intersects(clipFrame)
        }
        return true
    }

    public func reuseOrCreateDirectionalElement(localIndex: Int, childOrder: Int, sourceView: UIView) -> FocusTrackingAccessibilityElement {
        var elements = self.accessibilityDirectionalElementPool[localIndex] ?? []
        while elements.count <= childOrder {
            let element = FocusTrackingAccessibilityElement(accessibilityContainer: self)
            elements.append(element)
        }
        // Always refresh `sourceView` on the pooled element so the various
        // focus-by-view lookups (see `isAccessibilityObjectInsideListView`
        // and the source-view matching in `handleSystemAccessibilityFocusNotification`)
        // can map the *currently* rendering UIView back to the stable
        // per-item element. The element instance itself, however, remains
        // pinned to `localIndex`, which is what VoiceOver needs to keep
        // focus continuity across scrolls.
        elements[childOrder].sourceView = sourceView
        elements[childOrder].pinnedLocalIndex = localIndex
        self.accessibilityDirectionalElementPool[localIndex] = elements
        return elements[childOrder]
    }

    /// Index-based scroll for VoiceOver focus.
    ///
    /// When VoiceOver focuses one of our pooled
    /// `FocusTrackingAccessibilityElement` proxies we used to ask
    /// `scrollAccessibilityFocusIntoViewIfNeeded` to bring the proxy's
    /// geometric frame into the visible clip.  That works for short
    /// chat-list cells but breaks for chat history's tall message bubbles
    /// (1000–1500pt each), where the focused proxy's real screen frame
    /// can be tens of thousands of points off-screen — far outside the
    /// scroller's valid contentOffset range — and the geometric scroll
    /// either undershoots, overshoots into a different message, or
    /// confuses iOS's spatial navigation so the cursor jumps to a random
    /// element in the array.
    ///
    /// The fix is to behave like `UITableView.scrollToRow(at:at:animated:)`:
    /// use ListView's own `transaction(scrollToItem:)` to centre the
    /// item identified by `localIndex` in the visible window, regardless
    /// of its current geometric position.  After the transaction settles
    /// the item is materialised inside the clip, the proxy's frame is
    /// updated on the next `customAccessibilityElements` pass, and
    /// VoiceOver naturally redraws the focus indicator at the right
    /// place — matching what the user just selected.
    public func scrollVoiceOverFocusToItem(at localIndex: Int) {
        // Баг 2: синтетические trailing-кнопки не соответствуют реальной ячейке —
        // скроллить к ним некуда (и transaction(scrollToItem:) с таким индексом
        // был бы некорректен). Просто ничего не делаем: их фрейм фиксирован внизу.
        if self.accessibilitySyntheticTrailingIndices.contains(localIndex) {
            return
        }
        guard !self.accessibilityEdgeScrollPending,
              !self.accessibilityBoundaryRecenterInProgress else {
            return
        }

        // **Skip if already on-screen.**
        // Without this guard, every focus notification — including the
        // ones VoiceOver emits while the user is staying on the same
        // visible message — would trigger a full
        // `transaction(scrollToItem:)`.  That's expensive (synchronous
        // layout + materialisation pass), and worse, the resulting layout
        // change makes iOS re-resolve focus, often picking a different
        // element via `match=nearest` and creating a focus zig-zag
        // between two visible neighbours (the "chat=43 ↔ chat=44" loop
        // observed in the user's logs).  We only scroll when the target
        // row is genuinely outside the viewport.
        if let itemNode = self.itemNodes.first(where: { $0.index == localIndex }) {
            // **Rotation-correct visibility test.** The earlier version
            // compared `itemNode.frame` (ListView layout space) against a
            // viewport rect built from `insets`/`visibleSize`. For a
            // rotated list (chat history) the layout-space frame and the
            // on-screen position diverge — the test reported "already on
            // screen" for genuinely off-screen rows, so the whole method
            // short-circuited and never scrolled (the bug behind "скролл
            // не проходит / застряло после 2-3 подскролов").
            //
            // `UIAccessibility.convertToScreenCoordinates` walks the full
            // view hierarchy including the 180° rotation transform, so
            // the screen frame is correct regardless of rotation. We
            // compare it against the list's own on-screen clip frame.
            let itemScreenFrame = UIAccessibility.convertToScreenCoordinates(itemNode.bounds, in: itemNode.view)
            let listClipFrame = self.accessibilityClippingFrameInScreenCoordinates()
                ?? UIAccessibility.convertToScreenCoordinates(
                    CGRect(x: 0.0, y: self.insets.top, width: self.visibleSize.width, height: max(0.0, self.visibleSize.height - self.insets.top - self.insets.bottom)),
                    in: self.view)
            if !itemScreenFrame.isNull, !listClipFrame.isNull {
                let intersection = itemScreenFrame.intersection(listClipFrame)
                let intersectionHeight = intersection.isNull ? 0.0 : intersection.height
                let alreadyOnScreen: Bool
                if itemScreenFrame.height >= listClipFrame.height {
                    // Taller-than-clip row: a large overlap is enough —
                    // the user can already read its start.
                    alreadyOnScreen = intersectionHeight >= listClipFrame.height * 0.9
                } else {
                    // Short row: must be (almost) fully visible.
                    alreadyOnScreen = intersectionHeight >= itemScreenFrame.height - 1.0
                }
                if alreadyOnScreen {
                    return
                }
            }
        }

        self.accessibilityEdgeScrollPending = true
        self.accessibilityIgnoreOffscreenUntil = CACurrentMediaTime() + 0.2

        // `.center(.bottom)` with `additionalScrollDistance=0` mirrors how
        // `scrollToMessage(...)` brings the target message into the
        // viewport.  `animated: false` keeps the cursor responsive — the
        // user just swiped, they expect the next message to appear right
        // away.
        let scrollToItem = ListViewScrollToItem(
            index: localIndex,
            position: .center(.bottom),
            animated: false,
            curve: .Default(duration: nil),
            directionHint: .Down
        )
        self.transaction(
            deleteIndices: [],
            insertIndicesAndItems: [],
            updateIndicesAndItems: [],
            options: ListViewDeleteAndInsertOptions(),
            scrollToItem: scrollToItem,
            additionalScrollDistance: 0.0,
            updateSizeAndInsets: nil,
            stationaryItemRange: nil,
            updateOpaqueState: nil,
            completion: { _ in }
        )
        self.accessibilityLastProgrammaticEdgeScrollTimestamp = CACurrentMediaTime()

        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.accessibilityEdgeScrollPending = false
            }
        }
    }

    /// Reverse lookup: which `localIndex` does this UIView back, according
    /// to the directional element pool?  Used by the focus handler to
    /// translate UIView focus events into index-based scrolls.
    private func localIndexForSourceView(_ view: UIView) -> Int? {
        for (index, elements) in self.accessibilityDirectionalElementPool {
            for element in elements {
                if let sourceView = element.sourceView, sourceView === view {
                    return index
                }
            }
        }
        // Walk up the view tree as a fallback — chat history's
        // `sourceView` is the bubble's `AccessibilityAreaNode.view` /
        // `itemNode.view`, but iOS may post focus on a deeper descendant
        // (e.g. a button inside the bubble).  Take the first ancestor
        // that's known in the pool.
        var ancestor: UIView? = view.superview
        while let view = ancestor {
            for (index, elements) in self.accessibilityDirectionalElementPool {
                for element in elements {
                    if let sourceView = element.sourceView, sourceView === view {
                        return index
                    }
                }
            }
            ancestor = view.superview
        }
        return nil
    }

    public func cleanupDirectionalElementPool(activeLocalIndices: Set<Int>) {
        for key in self.accessibilityDirectionalElementPool.keys {
            if !activeLocalIndices.contains(key) {
                self.accessibilityDirectionalElementPool.removeValue(forKey: key)
            }
        }
    }

    private func accessibilityDebugData(from object: Any) -> (identifier: String, label: String, value: String, traits: UInt64, frame: CGRect, kind: String)? {
        if let element = object as? UIAccessibilityElement {
            return (
                identifier: element.accessibilityIdentifier ?? "",
                label: element.accessibilityLabel ?? "",
                value: element.accessibilityValue ?? "",
                traits: UInt64(element.accessibilityTraits.rawValue),
                frame: element.accessibilityFrame,
                kind: "UIAccessibilityElement"
            )
        }
        if let view = object as? UIView {
            return (
                identifier: view.accessibilityIdentifier ?? "",
                label: view.accessibilityLabel ?? "",
                value: view.accessibilityValue ?? "",
                traits: UInt64(view.accessibilityTraits.rawValue),
                frame: UIAccessibility.convertToScreenCoordinates(view.bounds, in: view),
                kind: String(describing: type(of: view))
            )
        }
        return nil
    }

    private func accessibilityDebugStableKey(from data: (identifier: String, label: String, value: String, traits: UInt64, frame: CGRect, kind: String)) -> String {
        return "\(data.identifier)|\(data.label)|\(data.value)|\(data.traits)"
    }

    private func accessibilityDebugFrameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func accessibilityDebugSummary(data: (identifier: String, label: String, value: String, traits: UInt64, frame: CGRect, kind: String)) -> String {
        let identifier = data.identifier
        var label = data.label
        if label.count > 80 {
            label = String(label.prefix(80)) + "..."
        }
        label = label.replacingOccurrences(of: "\n", with: " ")
        let frame = data.frame
        return "kind=\(data.kind) id='\(identifier)' label='\(label)' frame(x:\(Int(frame.minX.rounded())) y:\(Int(frame.minY.rounded())) w:\(Int(frame.width.rounded())) h:\(Int(frame.height.rounded())))"
    }

    private func logVoiceOverDirectionalSwipeTransition(snapshotId: Int, fromDirectionalIndex: Int, toDirectionalIndex: Int) {
        guard UIAccessibility.isVoiceOverRunning else {
            return
        }
        guard let elements = self.customAccessibilityElements(), !elements.isEmpty else {
            voDebugLog("[VO-SWIPE-DEBUG] snapshot=\(snapshotId) from=\(fromDirectionalIndex) to=\(toDirectionalIndex) elements=0")
            return
        }

        var rows: [String] = []
        rows.reserveCapacity(elements.count)

        for (index, element) in elements.enumerated() {
            guard let element = element as? UIAccessibilityElement else {
                rows.append("[\(index)] <non-UIAccessibilityElement>")
                continue
            }
            let marker: String
            if index == fromDirectionalIndex {
                marker = "FROM"
            } else if index == toDirectionalIndex {
                marker = "TO"
            } else {
                marker = ""
            }

            var label = element.accessibilityLabel ?? ""
            if label.count > 80 {
                label = String(label.prefix(80)) + "..."
            }
            label = label.replacingOccurrences(of: "\n", with: " ")

            let identifier = element.accessibilityIdentifier ?? ""
            let frame = element.accessibilityFrame
            let frameSummary = "x:\(Int(frame.minX.rounded())) y:\(Int(frame.minY.rounded())) w:\(Int(frame.width.rounded())) h:\(Int(frame.height.rounded()))"

            if marker.isEmpty {
                rows.append("[\(index)] id='\(identifier)' label='\(label)' frame(\(frameSummary))")
            } else {
                rows.append("[\(index) \(marker)] id='\(identifier)' label='\(label)' frame(\(frameSummary))")
            }
        }

        voDebugLog("[VO-SWIPE-DEBUG] one-finger-step snapshot=\(snapshotId) from=\(fromDirectionalIndex) to=\(toDirectionalIndex) count=\(elements.count)")
        voDebugLog("[VO-SWIPE-DEBUG] visible-elements: \(rows.joined(separator: " || "))")
    }

    private func interruptAccessibilitySpeechIfNeeded() {
        guard self.accessibilityInterruptSpeechOnUserAction, UIAccessibility.isVoiceOverRunning else {
            return
        }
        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: "")
    }
    
    public func scrollWithDirection(_ direction: ListViewScrollDirection, distance: CGFloat, centerVoiceOverFocus: Bool = false, postScrollStatus: Bool = true) -> Bool {
        let initialOffset = self.scroller.contentOffset
        let initialMaxOffset = max(self.scroller.contentInset.top, self.scroller.contentSize.height - self.scroller.frame.height)
        let initialProgress: CGFloat = initialMaxOffset > self.scroller.contentInset.top ? ((initialOffset.y - self.scroller.contentInset.top) / (initialMaxOffset - self.scroller.contentInset.top)) : 1.0
        voDebugLog("[VO-DEBUG] scrollWithDirection: direction=\(direction), distance=\(distance), initialOffset=\(initialOffset), contentSize=\(self.scroller.contentSize), frame=\(self.scroller.frame), contentInset=\(self.scroller.contentInset)")
        voDebugLog("[VO-DEBUG] scrollPosition before: offsetY=\(initialOffset.y), maxOffsetY=\(initialMaxOffset), progress=\(Int((max(0.0, min(1.0, initialProgress)) * 100.0).rounded()))%")
        switch direction {
            case .up:
                var contentOffset = initialOffset
                contentOffset.y -= distance
                contentOffset.y = max(self.scroller.contentInset.top, contentOffset.y)
                voDebugLog("[VO-DEBUG] scrollWithDirection UP: newOffset=\(contentOffset.y), willScroll=\(contentOffset.y < initialOffset.y)")
                if contentOffset.y < initialOffset.y {
                    self.scroller.setContentOffset(contentOffset, animated: false)
                    self.updateScrollViewDidScroll(self.scroller, synchronous: true)
                } else {
                    voDebugLog("[VO-DEBUG] scrollWithDirection UP: returning false (already at top)")
                    return false
                }
            case .down:
                var contentOffset = initialOffset
                contentOffset.y += distance
                contentOffset.y = max(self.scroller.contentInset.top, min(contentOffset.y, self.scroller.contentSize.height - self.scroller.frame.height))
                voDebugLog("[VO-DEBUG] scrollWithDirection DOWN: newOffset=\(contentOffset.y), willScroll=\(contentOffset.y > initialOffset.y)")
                if contentOffset.y > initialOffset.y {
                    self.scroller.setContentOffset(contentOffset, animated: false)
                    self.updateScrollViewDidScroll(self.scroller, synchronous: true)
                } else {
                    voDebugLog("[VO-DEBUG] scrollWithDirection DOWN: returning false (already at bottom)")
                    return false
                }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            
            let displayedVisibleRange = self.displayedItemRange.visibleRange
            let viewBounds = CGRect(origin: CGPoint.zero, size: self.visibleSize)
            let visibleNodeIndices = self.itemNodes
                .filter { $0.frame.intersects(viewBounds) && $0.index != nil }
                .compactMap(\.index)
            let resolvedVisibleRange = resolvedAccessibilityVisibleRange(
                displayedVisibleRange: displayedVisibleRange,
                visibleNodeIndices: visibleNodeIndices
            )
            let rangeIndices: [Int]
            if let resolvedVisibleRange {
                rangeIndices = Array(resolvedVisibleRange.first...resolvedVisibleRange.last)
            } else {
                rangeIndices = visibleNodeIndices
            }
            
            voDebugLog("[VO-DEBUG] deferred(0.15s): displayedRange=\(String(describing: displayedVisibleRange)), resolvedRange=\(String(describing: resolvedVisibleRange)), rangeIndices=\(rangeIndices), itemsCount=\(self.items.count)")
            let currentOffset = self.scroller.contentOffset
            let currentMaxOffset = max(self.scroller.contentInset.top, self.scroller.contentSize.height - self.scroller.frame.height)
            let currentProgress: CGFloat = currentMaxOffset > self.scroller.contentInset.top ? ((currentOffset.y - self.scroller.contentInset.top) / (currentMaxOffset - self.scroller.contentInset.top)) : 1.0
            voDebugLog("[VO-DEBUG] scrollPosition after: offsetY=\(currentOffset.y), maxOffsetY=\(currentMaxOffset), progress=\(Int((max(0.0, min(1.0, currentProgress)) * 100.0).rounded()))%")

            if let resolvedVisibleRange {
                let localFirst = resolvedVisibleRange.first + 1
                let localLast = resolvedVisibleRange.last + 1
                let localCount = max(0, localLast - localFirst + 1)
                let localCoverage: Double = self.items.count > 0 ? (Double(localCount) / Double(self.items.count)) * 100.0 : 0.0
                voDebugLog("[VO-DEBUG] localRange metrics: first=\(localFirst), last=\(localLast), count=\(localCount), totalItems=\(self.items.count), coverage=\(String(format: "%.1f", localCoverage))%")
            }

            if let resolvedVisibleRange {
                if let previousRange = self.accessibilityLastReportedVisibleRange, !self.accessibilityAutoAdvanceInProgress {
                    let isAtTopBoundary = resolvedVisibleRange.first <= 0
                    let isAtBottomBoundary = resolvedVisibleRange.last >= max(0, self.items.count - 1)
                    let hasNoRangeChange = resolvedVisibleRange.first == previousRange.firstIndex && resolvedVisibleRange.last == previousRange.lastIndex

                    // Auto-advance is only for true backward jumps after dynamic list rebase.
                    // Do not trigger it on equal ranges or at hard list boundaries.
                    let regressedDown = direction == .down && !isAtBottomBoundary && resolvedVisibleRange.last < previousRange.lastIndex
                    let regressedUp = direction == .up && !isAtTopBoundary && resolvedVisibleRange.first > previousRange.firstIndex
                    if regressedDown || regressedUp {
                        if hasNoRangeChange {
                            voDebugLog("[VO-DEBUG] accessibility auto-advance skipped: no range change")
                        }
                        self.accessibilityAutoAdvanceInProgress = true
                        voDebugLog("[VO-DEBUG] accessibility auto-advance: detected range regression, direction=\(direction), previous=\(previousRange), current=\(resolvedVisibleRange)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            guard let self else { return }
                            _ = self.scrollWithDirection(direction, distance: distance, centerVoiceOverFocus: false)
                            self.accessibilityAutoAdvanceInProgress = false
                        }
                    }
                }
                let resolvedFirstFullyVisible = displayedVisibleRange?.firstIndexFullyVisible ?? false
                self.accessibilityLastReportedVisibleRange = ListViewVisibleItemRange(
                    firstIndex: resolvedVisibleRange.first,
                    firstIndexFullyVisible: resolvedFirstFullyVisible,
                    lastIndex: resolvedVisibleRange.last
                )
            }
            
            let scrollStatus: String?
            // Highest priority: a caller-provided scroll-position string
            // (chat history returns the date of the top visible message).
            // When present it drives the `.pageScrolled` announcement below
            // and (via `usedScrollPositionAnnouncement`) suppresses focus
            // re-centring, so a 3-finger scroll speaks the position rather
            // than reading a message near the viewport centre.
            var usedScrollPositionAnnouncement = false
            if let scrollPositionAnnouncement = self.accessibilityScrollPositionAnnouncement?(), !scrollPositionAnnouncement.isEmpty {
                scrollStatus = scrollPositionAnnouncement
                usedScrollPositionAnnouncement = true
            } else if let absoluteInfo = self.accessibilityAbsoluteScrollInfo?(rangeIndices) {
                voDebugLog("[VO-DEBUG] absoluteInfo: first=\(absoluteInfo.first), last=\(absoluteInfo.last), total=\(absoluteInfo.total)")
                let absoluteCount = max(0, absoluteInfo.last - absoluteInfo.first + 1)
                let absoluteCoverage: Double = absoluteInfo.total > 0 ? (Double(absoluteCount) / Double(absoluteInfo.total)) * 100.0 : 0.0
                let absoluteTailProgress: Double = absoluteInfo.total > 0 ? (Double(absoluteInfo.last) / Double(absoluteInfo.total)) * 100.0 : 0.0
                voDebugLog("[VO-DEBUG] absoluteRange metrics: first=\(absoluteInfo.first), last=\(absoluteInfo.last), count=\(absoluteCount), total=\(absoluteInfo.total), coverage=\(String(format: "%.1f", absoluteCoverage))%, tailProgress=\(String(format: "%.1f", absoluteTailProgress))%")
                if let accessibilityPageScrolledRangeString = self.accessibilityPageScrolledRangeString {
                    scrollStatus = accessibilityPageScrolledRangeString("\(absoluteInfo.first)", "\(absoluteInfo.last)", "\(absoluteInfo.total)")
                } else {
                    scrollStatus = "Items \(absoluteInfo.first) to \(absoluteInfo.last) of \(absoluteInfo.total)"
                }
            } else if self.accessibilityPageScrolledUsesVisibleRange, let resolvedVisibleRange {
                if let accessibilityPageScrolledRangeString = self.accessibilityPageScrolledRangeString {
                    scrollStatus = accessibilityPageScrolledRangeString("\(resolvedVisibleRange.first + 1)", "\(resolvedVisibleRange.last + 1)", "\(self.items.count)")
                } else {
                    let rangeFormat = Bundle.main.localizedString(forKey: "VoiceOver.ScrollStatusRange", value: "Items from %1$@ to %2$@ of %3$@", table: nil)
                    scrollStatus = String(format: rangeFormat, "\(resolvedVisibleRange.first + 1)", "\(resolvedVisibleRange.last + 1)", "\(self.items.count)")
                }
            } else {
                scrollStatus = nil
            }
            
            voDebugLog("[VO-DEBUG] scrollStatus=\(scrollStatus ?? "nil")")
            
            if postScrollStatus {
                if let scrollStatus {
                    if self.accessibilityStatusAnnouncementOnScroll {
                        voDebugLog("[VO-DEBUG] posting .announcement: \(scrollStatus)")
                        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: scrollStatus)
                    } else {
                        voDebugLog("[VO-DEBUG] posting .pageScrolled: \(scrollStatus)")
                        UIAccessibility.post(notification: UIAccessibility.Notification.pageScrolled, argument: scrollStatus)
                    }
                } else {
                    voDebugLog("[VO-DEBUG] scrollStatus is nil, nothing posted!")
                }
            } else {
                voDebugLog("[VO-DEBUG] scrollStatus suppressed for programmatic edge scroll")
            }

            // Skip focus re-centring when we just announced a scroll
            // position: re-centring moves the VoiceOver cursor onto the
            // element nearest the viewport centre and reads it aloud, which
            // is the "random message after 3-finger scroll" we replace.
            if centerVoiceOverFocus, !usedScrollPositionAnnouncement, UIAccessibility.isVoiceOverRunning {
                self.postAccessibilityCenterFocus(retryCount: 2)
            }
        }
        return true
    }
    
    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let distance = floor((self.visibleSize.height - self.insets.top - self.insets.bottom))
        let scrollDirection: ListViewScrollDirection
        switch direction {
            case .down:
                scrollDirection = self.rotated ? .up : .down
            default:
                scrollDirection = self.rotated ? .down : .up
        }
        voDebugLog("[VO-DEBUG] accessibilityScroll called, direction=\(direction.rawValue), rotated=\(self.rotated), scrollDirection=\(scrollDirection), distance=\(distance)")
        let result = self.scrollWithDirection(scrollDirection, distance: distance, centerVoiceOverFocus: true)
        voDebugLog("[VO-DEBUG] accessibilityScroll result=\(result)")
        return result
    }

    public func postAccessibilityFocusOnAppear(preferredIdentifier: String? = nil, retryCount: Int = 3) {
        guard UIAccessibility.isVoiceOverRunning else {
            return
        }
        guard let targetElement = self.accessibilityElement(matchingIdentifier: preferredIdentifier) ?? self.accessibilityElementClosestToVisibleCenter() else {
            if retryCount > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.postAccessibilityFocusOnAppear(preferredIdentifier: preferredIdentifier, retryCount: retryCount - 1)
                }
            }
            return
        }
        
        self.accessibilityLastCenteredElementIdentifier = nil
        UIAccessibility.post(notification: .layoutChanged, argument: targetElement)
        
        if let scrollStatus = self.currentAccessibilityScrollStatus() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard UIAccessibility.isVoiceOverRunning else {
                    return
                }
                UIAccessibility.post(notification: .announcement, argument: scrollStatus)
            }
        }
    }
    
    private func currentAccessibilityScrollStatus() -> String? {
        let (_, rangeIndices) = self.currentAccessibilityRangeIndices()
        if let absoluteInfo = self.accessibilityAbsoluteScrollInfo?(rangeIndices) {
            if let accessibilityPageScrolledRangeString = self.accessibilityPageScrolledRangeString {
                return accessibilityPageScrolledRangeString("\(absoluteInfo.first)", "\(absoluteInfo.last)", "\(absoluteInfo.total)")
            } else {
                return "Items \(absoluteInfo.first) to \(absoluteInfo.last) of \(absoluteInfo.total)"
            }
        }
        
        let (resolvedVisibleRange, _) = self.currentAccessibilityRangeIndices()
        if self.accessibilityPageScrolledUsesVisibleRange, let resolvedVisibleRange {
            if let accessibilityPageScrolledRangeString = self.accessibilityPageScrolledRangeString {
                return accessibilityPageScrolledRangeString("\(resolvedVisibleRange.first + 1)", "\(resolvedVisibleRange.last + 1)", "\(self.items.count)")
            } else {
                let rangeFormat = Bundle.main.localizedString(forKey: "VoiceOver.ScrollStatusRange", value: "Items from %1$@ to %2$@ of %3$@", table: nil)
                return String(format: rangeFormat, "\(resolvedVisibleRange.first + 1)", "\(resolvedVisibleRange.last + 1)", "\(self.items.count)")
            }
        }
        
        return nil
    }
    
    private func currentAccessibilityRangeIndices() -> (resolvedVisibleRange: (first: Int, last: Int)?, rangeIndices: [Int]) {
        let displayedVisibleRange = self.displayedItemRange.visibleRange
        let viewBounds = CGRect(origin: CGPoint.zero, size: self.visibleSize)
        let visibleNodeIndices = self.itemNodes
            .filter { $0.frame.intersects(viewBounds) && $0.index != nil }
            .compactMap(\.index)
        let resolvedVisibleRange = resolvedAccessibilityVisibleRange(
            displayedVisibleRange: displayedVisibleRange,
            visibleNodeIndices: visibleNodeIndices
        )
        
        if let resolvedVisibleRange {
            return (resolvedVisibleRange, Array(resolvedVisibleRange.first...resolvedVisibleRange.last))
        } else {
            return (nil, visibleNodeIndices)
        }
    }
    
    private func accessibilityElement(matchingIdentifier identifier: String?) -> AnyObject? {
        guard let identifier, let elements = self.customAccessibilityElements(), !elements.isEmpty else {
            return nil
        }
        for element in elements {
            if let accessibilityElement = element as? UIAccessibilityElement, accessibilityElement.accessibilityIdentifier == identifier {
                return accessibilityElement
            } else if let view = element as? UIView, view.accessibilityIdentifier == identifier {
                return view
            }
        }
        return nil
    }
    
    private func postAccessibilityCenterFocus(retryCount: Int) {
        guard let centerElement = self.accessibilityElementClosestToVisibleCenter() else {
            if retryCount > 0 {
                voDebugLog("[VO-DEBUG] center-focus: no center element found, retry=\(retryCount)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.postAccessibilityCenterFocus(retryCount: retryCount - 1)
                }
            } else {
                voDebugLog("[VO-DEBUG] center-focus: no center element found")
            }
            return
        }

        let elementIdentifier = ObjectIdentifier(centerElement)
        if self.accessibilityLastCenteredElementIdentifier == elementIdentifier {
            voDebugLog("[VO-DEBUG] center-focus: skipping duplicate center target")
            return
        }
        self.accessibilityLastCenteredElementIdentifier = elementIdentifier
        voDebugLog("[VO-DEBUG] center-focus: posting .layoutChanged to center element")
        UIAccessibility.post(notification: UIAccessibility.Notification.layoutChanged, argument: centerElement)
    }

    private func accessibilityElementClosestToVisibleCenter() -> AnyObject? {
        let visibleBounds = CGRect(origin: .zero, size: self.visibleSize)
        let visibleBoundsInScreen = UIAccessibility.convertToScreenCoordinates(visibleBounds, in: self.view)
        let targetCenterY = visibleBoundsInScreen.midY

        guard let elements = self.customAccessibilityElements(), !elements.isEmpty else {
            return nil
        }

        var bestElement: AnyObject?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for element in elements {
            guard let accessibilityElement = element as? UIAccessibilityElement else {
                continue
            }
            let frame = accessibilityElement.accessibilityFrame
            if frame.isNull || frame.isEmpty || !frame.intersects(visibleBoundsInScreen) {
                continue
            }
            let label = accessibilityElement.accessibilityLabel ?? ""
            if label.isEmpty {
                continue
            }
            let distance = abs(frame.midY - targetCenterY)
            if distance < bestDistance {
                bestDistance = distance
                bestElement = accessibilityElement
            }
        }
        if bestElement == nil {
            // Fallback: center element from raw array, if castable.
            let middleIndex = elements.count / 2
            bestElement = elements[middleIndex] as AnyObject
        }
        return bestElement
    }
    
    open func customItemDeleteAnimationDuration(itemNode: ListViewItemNode) -> Double? {
        return nil
    }
}

private func findAccessibilityFocus(_ node: ASDisplayNode) -> Bool {
    if node.view.accessibilityElementIsFocused() {
        return true
    }
    return false
}
