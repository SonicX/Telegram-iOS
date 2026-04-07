import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import ContextUI
import AnimationCache
import MultiAnimationRenderer
import SearchUI

protocol ChatListDisplayNodeBackend: AnyObject {
    var displayNode: ASDisplayNode { get }

    var ready: Signal<Bool, NoError> { get }
    var contentsReady: Signal<Bool, NoError> { get }
    var currentState: ChatListNodeState { get }
    var state: Signal<ChatListNodeState, NoError> { get }
    var chatListFilter: ChatListFilter? { get }
    var entryPeerIds: [EnginePeer.Id] { get }
    var entriesCount: Int { get }
    var scrollToTopOption: Signal<ChatListGlobalScrollOption, NoError> { get }
    var preloadItems: Promise<[ChatHistoryPreloadItem]> { get }
    var isMainTab: ValuePromise<Bool> { get }

    var peerSelected: ((EnginePeer, Int64?, Bool, Bool, ChatListNodeEntryPromoInfo?) -> Void)? { get set }
    var disabledPeerSelected: ((EnginePeer, Int64?, ChatListDisabledPeerReason) -> Void)? { get set }
    var additionalCategorySelected: ((Int) -> Void)? { get set }
    var groupSelected: ((EngineChatList.Group) -> Void)? { get set }
    var addContact: ((String) -> Void)? { get set }
    var activateSearch: (() -> Void)? { get set }
    var deletePeerChat: ((EnginePeer.Id, Bool) -> Void)? { get set }
    var deletePeerThread: ((EnginePeer.Id, Int64) -> Void)? { get set }
    var setPeerThreadStopped: ((EnginePeer.Id, Int64, Bool) -> Void)? { get set }
    var setPeerThreadPinned: ((EnginePeer.Id, Int64, Bool) -> Void)? { get set }
    var setPeerThreadHidden: ((EnginePeer.Id, Int64, Bool) -> Void)? { get set }
    var updatePeerGrouping: ((EnginePeer.Id, Bool) -> Void)? { get set }
    var presentAlert: ((String) -> Void)? { get set }
    var present: ((ViewController) -> Void)? { get set }
    var push: ((ViewController) -> Void)? { get set }
    var toggleArchivedFolderHiddenByDefault: (() -> Void)? { get set }
    var hidePsa: ((EnginePeer.Id) -> Void)? { get set }
    var activateChatPreview: ((ChatListItem, Int64?, ASDisplayNode, ContextGesture?, CGPoint?) -> Void)? { get set }
    var openStories: ((ChatListNode.OpenStoriesSubject, ASDisplayNode?) -> Void)? { get set }
    var openBirthdaySetup: (() -> Void)? { get set }
    var openPremiumManagement: (() -> Void)? { get set }
    var openStarsTopup: ((Int64?) -> Void)? { get set }
    var openWebApp: ((TelegramUser) -> Void)? { get set }
    var openPhotoSetup: (() -> Void)? { get set }
    var openAdInfo: ((ASDisplayNode, AdPeer) -> Void)? { get set }
    var openAccountFreezeInfo: (() -> Void)? { get set }
    var contentOffsetChanged: ((ListViewVisibleContentOffset) -> Void)? { get set }
    var contentScrollingEnded: ((ChatListDisplayNode) -> Bool)? { get set }
    var didBeginInteractiveDragging: ((ChatListDisplayNode) -> Void)? { get set }
    var endedInteractiveDragging: ((ChatListDisplayNode) -> Void)? { get set }
    var shouldStopScrolling: ((ChatListDisplayNode, CGFloat) -> Bool)? { get set }
    var isEmptyUpdated: ((ChatListNodeEmptyState, Bool, ContainedViewLayoutTransition) -> Void)? { get set }
    var canExpandHiddenItems: (() -> Bool)? { get set }
    var addedVisibleChatsWithPeerIds: (([EnginePeer.Id]) -> Void)? { get set }
    var didBeginSelectingChats: (() -> Void)? { get set }
    var selectionCountChanged: ((Int) -> Void)? { get set }
    var reachedSelectionLimit: ((Int32) -> Void)? { get set }
    var updateFloatingHeaderOffset: ((CGFloat, ContainedViewLayoutTransition) -> Void)? { get set }

    var selectionLimit: Int32 { get set }
    var startedScrollingAtUpperBound: Bool { get set }
    var passthroughPeerSelection: Bool { get set }
    var synchronousDrawingWhenNotAnimated: Bool { get set }
    var tempTopInset: CGFloat { get set }
    var scrollHeightTopInset: CGFloat { get set }

    var isTracking: Bool { get }
    var isDragging: Bool { get }
    var isNavigationHidden: Bool { get }
    var isNavigationInAFinalState: Bool { get }

    func updateState(_ f: (ChatListNodeState) -> ChatListNodeState)
    func setCurrentRemovingItemId(_ itemId: ChatListNodeState.ItemId?)
    func updateFilter(_ filter: ChatListFilter?)
    func updateThemeAndStrings(theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, disableAnimations: Bool)
    func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets, visibleTopInset: CGFloat, originalTopInset: CGFloat, storiesInset: CGFloat, inlineNavigationLocation: ChatListControllerLocation?, inlineNavigationTransitionFraction: CGFloat)
    func updateSelectedChatLocation(_ chatLocation: ChatLocation?, progress: CGFloat, transition: ContainedViewLayoutTransition)
    func scrollToPosition(_ position: ChatListNodeScrollPosition, animated: Bool)
    @discardableResult func scrollToOffsetFromTop(_ offset: CGFloat, animated: Bool) -> Bool
    func visibleContentOffset() -> ListViewVisibleContentOffset
    func clearHighlightAnimated(_ animated: Bool)
    func selectChat(_ option: ChatListSelectionOption)
    func revealScrollHiddenItem()
    func hasItemsToBeRevealed() -> Bool
    func adjustScrollOffsetForNavigation(isNavigationHidden: Bool)
    func fixContentOffset(offset: CGFloat)
    func cancelTracking()
    func forEachItemNode(_ f: (ASDisplayNode) -> Void)
    func forEachVisibleItemNode(_ f: (ASDisplayNode) -> Void)
    func fixNavigationSearchableScrolling(searchNode: NavigationBarSearchContentNode) -> Bool
}

public final class ChatListDisplayNode: ASDisplayNode {
    fileprivate let backend: ChatListDisplayNodeBackend

    public init(getNavigationController: (() -> NavigationController?)? = nil, context: AccountContext, location: ChatListControllerLocation, chatListFilter: ChatListFilter? = nil, previewing: Bool, fillPreloadItems: Bool, mode: ChatListNodeMode, isPeerEnabled: ((EnginePeer) -> Bool)? = nil, theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, animationCache: AnimationCache, animationRenderer: MultiAnimationRenderer, disableAnimations: Bool, isInlineMode: Bool, autoSetReady: Bool, isMainTab: Bool?) {
        self.backend = ChatListTableNode(
            getNavigationController: getNavigationController,
            context: context,
            location: location,
            chatListFilter: chatListFilter,
            previewing: previewing,
            fillPreloadItems: fillPreloadItems,
            mode: mode,
            isPeerEnabled: isPeerEnabled,
            theme: theme,
            fontSize: fontSize,
            strings: strings,
            dateTimeFormat: dateTimeFormat,
            nameSortOrder: nameSortOrder,
            nameDisplayOrder: nameDisplayOrder,
            animationCache: animationCache,
            animationRenderer: animationRenderer,
            disableAnimations: disableAnimations,
            isInlineMode: isInlineMode,
            autoSetReady: autoSetReady,
            isMainTab: isMainTab
        )

        super.init()

        self.addSubnode(self.backend.displayNode)
    }

    public override func layout() {
        super.layout()
        self.backend.displayNode.frame = self.bounds
    }

    public var ready: Signal<Bool, NoError> { self.backend.ready }
    public var contentsReady: Signal<Bool, NoError> { self.backend.contentsReady }
    public var currentState: ChatListNodeState { self.backend.currentState }
    public var state: Signal<ChatListNodeState, NoError> { self.backend.state }
    public var chatListFilter: ChatListFilter? { self.backend.chatListFilter }
    public var entryPeerIds: [EnginePeer.Id] { self.backend.entryPeerIds }
    public var entriesCount: Int { self.backend.entriesCount }
    public var scrollToTopOption: Signal<ChatListGlobalScrollOption, NoError> { self.backend.scrollToTopOption }
    public var preloadItems: Promise<[ChatHistoryPreloadItem]> { self.backend.preloadItems }
    public let isMainTabProxy = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var isMainTab: ValuePromise<Bool> { self.backend.isMainTab }

    public var peerSelected: ((EnginePeer, Int64?, Bool, Bool, ChatListNodeEntryPromoInfo?) -> Void)? {
        get { self.backend.peerSelected }
        set { self.backend.peerSelected = newValue }
    }
    public var disabledPeerSelected: ((EnginePeer, Int64?, ChatListDisabledPeerReason) -> Void)? {
        get { self.backend.disabledPeerSelected }
        set { self.backend.disabledPeerSelected = newValue }
    }
    public var additionalCategorySelected: ((Int) -> Void)? {
        get { self.backend.additionalCategorySelected }
        set { self.backend.additionalCategorySelected = newValue }
    }
    public var groupSelected: ((EngineChatList.Group) -> Void)? {
        get { self.backend.groupSelected }
        set { self.backend.groupSelected = newValue }
    }
    public var addContact: ((String) -> Void)? {
        get { self.backend.addContact }
        set { self.backend.addContact = newValue }
    }
    public var activateSearch: (() -> Void)? {
        get { self.backend.activateSearch }
        set { self.backend.activateSearch = newValue }
    }
    public var deletePeerChat: ((EnginePeer.Id, Bool) -> Void)? {
        get { self.backend.deletePeerChat }
        set { self.backend.deletePeerChat = newValue }
    }
    public var deletePeerThread: ((EnginePeer.Id, Int64) -> Void)? {
        get { self.backend.deletePeerThread }
        set { self.backend.deletePeerThread = newValue }
    }
    public var setPeerThreadStopped: ((EnginePeer.Id, Int64, Bool) -> Void)? {
        get { self.backend.setPeerThreadStopped }
        set { self.backend.setPeerThreadStopped = newValue }
    }
    public var setPeerThreadPinned: ((EnginePeer.Id, Int64, Bool) -> Void)? {
        get { self.backend.setPeerThreadPinned }
        set { self.backend.setPeerThreadPinned = newValue }
    }
    public var setPeerThreadHidden: ((EnginePeer.Id, Int64, Bool) -> Void)? {
        get { self.backend.setPeerThreadHidden }
        set { self.backend.setPeerThreadHidden = newValue }
    }
    public var updatePeerGrouping: ((EnginePeer.Id, Bool) -> Void)? {
        get { self.backend.updatePeerGrouping }
        set { self.backend.updatePeerGrouping = newValue }
    }
    public var presentAlert: ((String) -> Void)? {
        get { self.backend.presentAlert }
        set { self.backend.presentAlert = newValue }
    }
    public var present: ((ViewController) -> Void)? {
        get { self.backend.present }
        set { self.backend.present = newValue }
    }
    public var push: ((ViewController) -> Void)? {
        get { self.backend.push }
        set { self.backend.push = newValue }
    }
    public var toggleArchivedFolderHiddenByDefault: (() -> Void)? {
        get { self.backend.toggleArchivedFolderHiddenByDefault }
        set { self.backend.toggleArchivedFolderHiddenByDefault = newValue }
    }
    public var hidePsa: ((EnginePeer.Id) -> Void)? {
        get { self.backend.hidePsa }
        set { self.backend.hidePsa = newValue }
    }
    public var activateChatPreview: ((ChatListItem, Int64?, ASDisplayNode, ContextGesture?, CGPoint?) -> Void)? {
        get { self.backend.activateChatPreview }
        set { self.backend.activateChatPreview = newValue }
    }
    public var openStories: ((ChatListNode.OpenStoriesSubject, ASDisplayNode?) -> Void)? {
        get { self.backend.openStories }
        set { self.backend.openStories = newValue }
    }
    public var openBirthdaySetup: (() -> Void)? {
        get { self.backend.openBirthdaySetup }
        set { self.backend.openBirthdaySetup = newValue }
    }
    public var openPremiumManagement: (() -> Void)? {
        get { self.backend.openPremiumManagement }
        set { self.backend.openPremiumManagement = newValue }
    }
    public var openStarsTopup: ((Int64?) -> Void)? {
        get { self.backend.openStarsTopup }
        set { self.backend.openStarsTopup = newValue }
    }
    public var openWebApp: ((TelegramUser) -> Void)? {
        get { self.backend.openWebApp }
        set { self.backend.openWebApp = newValue }
    }
    public var openPhotoSetup: (() -> Void)? {
        get { self.backend.openPhotoSetup }
        set { self.backend.openPhotoSetup = newValue }
    }
    public var openAdInfo: ((ASDisplayNode, AdPeer) -> Void)? {
        get { self.backend.openAdInfo }
        set { self.backend.openAdInfo = newValue }
    }
    public var openAccountFreezeInfo: (() -> Void)? {
        get { self.backend.openAccountFreezeInfo }
        set { self.backend.openAccountFreezeInfo = newValue }
    }
    public var contentOffsetChanged: ((ListViewVisibleContentOffset) -> Void)? {
        get { self.backend.contentOffsetChanged }
        set { self.backend.contentOffsetChanged = newValue }
    }
    public var contentScrollingEnded: ((ChatListDisplayNode) -> Bool)? {
        get { self.backend.contentScrollingEnded }
        set { self.backend.contentScrollingEnded = newValue }
    }
    public var didBeginInteractiveDragging: ((ChatListDisplayNode) -> Void)? {
        get { self.backend.didBeginInteractiveDragging }
        set { self.backend.didBeginInteractiveDragging = newValue }
    }
    public var endedInteractiveDragging: ((ChatListDisplayNode) -> Void)? {
        get { self.backend.endedInteractiveDragging }
        set { self.backend.endedInteractiveDragging = newValue }
    }
    public var shouldStopScrolling: ((ChatListDisplayNode, CGFloat) -> Bool)? {
        get { self.backend.shouldStopScrolling }
        set { self.backend.shouldStopScrolling = newValue }
    }
    public var isEmptyUpdated: ((ChatListNodeEmptyState, Bool, ContainedViewLayoutTransition) -> Void)? {
        get { self.backend.isEmptyUpdated }
        set { self.backend.isEmptyUpdated = newValue }
    }
    public var canExpandHiddenItems: (() -> Bool)? {
        get { self.backend.canExpandHiddenItems }
        set { self.backend.canExpandHiddenItems = newValue }
    }
    public var addedVisibleChatsWithPeerIds: (([EnginePeer.Id]) -> Void)? {
        get { self.backend.addedVisibleChatsWithPeerIds }
        set { self.backend.addedVisibleChatsWithPeerIds = newValue }
    }
    public var didBeginSelectingChats: (() -> Void)? {
        get { self.backend.didBeginSelectingChats }
        set { self.backend.didBeginSelectingChats = newValue }
    }
    public var selectionCountChanged: ((Int) -> Void)? {
        get { self.backend.selectionCountChanged }
        set { self.backend.selectionCountChanged = newValue }
    }
    public var reachedSelectionLimit: ((Int32) -> Void)? {
        get { self.backend.reachedSelectionLimit }
        set { self.backend.reachedSelectionLimit = newValue }
    }
    public var updateFloatingHeaderOffset: ((CGFloat, ContainedViewLayoutTransition) -> Void)? {
        get { self.backend.updateFloatingHeaderOffset }
        set { self.backend.updateFloatingHeaderOffset = newValue }
    }

    public var selectionLimit: Int32 {
        get { self.backend.selectionLimit }
        set { self.backend.selectionLimit = newValue }
    }
    public var startedScrollingAtUpperBound: Bool {
        get { self.backend.startedScrollingAtUpperBound }
        set { self.backend.startedScrollingAtUpperBound = newValue }
    }
    public var passthroughPeerSelection: Bool {
        get { self.backend.passthroughPeerSelection }
        set { self.backend.passthroughPeerSelection = newValue }
    }
    public var synchronousDrawingWhenNotAnimated: Bool {
        get { self.backend.synchronousDrawingWhenNotAnimated }
        set { self.backend.synchronousDrawingWhenNotAnimated = newValue }
    }
    public var tempTopInset: CGFloat {
        get { self.backend.tempTopInset }
        set { self.backend.tempTopInset = newValue }
    }
    public var scrollHeightTopInset: CGFloat {
        get { self.backend.scrollHeightTopInset }
        set { self.backend.scrollHeightTopInset = newValue }
    }

    public var isTracking: Bool { self.backend.isTracking }
    public var isDragging: Bool { self.backend.isDragging }
    public var isNavigationHidden: Bool { self.backend.isNavigationHidden }
    public var isNavigationInAFinalState: Bool { self.backend.isNavigationInAFinalState }

    public func updateState(_ f: (ChatListNodeState) -> ChatListNodeState) {
        self.backend.updateState(f)
    }
    public func setCurrentRemovingItemId(_ itemId: ChatListNodeState.ItemId?) {
        self.backend.setCurrentRemovingItemId(itemId)
    }
    func updateFilter(_ filter: ChatListFilter?) {
        self.backend.updateFilter(filter)
    }
    public func updateThemeAndStrings(theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, disableAnimations: Bool) {
        self.backend.updateThemeAndStrings(theme: theme, fontSize: fontSize, strings: strings, dateTimeFormat: dateTimeFormat, nameSortOrder: nameSortOrder, nameDisplayOrder: nameDisplayOrder, disableAnimations: disableAnimations)
    }
    public func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets, visibleTopInset: CGFloat, originalTopInset: CGFloat, storiesInset: CGFloat, inlineNavigationLocation: ChatListControllerLocation?, inlineNavigationTransitionFraction: CGFloat) {
        self.backend.displayNode.frame = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.backend.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets, visibleTopInset: visibleTopInset, originalTopInset: originalTopInset, storiesInset: storiesInset, inlineNavigationLocation: inlineNavigationLocation, inlineNavigationTransitionFraction: inlineNavigationTransitionFraction)
    }
    public func updateSelectedChatLocation(_ chatLocation: ChatLocation?, progress: CGFloat, transition: ContainedViewLayoutTransition) {
        self.backend.updateSelectedChatLocation(chatLocation, progress: progress, transition: transition)
    }
    public func scrollToPosition(_ position: ChatListNodeScrollPosition, animated: Bool = true) {
        self.backend.scrollToPosition(position, animated: animated)
    }
    @discardableResult public func scrollToOffsetFromTop(_ offset: CGFloat, animated: Bool) -> Bool {
        self.backend.scrollToOffsetFromTop(offset, animated: animated)
    }
    public func visibleContentOffset() -> ListViewVisibleContentOffset {
        self.backend.visibleContentOffset()
    }
    public func clearHighlightAnimated(_ animated: Bool) {
        self.backend.clearHighlightAnimated(animated)
    }
    public func selectChat(_ option: ChatListSelectionOption) {
        self.backend.selectChat(option)
    }
    public func revealScrollHiddenItem() {
        self.backend.revealScrollHiddenItem()
    }
    public func hasItemsToBeRevealed() -> Bool {
        self.backend.hasItemsToBeRevealed()
    }
    public func adjustScrollOffsetForNavigation(isNavigationHidden: Bool) {
        self.backend.adjustScrollOffsetForNavigation(isNavigationHidden: isNavigationHidden)
    }
    public func fixContentOffset(offset: CGFloat) {
        self.backend.fixContentOffset(offset: offset)
    }
    public func cancelTracking() {
        self.backend.cancelTracking()
    }
    public func forEachItemNode(_ f: (ASDisplayNode) -> Void) {
        self.backend.forEachItemNode(f)
    }
    public func forEachVisibleItemNode(_ f: (ASDisplayNode) -> Void) {
        self.backend.forEachVisibleItemNode(f)
    }

    public func fixNavigationSearchableScrolling(searchNode: NavigationBarSearchContentNode) -> Bool {
        self.backend.fixNavigationSearchableScrolling(searchNode: searchNode)
    }
}
