import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SGAPIToken
import SGAPIWebSettings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import TelegramNotices
import ContactsPeerItem
import ContextUI
import ItemListUI
import SearchUI
import ChatListSearchItemHeader
import PremiumUI
import AnimationCache
import MultiAnimationRenderer
import Postbox
import ChatFolderLinkPreviewScreen
import StoryContainerScreen
import ChatListHeaderComponent
import UndoUI
import NewSessionInfoScreen
import PresentationDataUtils

private final class ChatListTableContainerView: UIView {
    weak var escapeHandler: ChatListTableNode?
    
    override func accessibilityPerformEscape() -> Bool {
        return self.escapeHandler?.performAccessibilityEscape() ?? false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.escapeHandler?.hostContainerDidMoveToWindow()
    }
}

private final class ChatListAccessibilityTableView: UITableView {
    weak var escapeHandler: ChatListTableNode?
    
    override func accessibilityPerformEscape() -> Bool {
        if let escapeHandler = self.escapeHandler, escapeHandler.performAccessibilityEscape() {
            return true
        }
        return super.accessibilityPerformEscape()
    }
}

private final class ChatListHostedCell: UITableViewCell {
    private let containerNode = ASDisplayNode()
    var itemNode: ListViewItemNode?
    var currentStableId: AnyHashable?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none
        self.clipsToBounds = false
        self.contentView.clipsToBounds = false
        self.containerNode.backgroundColor = .clear
        self.contentView.addSubview(self.containerNode.view)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        if let itemNode = self.itemNode {
            itemNode.removeFromSupernode()
            itemNode.view.removeFromSuperview()
        }
        self.itemNode = nil
        self.currentStableId = nil
    }

    func setItemNode(_ itemNode: ListViewItemNode) {
        if self.itemNode !== itemNode {
            if let current = self.itemNode {
                current.removeFromSupernode()
                current.view.removeFromSuperview()
            }
            self.itemNode = itemNode
            self.containerNode.addSubnode(itemNode)
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = self.contentView.bounds
        self.containerNode.frame = bounds
        if let itemNode = self.itemNode, bounds.width > 0.0, bounds.height > 0.0 {
            itemNode.frame = bounds
            itemNode.layout()
        }
    }
}

private struct ChatListTableRow {
    let stableId: ChatListNodeEntryId
    let entry: ChatListNodeEntry
    let item: ListViewItem
    let approximateHeight: CGFloat
}

private func chatListTableApproximateHeight(entry: ChatListNodeEntry) -> CGFloat {
    switch entry {
    case .HeaderEntry, .HoleEntry:
        return 0.0
    case .SectionHeader:
        return 28.0
    case .ArchiveIntro:
        return 208.0
    case .EmptyIntro:
        return 220.0
    case .Notice:
        return 124.0
    case .AdditionalCategory:
        return 44.0
    case .GroupReferenceEntry:
        return 74.0
    case .PeerEntry:
        return 74.0
    case .ContactEntry:
        return 60.0
    }
}

private func mappedChatListTableItem(context: AccountContext, nodeInteraction: ChatListNodeInteraction, location: ChatListControllerLocation, isPremium: Bool, filterData: ChatListItemFilterData?, chatListFilters: [ChatListFilter]?, mode: ChatListNodeMode, isPeerEnabled: ((EnginePeer) -> Bool)?, entry: ChatListNodeEntry) -> ListViewItem {
    switch entry {
    case .HeaderEntry:
        return ChatListEmptyHeaderItem()
    case let .AdditionalCategory(_, id, title, image, appearance, selected, presentationData):
        var header: ChatListSearchItemHeader?
        if case .peerType = mode {
        } else if case .action = appearance {
            header = ChatListSearchItemHeader(type: .orImportIntoAnExistingGroup, theme: presentationData.theme, strings: presentationData.strings, actionTitle: nil, action: nil)
        }
        return ChatListAdditionalCategoryItem(
            presentationData: ItemListPresentationData(theme: presentationData.theme, fontSize: presentationData.fontSize, strings: presentationData.strings, nameDisplayOrder: presentationData.nameDisplayOrder, dateTimeFormat: presentationData.dateTimeFormat),
            context: context,
            title: title,
            image: image,
            appearance: appearance,
            isSelected: selected,
            header: header,
            action: {
                nodeInteraction.additionalCategorySelected(id)
            }
        )
    case let .PeerEntry(peerEntry):
        return ChatListItem(
            presentationData: peerEntry.presentationData,
            context: context,
            chatListLocation: location,
            filterData: filterData,
            index: peerEntry.index,
            content: .peer(ChatListItemContent.PeerData(
                messages: peerEntry.messages,
                peer: peerEntry.peer,
                threadInfo: peerEntry.threadInfo,
                combinedReadState: peerEntry.readState,
                isRemovedFromTotalUnreadCount: peerEntry.isRemovedFromTotalUnreadCount,
                presence: peerEntry.presence,
                hasUnseenMentions: peerEntry.hasUnseenMentions,
                hasUnseenReactions: peerEntry.hasUnseenReactions,
                draftState: peerEntry.draftState,
                mediaDraftContentType: peerEntry.mediaDraftContentType,
                inputActivities: peerEntry.inputActivities,
                promoInfo: peerEntry.promoInfo,
                ignoreUnreadBadge: false,
                displayAsMessage: false,
                hasFailedMessages: peerEntry.hasFailedMessages,
                forumTopicData: peerEntry.forumTopicData,
                topForumTopicItems: peerEntry.topForumTopicItems,
                autoremoveTimeout: peerEntry.autoremoveTimeout,
                storyState: peerEntry.storyState.flatMap { storyState in
                    ChatListItemContent.StoryState(stats: storyState.stats, hasUnseenCloseFriends: storyState.hasUnseenCloseFriends)
                },
                requiresPremiumForMessaging: peerEntry.requiresPremiumForMessaging,
                displayAsTopicList: peerEntry.displayAsTopicList,
                tags: chatListItemTags(location: location, accountPeerId: context.account.peerId, isPremium: isPremium, peer: peerEntry.peer.chatMainPeer, isUnread: peerEntry.readState?.isUnread ?? false, isMuted: peerEntry.isRemovedFromTotalUnreadCount, isContact: peerEntry.isContact, hasUnseenMentions: peerEntry.hasUnseenMentions, chatListFilters: chatListFilters)
            )),
            editing: peerEntry.editing,
            hasActiveRevealControls: peerEntry.hasActiveRevealControls,
            selected: peerEntry.selected,
            header: nil,
            enabledContextActions: .auto,
            hiddenOffset: peerEntry.threadInfo?.isHidden == true && !peerEntry.revealed,
            interaction: nodeInteraction
        )
    case let .HoleEntry(_, theme):
        return ChatListHoleItem(theme: theme)
    case let .GroupReferenceEntry(groupReferenceEntry):
        return ChatListItem(
            presentationData: groupReferenceEntry.presentationData,
            context: context,
            chatListLocation: location,
            filterData: filterData,
            index: groupReferenceEntry.index,
            content: .groupReference(ChatListItemContent.GroupReferenceData(
                groupId: groupReferenceEntry.groupId,
                peers: groupReferenceEntry.peers,
                message: groupReferenceEntry.message,
                unreadCount: groupReferenceEntry.unreadCount,
                hiddenByDefault: groupReferenceEntry.hiddenByDefault,
                storyState: groupReferenceEntry.storyState.flatMap { storyState in
                    ChatListItemContent.StoryState(stats: storyState.stats, hasUnseenCloseFriends: storyState.hasUnseenCloseFriends)
                }
            )),
            editing: groupReferenceEntry.editing,
            hasActiveRevealControls: false,
            selected: false,
            header: nil,
            enabledContextActions: .auto,
            hiddenOffset: groupReferenceEntry.hiddenByDefault && !groupReferenceEntry.revealed,
            interaction: nodeInteraction
        )
    case let .ContactEntry(contactEntry):
        let presentationData = contactEntry.presentationData
        return ContactsPeerItem(
            presentationData: ItemListPresentationData(theme: presentationData.theme, fontSize: presentationData.fontSize, strings: presentationData.strings, nameDisplayOrder: presentationData.nameDisplayOrder, dateTimeFormat: presentationData.dateTimeFormat),
            sortOrder: presentationData.nameSortOrder,
            displayOrder: presentationData.nameDisplayOrder,
            context: context,
            peerMode: .generalSearch(isSavedMessages: false),
            peer: .peer(peer: contactEntry.peer, chatPeer: contactEntry.peer),
            status: .presence(contactEntry.presence, contactEntry.presentationData.dateTimeFormat),
            enabled: true,
            selection: .none,
            editing: ContactsPeerItemEditing(editable: false, editing: false, revealed: false),
            index: nil,
            header: nil,
            action: { _ in
                nodeInteraction.peerSelected(contactEntry.peer, nil, nil, nil, false)
            },
            disabledAction: nil,
            animationCache: nodeInteraction.animationCache,
            animationRenderer: nodeInteraction.animationRenderer
        )
    case let .ArchiveIntro(presentationData):
        return ChatListArchiveInfoItem(theme: presentationData.theme, strings: presentationData.strings)
    case let .EmptyIntro(presentationData):
        return ChatListEmptyInfoItem(theme: presentationData.theme, strings: presentationData.strings)
    case let .SectionHeader(presentationData, displayHide):
        return ChatListSectionHeaderItem(theme: presentationData.theme, strings: presentationData.strings, hide: displayHide ? {
            hideChatListContacts(context: context)
        } : nil)
    case let .Notice(presentationData, notice):
        return ChatListNoticeItem(context: context, theme: presentationData.theme, strings: presentationData.strings, notice: notice, action: { [weak nodeInteraction] action in
            switch action {
            case .activate:
                switch notice {
                case let .sgUrl(id, _, _, url, needAuth, permanent):
                    nodeInteraction?.openSGAnnouncement(id, url, needAuth, permanent)
                case .clearStorage:
                    nodeInteraction?.openStorageManagement()
                case .setupPassword:
                    nodeInteraction?.openPasswordSetup()
                case .premiumUpgrade, .premiumAnnualDiscount, .premiumRestore:
                    nodeInteraction?.openPremiumIntro()
                case .xmasPremiumGift:
                    nodeInteraction?.openPremiumGift([], nil)
                case .premiumGrace:
                    nodeInteraction?.openPremiumManagement()
                case .setupBirthday:
                    nodeInteraction?.openBirthdaySetup()
                case let .birthdayPremiumGift(peers, birthdays):
                    nodeInteraction?.openPremiumGift(peers, birthdays)
                case .reviewLogin:
                    break
                case let .starsSubscriptionLowBalance(amount, _):
                    nodeInteraction?.openStarsTopup(amount.value)
                case .setupPhoto:
                    nodeInteraction?.openPhotoSetup()
                case .accountFreeze:
                    nodeInteraction?.openAccountFreezeInfo()
                case let .link(_, url, _, _):
                    nodeInteraction?.openUrl(url)
                }
            case .hide:
                nodeInteraction?.dismissNotice(notice)
            case let .buttonChoice(isPositive):
                if case let .reviewLogin(newSessionReview, _) = notice {
                    nodeInteraction?.performActiveSessionAction(newSessionReview, isPositive)
                }
            }
        })
    }
}

final class ChatListTableNode: ASDisplayNode, ChatListDisplayNodeBackend, UITableViewDataSource, UITableViewDelegate, UIScrollViewDelegate {
    private let getNavigationController: (() -> NavigationController?)?
    private let context: AccountContext
    private let location: ChatListControllerLocation
    private let mode: ChatListNodeMode
    private let animationCache: AnimationCache
    private let animationRenderer: MultiAnimationRenderer
    private let tableView: UITableView
    private let selectionProxyListView = ListView()

    private var currentRows: [ChatListTableRow] = []
    private var currentView: ChatListNodeView?
    private var nodeCache: [AnyHashable: ListViewItemNode] = [:]
    private var itemCache: [AnyHashable: ListViewItem] = [:]
    private var currentLocation: ChatListNodeLocation?
    private let chatListLocation = ValuePromise<ChatListNodeLocation>()
    private let chatListDisposable = MetaDisposable()
    private let _ready = ValuePromise<Bool>(false)
    private let _contentsReady = ValuePromise<Bool>(false)
    private var didSetReady = false
    private var didSetContentsReady = false
    private let statePromise: ValuePromise<ChatListNodeState>
    private(set) var currentState: ChatListNodeState
    private var visibleTopInset: CGFloat?
    private var originalTopInset: CGFloat?
    private var lastUpdateSizeAndInsets: ListViewUpdateSizeAndInsets?
    private var didSetupInitialContentOffset = false
    private var interaction: ChatListNodeInteraction!
    private var currentAppliedFilter: ChatListFilter?

    private enum DeferredTableContentUpdate {
        case none
        case refreshVisible
        case reloadAll
    }

    private var deferredTableContentUpdate: DeferredTableContentUpdate = .none

    var peerSelected: ((EnginePeer, Int64?, Bool, Bool, ChatListNodeEntryPromoInfo?) -> Void)?
    var disabledPeerSelected: ((EnginePeer, Int64?, ChatListDisabledPeerReason) -> Void)?
    var additionalCategorySelected: ((Int) -> Void)?
    var groupSelected: ((EngineChatList.Group) -> Void)?
    var addContact: ((String) -> Void)?
    var activateSearch: (() -> Void)?
    var deletePeerChat: ((EnginePeer.Id, Bool) -> Void)?
    var deletePeerThread: ((EnginePeer.Id, Int64) -> Void)?
    var setPeerThreadStopped: ((EnginePeer.Id, Int64, Bool) -> Void)?
    var setPeerThreadPinned: ((EnginePeer.Id, Int64, Bool) -> Void)?
    var setPeerThreadHidden: ((EnginePeer.Id, Int64, Bool) -> Void)?
    var updatePeerGrouping: ((EnginePeer.Id, Bool) -> Void)?
    var presentAlert: ((String) -> Void)?
    var present: ((ViewController) -> Void)?
    var push: ((ViewController) -> Void)?
    var toggleArchivedFolderHiddenByDefault: (() -> Void)?
    var hidePsa: ((EnginePeer.Id) -> Void)?
    var activateChatPreview: ((ChatListItem, Int64?, ASDisplayNode, ContextGesture?, CGPoint?) -> Void)?
    var openStories: ((ChatListNode.OpenStoriesSubject, ASDisplayNode?) -> Void)?
    var openBirthdaySetup: (() -> Void)?
    var openPremiumManagement: (() -> Void)?
    var openStarsTopup: ((Int64?) -> Void)?
    var openWebApp: ((TelegramUser) -> Void)?
    var openPhotoSetup: (() -> Void)?
    var openAdInfo: ((ASDisplayNode, AdPeer) -> Void)?
    var openAccountFreezeInfo: (() -> Void)?
    var contentOffsetChanged: ((ListViewVisibleContentOffset) -> Void)?
    var contentScrollingEnded: ((ChatListDisplayNode) -> Bool)?
    var didBeginInteractiveDragging: ((ChatListDisplayNode) -> Void)?
    var endedInteractiveDragging: ((ChatListDisplayNode) -> Void)?
    var shouldStopScrolling: ((ChatListDisplayNode, CGFloat) -> Bool)?
    var isEmptyUpdated: ((ChatListNodeEmptyState, Bool, ContainedViewLayoutTransition) -> Void)?
    var canExpandHiddenItems: (() -> Bool)?
    var addedVisibleChatsWithPeerIds: (([EnginePeer.Id]) -> Void)?
    var didBeginSelectingChats: (() -> Void)?
    var selectionCountChanged: ((Int) -> Void)?
    var reachedSelectionLimit: ((Int32) -> Void)?
    var updateFloatingHeaderOffset: ((CGFloat, ContainedViewLayoutTransition) -> Void)?

    var selectionLimit: Int32 = 100
    var startedScrollingAtUpperBound: Bool = false
    var passthroughPeerSelection: Bool = false
    var synchronousDrawingWhenNotAnimated: Bool = false
    var tempTopInset: CGFloat = 0.0 {
        didSet {
            self.contentOffsetChanged?(self.visibleContentOffset())
        }
    }
    var scrollHeightTopInset: CGFloat = ChatListNavigationBar.searchScrollHeight

    let preloadItems = Promise<[ChatHistoryPreloadItem]>([])
    let isMainTab = ValuePromise<Bool>(false, ignoreRepeated: true)

    var displayNode: ASDisplayNode { self }
    var ready: Signal<Bool, NoError> { self._ready.get() }
    var contentsReady: Signal<Bool, NoError> { self._contentsReady.get() }
    var state: Signal<ChatListNodeState, NoError> { self.statePromise.get() }
    var chatListFilter: ChatListFilter? { self.currentAppliedFilter }
    var entryPeerIds: [EnginePeer.Id] {
        return self.currentView?.filteredEntries.compactMap { entry in
            if case let .PeerEntry(peerEntry) = entry, case let .chatList(index) = peerEntry.index {
                return index.messageIndex.id.peerId
            }
            return nil
        } ?? []
    }
    var entriesCount: Int { self.currentView?.filteredEntries.count ?? 0 }
    var scrollToTopOption: Signal<ChatListGlobalScrollOption, NoError> {
        return self.visibleContentOffset().isAtTop ? .single(.none) : .single(.top)
    }
    var isTracking: Bool { self.tableView.isTracking }
    var isDragging: Bool { self.tableView.isDragging }
    var isNavigationHidden: Bool {
        switch self.visibleContentOffset() {
        case let .known(value):
            return abs(value) >= self.scrollHeightTopInset - 1.0
        case .none:
            return false
        case .unknown:
            return true
        }
    }
    var isNavigationInAFinalState: Bool { true }

    init(getNavigationController: (() -> NavigationController?)? = nil, context: AccountContext, location: ChatListControllerLocation, chatListFilter: ChatListFilter?, previewing: Bool, fillPreloadItems: Bool, mode: ChatListNodeMode, isPeerEnabled: ((EnginePeer) -> Bool)?, theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, animationCache: AnimationCache, animationRenderer: MultiAnimationRenderer, disableAnimations: Bool, isInlineMode: Bool, autoSetReady: Bool, isMainTab: Bool?) {
        self.getNavigationController = getNavigationController
        self.context = context
        self.location = location
        self.mode = mode
        self.animationCache = animationCache
        self.animationRenderer = animationRenderer
        self.tableView = ChatListAccessibilityTableView(frame: .zero, style: .plain)

        self.currentState = ChatListNodeState(
            presentationData: ChatListPresentationData(theme: theme, fontSize: fontSize, strings: strings, dateTimeFormat: dateTimeFormat, nameSortOrder: nameSortOrder, nameDisplayOrder: nameDisplayOrder, disableAnimations: disableAnimations),
            editing: false,
            peerIdWithRevealedOptions: nil,
            selectedPeerIds: Set(),
            foundPeers: [],
            selectedPeerMap: [:],
            selectedAdditionalCategoryIds: Set(),
            peerInputActivities: nil,
            pendingRemovalItemIds: Set(),
            pendingClearHistoryPeerIds: Set(),
            hiddenItemShouldBeTemporaryRevealed: false,
            hiddenPsaPeerId: nil,
            selectedThreadIds: Set(),
            archiveStoryState: nil
        )
        self.statePromise = ValuePromise(self.currentState, ignoreRepeated: true)

        super.init()

        if let isMainTab {
            self.isMainTab.set(isMainTab)
        }

        self.backgroundColor = theme.chatList.backgroundColor
        self.setViewBlock({
            return ChatListTableContainerView()
        })
        (self.tableView as? ChatListAccessibilityTableView)?.escapeHandler = self
        (self.view as? ChatListTableContainerView)?.escapeHandler = self

        self.tableView.backgroundColor = .clear
        self.tableView.separatorStyle = .none
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.showsVerticalScrollIndicator = true
        self.tableView.register(ChatListHostedCell.self, forCellReuseIdentifier: "c")
        self.view.addSubview(self.tableView)

        self.interaction = ChatListNodeInteraction(
            context: context,
            animationCache: animationCache,
            animationRenderer: animationRenderer,
            activateSearch: { [weak self] in self?.activateSearch?() },
            openSGAnnouncement: { [weak self] announcementId, url, needAuth, permanent in
                guard let self else {
                    return
                }
                if needAuth {
                    let _ = (getSGSettingsURL(context: self.context, url: url)
                    |> deliverOnMainQueue).start(next: { [weak self] url in
                        guard let self else {
                            return
                        }
                        self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url, forceExternal: false, presentationData: self.context.sharedContext.currentPresentationData.with { $0 }, navigationController: self.getNavigationController?(), dismissInput: {})
                    })
                } else {
                    Queue.mainQueue().async { [weak self] in
                        guard let self else {
                            return
                        }
                        self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url, forceExternal: false, presentationData: self.context.sharedContext.currentPresentationData.with { $0 }, navigationController: self.getNavigationController?(), dismissInput: {})
                    }
                }
                if !permanent {
                    Queue.mainQueue().after(0.6) { [weak self] in
                        if let self {
                            dismissSGProvidedSuggestion(suggestionId: announcementId)
                            postSGWebSettingsInteractivelly(context: self.context, data: ["skip_announcement_id": announcementId])
                        }
                    }
                }
            },
            peerSelected: { [weak self] peer, _, threadId, promoInfo, activateInput in
                self?.peerSelected?(peer, threadId, false, activateInput, promoInfo)
            },
            disabledPeerSelected: { [weak self] peer, threadId, reason in
                self?.disabledPeerSelected?(peer, threadId, reason)
            },
            togglePeerSelected: { [weak self] peer, _ in
                guard let self else { return }
                self.updateState { state in
                    var state = state
                    if state.selectedPeerIds.contains(peer.id) {
                        state.selectedPeerIds.remove(peer.id)
                    } else {
                        state.selectedPeerIds.insert(peer.id)
                    }
                    return state
                }
            },
            togglePeersSelection: { _, _ in },
            additionalCategorySelected: { [weak self] id in self?.additionalCategorySelected?(id) },
            messageSelected: { [weak self] peer, threadId, _, promoInfo in
                self?.peerSelected?(peer, threadId, false, false, promoInfo)
            },
            groupSelected: { [weak self] group in self?.groupSelected?(group) },
            addContact: { [weak self] value in self?.addContact?(value) },
            setPeerIdWithRevealedOptions: { _, _ in },
            setItemPinned: { _, _ in },
            setPeerMuted: { _, _ in },
            setPeerThreadMuted: { _, _, _ in },
            deletePeer: { [weak self] peerId, joined in self?.deletePeerChat?(peerId, joined) },
            deletePeerThread: { [weak self] peerId, threadId in self?.deletePeerThread?(peerId, threadId) },
            setPeerThreadStopped: { [weak self] peerId, threadId, value in self?.setPeerThreadStopped?(peerId, threadId, value) },
            setPeerThreadPinned: { [weak self] peerId, threadId, value in self?.setPeerThreadPinned?(peerId, threadId, value) },
            setPeerThreadHidden: { [weak self] peerId, threadId, value in self?.setPeerThreadHidden?(peerId, threadId, value) },
            updatePeerGrouping: { [weak self] peerId, grouped in self?.updatePeerGrouping?(peerId, grouped) },
            togglePeerMarkedUnread: { _, _ in },
            toggleArchivedFolderHiddenByDefault: { [weak self] in self?.toggleArchivedFolderHiddenByDefault?() },
            toggleThreadsSelection: { _, _ in },
            hidePsa: { [weak self] peerId in self?.hidePsa?(peerId) },
            activateChatPreview: { [weak self] item, threadId, node, gesture, point in
                self?.activateChatPreview?(item, threadId, node, gesture, point)
            },
            present: { [weak self] controller in self?.present?(controller) },
            openForumThread: { _, _ in },
            openStorageManagement: {},
            openPasswordSetup: {},
            openPremiumIntro: {},
            openPremiumGift: { _, _ in },
            openPremiumManagement: { [weak self] in self?.openPremiumManagement?() },
            openActiveSessions: {},
            openBirthdaySetup: { [weak self] in self?.openBirthdaySetup?() },
            performActiveSessionAction: { _, _ in },
            openChatFolderUpdates: {},
            hideChatFolderUpdates: {},
            openStories: { [weak self] subject, node in self?.openStories?(subject, node) },
            openStarsTopup: { [weak self] amount in self?.openStarsTopup?(amount) },
            dismissNotice: { _ in },
            editPeer: { _ in },
            openWebApp: { [weak self] user in self?.openWebApp?(user) },
            openPhotoSetup: { [weak self] in self?.openPhotoSetup?() },
            openAdInfo: { [weak self] node, ad in self?.openAdInfo?(node, ad) },
            openAccountFreezeInfo: { [weak self] in self?.openAccountFreezeInfo?() },
            openUrl: { [weak self] url in
                guard let self else {
                    return
                }
                let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: self.context.sharedContext.mainWindow?.viewController as? NavigationController, dismissInput: {})
            }
        )

        let shouldLoadCanMessagePeer: Bool
        if case .peers = mode {
            shouldLoadCanMessagePeer = true
        } else {
            shouldLoadCanMessagePeer = false
        }
        let chatListViewUpdate = self.chatListLocation.get()
        |> distinctUntilChanged
        |> mapToSignal { listLocation -> Signal<(ChatListNodeViewUpdate, ChatListFilter?), NoError> in
            chatListViewForLocation(chatListLocation: location, location: listLocation, account: context.account, shouldLoadCanMessagePeer: shouldLoadCanMessagePeer)
            |> map { ($0, listLocation.filter) }
        }

        let hideArchivedFolderByDefault = context.account.postbox.preferencesView(keys: [ApplicationSpecificPreferencesKeys.chatArchiveSettings])
        |> map { view -> Bool in
            let settings: ChatArchiveSettings = view.values[ApplicationSpecificPreferencesKeys.chatArchiveSettings]?.get(ChatArchiveSettings.self) ?? .default
            return settings.isHiddenByDefault
        }
        |> distinctUntilChanged

        let contacts = Signal<[ChatListContactPeer], NoError>.single([])

        let chatListFilters = combineLatest(queue: .mainQueue(),
            context.engine.peers.updatedChatListFilters(),
            context.engine.data.subscribe(TelegramEngine.EngineData.Item.ChatList.FiltersDisplayTags())
        )
        |> map { filters, displayTags -> [ChatListFilter]? in
            if !displayTags {
                return nil
            }
            return filters.filter { $0.id != chatListFilter?.id }
        }
        |> distinctUntilChanged

        let accountIsPremium = context.engine.data.subscribe(
            TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)
        )
        |> map { $0?.isPremium ?? false }
        |> distinctUntilChanged

        let previousView = Atomic<ChatListNodeView?>(value: nil)
        let previousChatListFilters = Atomic<[ChatListFilter]?>(value: nil)
        let previousAccountIsPremium = Atomic<Bool?>(value: nil)

        let applied = (combineLatest(queue: Queue.mainQueue(),
            hideArchivedFolderByDefault,
            chatListViewUpdate,
            self.statePromise.get(),
            contacts,
            chatListFilters,
            accountIsPremium
        )
        |> deliverOnMainQueue)
        .startStrict(next: { [weak self] hideArchivedFolderByDefault, updateAndFilter, state, contacts, chatListFilters, accountIsPremium in
            guard let self else { return }
            let (update, filter) = updateAndFilter

            let (rawEntries, isLoading) = chatListNodeEntriesForView(
                view: update.list,
                state: state,
                savedMessagesPeer: nil,
                foundPeers: state.foundPeers,
                hideArchivedFolderByDefault: hideArchivedFolderByDefault,
                displayArchiveIntro: false,
                notice: nil,
                mode: mode,
                chatListLocation: location,
                contacts: contacts,
                accountPeerId: context.account.peerId,
                isMainTab: location == .chatList(groupId: .root) && chatListFilter == nil
            )

            let processedEntries = rawEntries.isEmpty ? [.HeaderEntry] : rawEntries
            let processedView = ChatListNodeView(originalList: update.list, filteredEntries: processedEntries, isLoading: isLoading, filter: filter)
            print("[ChatListTableNode] update type=\(update.type) rawEntries=\(rawEntries.count) processedEntries=\(processedEntries.count) isLoading=\(isLoading) filter=\(String(describing: filter?.id))")
            let _ = previousView.swap(processedView)
            let _ = previousChatListFilters.swap(chatListFilters)
            let _ = previousAccountIsPremium.swap(accountIsPremium)

            let filterData = filter.flatMap { filter -> ChatListItemFilterData? in
                if case let .filter(_, _, _, data) = filter {
                    return ChatListItemFilterData(excludesArchived: data.excludeArchived)
                } else {
                    return nil
                }
            }

            let displayEntries = processedEntries.reversed()
            let rows = displayEntries.map { entry -> ChatListTableRow in
                let item = mappedChatListTableItem(
                    context: context,
                    nodeInteraction: self.interaction,
                    location: location,
                    isPremium: accountIsPremium,
                    filterData: filterData,
                    chatListFilters: chatListFilters,
                    mode: mode,
                    isPeerEnabled: isPeerEnabled,
                    entry: entry
                )
                let preferredHeight = chatListTableApproximateHeight(entry: entry)
                let itemHeight = max(0.0, item.approximateHeight)
                let resolvedHeight: CGFloat
                switch entry {
                case .HeaderEntry, .HoleEntry:
                    resolvedHeight = preferredHeight
                default:
                    // Match ListView: e.g. hidden forum threads report approximateHeight 0 (see ChatListItem)
                    // but preferredHeight is still the nominal row height — using 74pt would show an empty gap.
                    if itemHeight <= CGFloat.ulpOfOne {
                        resolvedHeight = 0.0
                    } else {
                        resolvedHeight = preferredHeight > 0.0 ? preferredHeight : itemHeight
                    }
                }
                return ChatListTableRow(
                    stableId: entry.stableId,
                    entry: entry,
                    item: item,
                    approximateHeight: resolvedHeight
                )
            }
            print("[ChatListTableNode] rows=\(rows.count) firstStableId=\(rows.first.map { String(describing: $0.stableId) } ?? "nil")")

            let previousStableIds = Set(self.currentRows.map(\.stableId))
            let oldOrder = self.currentRows.map(\.stableId)
            let newOrder = rows.map(\.stableId)
            let sameRowOrder = oldOrder.count == newOrder.count && !zip(oldOrder, newOrder).contains { $0.0 != $0.1 }
            let oldRowsSnapshot = self.currentRows
            let sameHeights = sameRowOrder && oldRowsSnapshot.count == rows.count && !zip(oldRowsSnapshot, rows).contains { old, new in
                abs(old.approximateHeight - new.approximateHeight) > 0.5
            }

            self.currentRows = rows
            self.currentView = processedView
            self.currentAppliedFilter = filter
            let reloadAll = !(sameRowOrder && sameHeights)
            self.performTableContentUpdate(reloadAll: reloadAll)
            print("[ChatListTableNode] table update sameOrder=\(sameRowOrder) contentInset=\(self.tableView.contentInset) bounds=\(self.tableView.bounds)")
            self.updateEmptyState(view: processedView)
            self.updatePreloadItems(view: processedView)

            let insertedPeerIds = rows.compactMap { row -> EnginePeer.Id? in
                guard !previousStableIds.contains(row.stableId) else {
                    return nil
                }
                if case let .PeerEntry(peerEntry) = row.entry, case let .chatList(index) = peerEntry.index {
                    return index.messageIndex.id.peerId
                }
                return nil
            }
            if !insertedPeerIds.isEmpty {
                self.addedVisibleChatsWithPeerIds?(insertedPeerIds)
            }

            if !self.didSetReady {
                self.didSetReady = true
                self._ready.set(true)
            }
            if !self.didSetContentsReady {
                self.didSetContentsReady = true
                self._contentsReady.set(true)
            }
            self.contentOffsetChanged?(self.visibleContentOffset())
        })

        self.chatListDisposable.set(applied)
        self.chatListLocation.set(.initial(count: 50, filter: chatListFilter))
    }

    deinit {
        self.chatListDisposable.dispose()
    }

    override func layout() {
        super.layout()
        self.tableView.frame = self.bounds
        print("[ChatListTableNode] layout bounds=\(self.bounds) tableFrame=\(self.tableView.frame)")
        self.flushDeferredTableContentUpdateIfNeeded()
    }

    fileprivate func hostContainerDidMoveToWindow() {
        self.flushDeferredTableContentUpdateIfNeeded()
    }

    private var canLayOutTableViewContent: Bool {
        guard self.tableView.window != nil else {
            return false
        }
        return self.tableView.bounds.width >= 1.0 && self.tableView.bounds.height >= 1.0
    }

    private func scheduleDeferredContentUpdate(_ kind: DeferredTableContentUpdate) {
        switch kind {
        case .none:
            break
        case .reloadAll:
            self.deferredTableContentUpdate = .reloadAll
        case .refreshVisible:
            if self.deferredTableContentUpdate != .reloadAll {
                self.deferredTableContentUpdate = .refreshVisible
            }
        }
    }

    private func performTableContentUpdate(reloadAll: Bool) {
        let needReload = reloadAll || self.deferredTableContentUpdate == .reloadAll
        if self.canLayOutTableViewContent {
            self.deferredTableContentUpdate = .none
            if needReload {
                self.tableView.reloadData()
            } else {
                self.refreshVisibleTableRows()
            }
        } else {
            self.scheduleDeferredContentUpdate(needReload ? .reloadAll : .refreshVisible)
        }
    }

    private func flushDeferredTableContentUpdateIfNeeded() {
        guard self.canLayOutTableViewContent, self.deferredTableContentUpdate != .none else {
            return
        }
        let kind = self.deferredTableContentUpdate
        self.deferredTableContentUpdate = .none
        switch kind {
        case .none:
            break
        case .refreshVisible:
            self.refreshVisibleTableRows()
        case .reloadAll:
            self.tableView.reloadData()
        }
    }

    func updateState(_ f: (ChatListNodeState) -> ChatListNodeState) {
        let updated = f(self.currentState)
        if updated != self.currentState {
            self.currentState = updated
            self.statePromise.set(updated)
            self.selectionCountChanged?(updated.selectedPeerIds.count)
        }
    }

    func setCurrentRemovingItemId(_ itemId: ChatListNodeState.ItemId?) {
    }

    func updateFilter(_ filter: ChatListFilter?) {
        self.chatListLocation.set(.initial(count: 50, filter: filter))
    }

    func updateThemeAndStrings(theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, disableAnimations: Bool) {
        self.updateState { state in
            var state = state
            state.presentationData = ChatListPresentationData(theme: theme, fontSize: fontSize, strings: strings, dateTimeFormat: dateTimeFormat, nameSortOrder: nameSortOrder, nameDisplayOrder: nameDisplayOrder, disableAnimations: disableAnimations)
            return state
        }
        self.backgroundColor = theme.chatList.backgroundColor
        self.performTableContentUpdate(reloadAll: true)
    }

    func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets, visibleTopInset: CGFloat, originalTopInset: CGFloat, storiesInset: CGFloat, inlineNavigationLocation: ChatListControllerLocation?, inlineNavigationTransitionFraction: CGFloat) {
        self.lastUpdateSizeAndInsets = updateSizeAndInsets
        self.visibleTopInset = visibleTopInset
        self.originalTopInset = originalTopInset
        self.frame = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.bounds = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.tableView.frame = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.tableView.contentInset = updateSizeAndInsets.insets
        self.tableView.scrollIndicatorInsets = updateSizeAndInsets.insets
        let targetOffsetY = -updateSizeAndInsets.insets.top + self.tempTopInset
        print("[ChatListTableNode] updateLayout size=\(updateSizeAndInsets.size) insets=\(updateSizeAndInsets.insets) targetOffsetY=\(targetOffsetY)")
        if !self.didSetupInitialContentOffset {
            self.didSetupInitialContentOffset = true
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: targetOffsetY), animated: false)
        } else if case let .known(currentOffset) = self.visibleContentOffset(), abs(currentOffset) < 1.0 {
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: targetOffsetY), animated: false)
        }
        transition.updateFrame(node: self, frame: CGRect(origin: .zero, size: updateSizeAndInsets.size))
        self.updateFloatingHeaderOffset?(visibleTopInset, transition)
        self.flushDeferredTableContentUpdateIfNeeded()
    }

    func updateSelectedChatLocation(_ chatLocation: ChatLocation?, progress: CGFloat, transition: ContainedViewLayoutTransition) {
        if let chatLocation {
            self.interaction.highlightedChatLocation = ChatListHighlightedLocation(location: chatLocation, progress: progress)
        } else {
            self.interaction.highlightedChatLocation = nil
        }
        for case let cell as ChatListHostedCell in self.tableView.visibleCells {
            (cell.itemNode as? ChatListItemNode)?.updateIsHighlighted(transition: transition)
        }
    }

    func scrollToPosition(_ position: ChatListNodeScrollPosition, animated: Bool) {
        switch position {
        case let .top(adjustForTempInset):
            let offset = adjustForTempInset ? self.tempTopInset : 0.0
            let _ = self.scrollToOffsetFromTop(offset, animated: animated)
        }
    }

    @discardableResult func scrollToOffsetFromTop(_ offset: CGFloat, animated: Bool) -> Bool {
        let y = -self.tableView.adjustedContentInset.top + offset + self.tempTopInset
        self.tableView.setContentOffset(CGPoint(x: 0.0, y: y), animated: animated)
        return true
    }

    func visibleContentOffset() -> ListViewVisibleContentOffset {
        let adjusted = self.tableView.contentOffset.y + self.tableView.adjustedContentInset.top - self.tempTopInset
        return .known(adjusted)
    }

    func clearHighlightAnimated(_ animated: Bool) {
        if let indexPath = self.tableView.indexPathForSelectedRow {
            self.tableView.deselectRow(at: indexPath, animated: animated)
        }
    }

    func selectChat(_ option: ChatListSelectionOption) {
        switch option {
        case .peerId:
            break
        case .index, .previous, .next:
            break
        }
    }

    func revealScrollHiddenItem() {
        guard self.hasItemsToBeRevealed() else {
            return
        }
        self.updateState { state in
            var state = state
            state.hiddenItemShouldBeTemporaryRevealed = true
            return state
        }
    }

    func hasItemsToBeRevealed() -> Bool {
        guard let currentView = self.currentView else {
            return false
        }
        for entry in currentView.filteredEntries {
            switch entry {
            case let .PeerEntry(peerEntry):
                if peerEntry.threadInfo?.isHidden == true {
                    return true
                }
            case let .GroupReferenceEntry(groupReferenceEntry):
                if groupReferenceEntry.hiddenByDefault {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    func adjustScrollOffsetForNavigation(isNavigationHidden: Bool) {
        if self.isNavigationHidden == isNavigationHidden {
            return
        }
        if isNavigationHidden {
            let _ = self.scrollToOffsetFromTop(-self.scrollHeightTopInset, animated: false)
        } else {
            let _ = self.scrollToOffsetFromTop(0.0, animated: false)
        }
    }

    func fixContentOffset(offset: CGFloat) {
        let _ = self.scrollToOffsetFromTop(offset, animated: false)
    }

    func cancelTracking() {
    }

    fileprivate func performAccessibilityEscape() -> Bool {
        if let navigationController = self.getNavigationController?(), navigationController.accessibilityPerformEscape() {
            return true
        }
        
        var responder: UIResponder? = self.view
        while let current = responder {
            if let navigationController = current as? NavigationController, navigationController.accessibilityPerformEscape() {
                return true
            }
            if let viewController = current as? UIViewController, let navigationController = viewController.navigationController as? NavigationController, navigationController.accessibilityPerformEscape() {
                return true
            }
            responder = current.next
        }
        
        if let navigationController = self.context.sharedContext.mainWindow?.viewController as? NavigationController {
            return navigationController.accessibilityPerformEscape()
        }
        
        return false
    }

    func fixNavigationSearchableScrolling(searchNode: NavigationBarSearchContentNode) -> Bool {
        if searchNode.expansionProgress > 0.0 && searchNode.expansionProgress < 1.0 {
            let targetProgress: CGFloat
            let offsetFromTop: CGFloat
            if searchNode.expansionProgress < 0.6 {
                offsetFromTop = -navigationBarSearchContentHeight
                targetProgress = 0.0
            } else {
                offsetFromTop = 0.0
                targetProgress = 1.0
            }
            searchNode.updateExpansionProgress(targetProgress, animated: true)
            _ = self.scrollToOffsetFromTop(offsetFromTop, animated: true)
            return true
        }
        return false
    }

    func forEachItemNode(_ f: (ASDisplayNode) -> Void) {
        for case let cell as ChatListHostedCell in self.tableView.visibleCells {
            if let itemNode = cell.itemNode {
                f(itemNode)
            }
        }
    }

    func forEachVisibleItemNode(_ f: (ASDisplayNode) -> Void) {
        self.forEachItemNode(f)
    }

    private func copyAccessibility(from itemNode: ListViewItemNode, to cell: ChatListHostedCell) {
        cell.accessibilityCustomActions = itemNode.view.accessibilityCustomActions
        cell.isAccessibilityElement = itemNode.view.isAccessibilityElement
        cell.accessibilityLabel = itemNode.view.accessibilityLabel
        cell.accessibilityValue = itemNode.view.accessibilityValue
        cell.accessibilityTraits = itemNode.view.accessibilityTraits
    }

    /// Applies row data synchronously for cached nodes when possible. `ContactsPeerItemNode` falls back to async `updateNode` because its `layoutForParams` does not bind a new `ListViewItem`.
    private func syncConfigureCachedNode(
        cell: ChatListHostedCell,
        row: ChatListTableRow,
        itemNode: ListViewItemNode,
        tableView: UITableView,
        previousItem: ListViewItem?,
        nextItem: ListViewItem?
    ) -> Bool {
        if itemNode is ContactsPeerItemNode {
            return false
        }
        let width = max(1.0, tableView.bounds.width)
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: row.approximateHeight)
        if let chatItem = row.item as? ChatListItem, let chatNode = itemNode as? ChatListItemNode {
            chatNode.setupItem(item: chatItem, synchronousLoads: true)
            chatNode.layoutForParams(params, item: chatItem, previousItem: previousItem, nextItem: nextItem)
        } else {
            itemNode.layoutForParams(params, item: row.item, previousItem: previousItem, nextItem: nextItem)
        }
        itemNode.frame = CGRect(origin: .zero, size: CGSize(width: width, height: row.approximateHeight))
        cell.setItemNode(itemNode)
        self.copyAccessibility(from: itemNode, to: cell)
        return true
    }

    private func configureHostedCell(_ cell: ChatListHostedCell, at indexPath: IndexPath, tableView: UITableView) {
        let row = self.currentRows[indexPath.row]
        let stableId = AnyHashable(row.stableId)
        cell.currentStableId = stableId

        let previousItem = indexPath.row > 0 ? self.currentRows[indexPath.row - 1].item : nil
        let nextItem = indexPath.row + 1 < self.currentRows.count ? self.currentRows[indexPath.row + 1].item : nil
        let params = ListViewItemLayoutParams(width: max(1.0, tableView.bounds.width), leftInset: 0.0, rightInset: 0.0, availableHeight: row.approximateHeight)

        if let current = self.nodeCache[stableId] {
            if self.syncConfigureCachedNode(cell: cell, row: row, itemNode: current, tableView: tableView, previousItem: previousItem, nextItem: nextItem) {
                return
            }
            row.item.updateNode(async: { $0() }, node: { current }, params: params, previousItem: previousItem, nextItem: nextItem, animation: .None, completion: { [weak self, weak cell] _, apply in
                apply(ListViewItemApply(isOnScreen: true))
                guard let self, let cell, cell.currentStableId == stableId else {
                    return
                }
                current.frame = CGRect(origin: .zero, size: CGSize(width: max(1.0, tableView.bounds.width), height: row.approximateHeight))
                cell.setItemNode(current)
                self.copyAccessibility(from: current, to: cell)
            })
        } else {
            row.item.nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: true, previousItem: previousItem, nextItem: nextItem, completion: { [weak self, weak cell] itemNode, getApply in
                guard let self else {
                    return
                }
                let (_, apply) = getApply()
                apply(ListViewItemApply(isOnScreen: true))
                self.nodeCache[stableId] = itemNode
                self.itemCache[stableId] = row.item
                guard let cell, cell.currentStableId == stableId else {
                    return
                }
                itemNode.frame = CGRect(origin: .zero, size: CGSize(width: max(1.0, tableView.bounds.width), height: row.approximateHeight))
                cell.setItemNode(itemNode)
                self.copyAccessibility(from: itemNode, to: cell)
            })
        }
    }

    private func refreshVisibleTableRows() {
        guard let indexPaths = self.tableView.indexPathsForVisibleRows else {
            return
        }
        for indexPath in indexPaths.sorted() {
            guard indexPath.row < self.currentRows.count, let cell = self.tableView.cellForRow(at: indexPath) as? ChatListHostedCell else {
                continue
            }
            self.configureHostedCell(cell, at: indexPath, tableView: self.tableView)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.currentRows.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        self.currentRows[indexPath.row].approximateHeight
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath) as! ChatListHostedCell
        self.configureHostedCell(cell, at: indexPath, tableView: tableView)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = self.currentRows[indexPath.row]
        row.item.selected(listView: self.selectionProxyListView)
        self.clearHighlightAnimated(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.contentOffsetChanged?(self.visibleContentOffset())
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        switch self.visibleContentOffset() {
        case let .known(value):
            self.startedScrollingAtUpperBound = value <= 0.001
        default:
            self.startedScrollingAtUpperBound = false
        }
        if let host = self.supernode as? ChatListDisplayNode {
            self.didBeginInteractiveDragging?(host)
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if let host = self.supernode as? ChatListDisplayNode, self.shouldStopScrolling?(host, velocity.y) == true {
            targetContentOffset.pointee = scrollView.contentOffset
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            if let host = self.supernode as? ChatListDisplayNode {
                self.endedInteractiveDragging?(host)
                _ = self.contentScrollingEnded?(host)
            }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if let host = self.supernode as? ChatListDisplayNode {
            _ = self.contentScrollingEnded?(host)
        }
    }

    private func updateEmptyState(view: ChatListNodeView) {
        var isEmpty = false
        var isLoading = false
        var hasArchiveInfo = false
        if view.filteredEntries.isEmpty {
            isEmpty = true
        } else if view.filteredEntries.count <= 2 {
            isEmpty = true
            for entry in view.filteredEntries {
                switch entry {
                case .HeaderEntry, .HoleEntry:
                    break
                case .ArchiveIntro:
                    hasArchiveInfo = true
                    isEmpty = false
                default:
                    isEmpty = false
                }
            }
            isLoading = view.filteredEntries.contains(where: {
                if case .HoleEntry = $0 { return true } else { return false }
            })
        }
        let state: ChatListNodeEmptyState
        if view.isLoading {
            state = .empty(isLoading: true, hasArchiveInfo: hasArchiveInfo)
        } else if isEmpty {
            state = .empty(isLoading: isLoading, hasArchiveInfo: false)
        } else {
            state = .notEmpty(containsChats: true, onlyArchive: false, onlyGeneralThread: false)
        }
        self.isEmptyUpdated?(state, view.filter != nil, .immediate)
    }

    private func updatePreloadItems(view: ChatListNodeView) {
        var items: [ChatHistoryPreloadItem] = []
        if !view.originalList.hasLater {
            for entry in view.filteredEntries.reversed() {
                if case let .PeerEntry(peerEntry) = entry, peerEntry.promoInfo == nil, case let .chatList(index) = peerEntry.index {
                    items.append(ChatHistoryPreloadItem(index: index, threadId: nil, isMuted: peerEntry.isRemovedFromTotalUnreadCount, hasUnread: peerEntry.readState?.count ?? 0 > 0))
                }
                if items.count >= 30 {
                    break
                }
            }
        }
        self.preloadItems.set(.single(items))
    }
}

private extension ListViewVisibleContentOffset {
    var isAtTop: Bool {
        if case let .known(value) = self {
            return abs(value) < 0.5
        } else {
            return false
        }
    }
}
