import SGSimpleSettings
import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import Postbox
import TelegramPresentationData
import TelegramUIPreferences
import MediaResources
import AccountContext
import TemporaryCachedPeerDataManager
import ChatListSearchItemNode
import Emoji
import AppBundle
import ListMessageItem
import AccountContext
import ChatInterfaceState
import ChatListUI
import ComponentFlow
import ReactionSelectionNode
import ChatPresentationInterfaceState
import TelegramNotices
import ChatControllerInteraction
import TranslateUI
import ChatHistoryEntry
import ChatOverscrollControl
import ChatBotInfoItem
import ChatUserInfoItem
import ChatMessageItem
import ChatMessageItemImpl
import ChatMessageItemView
import ChatMessageBubbleItemNode
import ChatMessageTransitionNode
import ChatControllerInteraction
import DustEffect
import UrlHandling
import TextFormat
import ChatNewThreadInfoItem

struct ChatTopVisibleMessageRange: Equatable {
    var lowerBound: MessageIndex
    var upperBound: MessageIndex
    var isLast: Bool
    var isLoading: Bool
}

private let historyMessageCount: Int = 44

private struct PendingMessageNavigationAlignment {
    let messageId: MessageId
    let directionHint: ListViewScrollToItemDirectionHint
    var remainingPasses: Int
}

enum ChatHistoryViewScrollPosition {
    case unread(index: MessageIndex)
    case positionRestoration(index: MessageIndex, relativeOffset: CGFloat)
    case index(subject: MessageHistoryScrollToSubject, position: ListViewScrollPosition, directionHint: ListViewScrollToItemDirectionHint, animated: Bool, highlight: Bool, displayLink: Bool, setupReply: Bool)
}

enum ChatHistoryViewUpdateType {
    case Initial(fadeIn: Bool)
    case Generic(type: ViewUpdateType)
}

public struct ChatHistoryCombinedInitialReadStateData {
    public let unreadCount: Int32
    public let totalState: ChatListTotalUnreadState?
    public let notificationSettings: PeerNotificationSettings?
}

public struct ChatHistoryCombinedInitialData {
    var initialData: InitialMessageHistoryData?
    var buttonKeyboardMessage: Message?
    var cachedData: CachedPeerData?
    var cachedDataMessages: [MessageId: Message]?
    var readStateData: [PeerId: ChatHistoryCombinedInitialReadStateData]?
}

enum ChatHistoryViewUpdate {
    case Loading(initialData: ChatHistoryCombinedInitialData?, type: ChatHistoryViewUpdateType)
    case HistoryView(view: MessageHistoryView, type: ChatHistoryViewUpdateType, scrollPosition: ChatHistoryViewScrollPosition?, flashIndicators: Bool, originalScrollPosition: ChatHistoryViewScrollPosition?, initialData: ChatHistoryCombinedInitialData, id: Int32)
}

struct ChatHistoryView {
    let originalView: MessageHistoryView
    let filteredEntries: [ChatHistoryEntry]
    let associatedData: ChatMessageItemAssociatedData
    let lastHeaderId: Int64
    let id: Int32
    let locationInput: ChatHistoryLocationInput?
    let ignoreMessagesInTimestampRange: ClosedRange<Int32>?
    let ignoreMessageIds: Set<MessageId>
}

enum ChatHistoryViewTransitionReason {
    case Initial(fadeIn: Bool)
    case InteractiveChanges
    case Reload
    case HoleReload
}

struct ChatHistoryViewTransitionInsertEntry {
    let index: Int
    let previousIndex: Int?
    let entry: ChatHistoryEntry
    let directionHint: ListViewItemOperationDirectionHint?
}

struct ChatHistoryViewTransitionUpdateEntry {
    let index: Int
    let previousIndex: Int
    let entry: ChatHistoryEntry
    let directionHint: ListViewItemOperationDirectionHint?
}

struct ChatHistoryViewTransition {
    var historyView: ChatHistoryView
    var deleteItems: [ListViewDeleteItem]
    var insertEntries: [ChatHistoryViewTransitionInsertEntry]
    var updateEntries: [ChatHistoryViewTransitionUpdateEntry]
    var options: ListViewDeleteAndInsertOptions
    var scrollToItem: ListViewScrollToItem?
    var stationaryItemRange: (Int, Int)?
    var initialData: InitialMessageHistoryData?
    var keyboardButtonsMessage: Message?
    var cachedData: CachedPeerData?
    var cachedDataMessages: [MessageId: Message]?
    var readStateData: [PeerId: ChatHistoryCombinedInitialReadStateData]?
    var scrolledToIndex: MessageHistoryScrollToSubject?
    var scrolledToSomeIndex: Bool
    var animateIn: Bool
    var reason: ChatHistoryViewTransitionReason
    var flashIndicators: Bool
}

struct ChatHistoryListViewTransition {
    var historyView: ChatHistoryView
    var deleteItems: [ListViewDeleteItem]
    var insertItems: [ListViewInsertItem]
    var updateItems: [ListViewUpdateItem]
    var options: ListViewDeleteAndInsertOptions
    var scrollToItem: ListViewScrollToItem?
    var stationaryItemRange: (Int, Int)?
    var initialData: InitialMessageHistoryData?
    var keyboardButtonsMessage: Message?
    var cachedData: CachedPeerData?
    var cachedDataMessages: [MessageId: Message]?
    var readStateData: [PeerId: ChatHistoryCombinedInitialReadStateData]?
    var scrolledToIndex: MessageHistoryScrollToSubject?
    var scrolledToSomeIndex: Bool
    var peerType: MediaAutoDownloadPeerType
    var networkType: MediaAutoDownloadNetworkType
    var animateIn: Bool
    var reason: ChatHistoryViewTransitionReason
    var flashIndicators: Bool
    var animateFromPreviousFilter: Bool
}

private func maxMessageIndexForEntries(_ view: ChatHistoryView, indexRange: (Int, Int)) -> (incoming: MessageIndex?, overall: MessageIndex?) {
    var incoming: MessageIndex?
    var overall: MessageIndex?
    var nextLowestIndex: MessageIndex?
    if indexRange.0 >= 0 && indexRange.0 < view.filteredEntries.count {
        if indexRange.0 > 0 {
            nextLowestIndex = view.filteredEntries[indexRange.0 - 1].index
        }
    }
    var nextHighestIndex: MessageIndex?
    if indexRange.1 >= 0 && indexRange.1 < view.filteredEntries.count {
        if indexRange.1 < view.filteredEntries.count - 1 {
            nextHighestIndex = view.filteredEntries[indexRange.1 + 1].index
        }
    }
    for i in (0 ..< view.originalView.entries.count).reversed() {
        let index = view.originalView.entries[i].index
        if let nextLowestIndex = nextLowestIndex {
            if index <= nextLowestIndex {
                continue
            }
        }
        if let nextHighestIndex = nextHighestIndex {
            if index >= nextHighestIndex {
                continue
            }
        }
        let messageEntry = view.originalView.entries[i]
        if overall == nil || overall! < index {
            overall = index
        }
        if !messageEntry.message.flags.intersection(.IsIncomingMask).isEmpty {
            if incoming == nil || incoming! < index {
                incoming = index
            }
        }
        if incoming != nil {
            return (incoming, overall)
        }
    }
    return (incoming, overall)
}

extension ListMessageItemInteraction {
    convenience init(controllerInteraction: ChatControllerInteraction) {
        self.init(openMessage: { message, mode -> Bool in
            return controllerInteraction.openMessage(message, OpenMessageParams(mode: mode))
        }, openMessageContextMenu: { message, bool, node, rect, gesture in
            controllerInteraction.openMessageContextMenu(message, bool, node, rect, gesture, nil)
        }, toggleMessagesSelection: { messageId, selected in
            controllerInteraction.toggleMessagesSelection(messageId, selected)
        }, openUrl: { url, param1, param2, message in
            controllerInteraction.openUrl(ChatControllerInteraction.OpenUrl(url: url, concealed: param1, external: param2, message: message, progress: Promise()))
        }, openInstantPage: { message, data in
            controllerInteraction.openInstantPage(message, data)
        }, longTap: { action, message in
            controllerInteraction.longTap(action, ChatControllerInteraction.LongTapParams(message: message))
        }, getHiddenMedia: {
            return controllerInteraction.hiddenMedia
        })
    }
}

private func mappedInsertEntries(context: AccountContext, chatLocation: ChatLocation, associatedData: ChatMessageItemAssociatedData, controllerInteraction: ChatControllerInteraction, mode: ChatHistoryListMode, lastHeaderId: Int64, isSavedMusic: Bool, canReorder: Bool, entries: [ChatHistoryViewTransitionInsertEntry]) -> [ListViewInsertItem] {
    var disableFloatingDateHeaders = false
    if case .customChatContents = chatLocation {
        disableFloatingDateHeaders = true
    }
    
    return entries.map { entry -> ListViewInsertItem in
        switch entry.entry {
            case let .MessageEntry(message, presentationData, read, location, selection, attributes):
                let item: ListViewItem
                switch mode {
                    case .bubbles:
                        item = ChatMessageItemImpl(presentationData: presentationData, context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, content: .message(message: message, read: read, selection: selection, attributes: attributes, location: location), disableDate: disableFloatingDateHeaders || message.timestamp < 10)
                    case let .list(_, _, _, displayHeaders, hintLinks, isGlobalSearch):
                        let displayHeader: Bool
                        switch displayHeaders {
                        case .none:
                            displayHeader = false
                        case .all:
                            displayHeader = true
                        case .allButLast:
                            displayHeader = listMessageDateHeaderId(timestamp: message.timestamp) != lastHeaderId
                        }
                        item = ListMessageItem(presentationData: presentationData, context: context, chatLocation: chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: controllerInteraction), message: message, translateToLanguage: associatedData.translateToLanguage, selection: selection, displayHeader: displayHeader, hintIsLink: hintLinks, isGlobalSearchResult: isGlobalSearch, isSavedMusic: isSavedMusic, canReorder: canReorder)
                }
                return ListViewInsertItem(index: entry.index, previousIndex: entry.previousIndex, item: item, directionHint: entry.directionHint)
            case let .MessageGroupEntry(_, messages, presentationData):
                let item: ListViewItem
                switch mode {
                    case .bubbles:
                        item = ChatMessageItemImpl(presentationData: presentationData, context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, content: .group(messages: messages), disableDate: disableFloatingDateHeaders)
                    case .list:
                        assertionFailure()
                        item = ListMessageItem(presentationData: presentationData, context: context, chatLocation: chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: controllerInteraction), message: messages[0].0, selection: .none, displayHeader: false)
                }
                return ListViewInsertItem(index: entry.index, previousIndex: entry.previousIndex, item: item, directionHint: entry.directionHint)
            case let .UnreadEntry(_, presentationData):
                return ListViewInsertItem(index: entry.index, previousIndex: entry.previousIndex, item: ChatUnreadItem(index: entry.entry.index, presentationData: presentationData, controllerInteraction: controllerInteraction, context: context), directionHint: entry.directionHint)
            case let .ReplyCountEntry(_, isComments, count, presentationData):
                return ListViewInsertItem(index: entry.index, previousIndex: entry.previousIndex, item: ChatReplyCountItem(index: entry.entry.index, isComments: isComments, count: count, presentationData: presentationData, context: context, controllerInteraction: controllerInteraction), directionHint: entry.directionHint)
            case let .ChatInfoEntry(data, presentationData):
                let item: ListViewItem
                switch data {
                case let .botInfo(title, text, photo, video):
                    item = ChatBotInfoItem(title: title, text: text, photo: photo, video: video, controllerInteraction: controllerInteraction, presentationData: presentationData, context: context)
                case let .userInfo(peer, verification, registrationDate, phoneCountry, groupsInCommonCount):
                    item = ChatUserInfoItem(peer: peer, verification: verification, registrationDate: registrationDate, phoneCountry: phoneCountry, groupsInCommonCount: groupsInCommonCount, controllerInteraction: controllerInteraction, presentationData: presentationData, context: context)
                case .newThreadInfo:
                    item = ChatNewThreadInfoItem(controllerInteraction: controllerInteraction, presentationData: presentationData, context: context)
                }
                return ListViewInsertItem(index: entry.index, previousIndex: entry.previousIndex, item: item, directionHint: entry.directionHint)
            case let .SearchEntry(theme, strings):
                return ListViewInsertItem(index: entry.index, previousIndex: entry.previousIndex, item: ChatListSearchItem(theme: theme, placeholder: strings.Common_Search, activate: {
                    controllerInteraction.openSearch()
                }), directionHint: entry.directionHint)
        }
    }
}

private func mappedUpdateEntries(context: AccountContext, chatLocation: ChatLocation, associatedData: ChatMessageItemAssociatedData, controllerInteraction: ChatControllerInteraction, mode: ChatHistoryListMode, lastHeaderId: Int64, isSavedMusic: Bool, canReorder: Bool, entries: [ChatHistoryViewTransitionUpdateEntry]) -> [ListViewUpdateItem] {
    var disableFloatingDateHeaders = false
    if case .customChatContents = chatLocation {
        disableFloatingDateHeaders = true
    }
    
    return entries.map { entry -> ListViewUpdateItem in
        switch entry.entry {
            case let .MessageEntry(message, presentationData, read, location, selection, attributes):
                let item: ListViewItem
                switch mode {
                    case .bubbles:
                        item = ChatMessageItemImpl(presentationData: presentationData, context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, content: .message(message: message, read: read, selection: selection, attributes: attributes, location: location), disableDate: disableFloatingDateHeaders || message.timestamp < 10)
                    case let .list(_, _, _, displayHeaders, hintLinks, isGlobalSearch):
                        let displayHeader: Bool
                        switch displayHeaders {
                        case .none:
                            displayHeader = false
                        case .all:
                            displayHeader = true
                        case .allButLast:
                            displayHeader = listMessageDateHeaderId(timestamp: message.timestamp) != lastHeaderId
                        }
                        item = ListMessageItem(presentationData: presentationData, context: context, chatLocation: chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: controllerInteraction), message: message, translateToLanguage: associatedData.translateToLanguage, selection: selection, displayHeader: displayHeader, hintIsLink: hintLinks, isGlobalSearchResult: isGlobalSearch, isSavedMusic: isSavedMusic, canReorder: canReorder)
                }
                return ListViewUpdateItem(index: entry.index, previousIndex: entry.previousIndex, item: item, directionHint: entry.directionHint)
            case let .MessageGroupEntry(_, messages, presentationData):
                let item: ListViewItem
                switch mode {
                    case .bubbles:
                        item = ChatMessageItemImpl(presentationData: presentationData, context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, content: .group(messages: messages), disableDate: disableFloatingDateHeaders)
                    case .list:
                        assertionFailure()
                        item = ListMessageItem(presentationData: presentationData, context: context, chatLocation: chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: controllerInteraction), message: messages[0].0, selection: .none, displayHeader: false)
                }
                return ListViewUpdateItem(index: entry.index, previousIndex: entry.previousIndex, item: item, directionHint: entry.directionHint)
            case let .UnreadEntry(_, presentationData):
                return ListViewUpdateItem(index: entry.index, previousIndex: entry.previousIndex, item: ChatUnreadItem(index: entry.entry.index, presentationData: presentationData, controllerInteraction: controllerInteraction, context: context), directionHint: entry.directionHint)
            case let .ReplyCountEntry(_, isComments, count, presentationData):
                return ListViewUpdateItem(index: entry.index, previousIndex: entry.previousIndex, item: ChatReplyCountItem(index: entry.entry.index, isComments: isComments, count: count, presentationData: presentationData, context: context, controllerInteraction: controllerInteraction), directionHint: entry.directionHint)
            case let .ChatInfoEntry(data, presentationData):
                let item: ListViewItem
                switch data {
                case let .botInfo(title, text, photo, video):
                    item = ChatBotInfoItem(title: title, text: text, photo: photo, video: video, controllerInteraction: controllerInteraction, presentationData: presentationData, context: context)
                case let .userInfo(peer, verification, registrationDate, phoneCountry, groupsInCommonCount):
                    item = ChatUserInfoItem(peer: peer, verification: verification, registrationDate: registrationDate, phoneCountry: phoneCountry, groupsInCommonCount: groupsInCommonCount, controllerInteraction: controllerInteraction, presentationData: presentationData, context: context)
                case .newThreadInfo:
                    item = ChatNewThreadInfoItem(controllerInteraction: controllerInteraction, presentationData: presentationData, context: context)
                }
                return ListViewUpdateItem(index: entry.index, previousIndex: entry.previousIndex, item: item, directionHint: entry.directionHint)
            case let .SearchEntry(theme, strings):
                return ListViewUpdateItem(index: entry.index, previousIndex: entry.previousIndex, item: ChatListSearchItem(theme: theme, placeholder: strings.Common_Search, activate: {
                    controllerInteraction.openSearch()
                }), directionHint: entry.directionHint)
        }
    }
}

private func mappedChatHistoryViewListTransition(context: AccountContext, chatLocation: ChatLocation, associatedData: ChatMessageItemAssociatedData, controllerInteraction: ChatControllerInteraction, mode: ChatHistoryListMode, lastHeaderId: Int64, isSavedMusic: Bool, canReorder: Bool, animateFromPreviousFilter: Bool, transition: ChatHistoryViewTransition) -> ChatHistoryListViewTransition {
    return ChatHistoryListViewTransition(historyView: transition.historyView, deleteItems: transition.deleteItems, insertItems: mappedInsertEntries(context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, mode: mode, lastHeaderId: lastHeaderId, isSavedMusic: isSavedMusic, canReorder: canReorder, entries: transition.insertEntries), updateItems: mappedUpdateEntries(context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, mode: mode, lastHeaderId: lastHeaderId, isSavedMusic: isSavedMusic, canReorder: canReorder, entries: transition.updateEntries), options: transition.options, scrollToItem: transition.scrollToItem, stationaryItemRange: transition.stationaryItemRange, initialData: transition.initialData, keyboardButtonsMessage: transition.keyboardButtonsMessage, cachedData: transition.cachedData, cachedDataMessages: transition.cachedDataMessages, readStateData: transition.readStateData, scrolledToIndex: transition.scrolledToIndex, scrolledToSomeIndex: transition.scrolledToSomeIndex, peerType: associatedData.automaticDownloadPeerType, networkType: associatedData.automaticDownloadNetworkType, animateIn: transition.animateIn, reason: transition.reason, flashIndicators: transition.flashIndicators, animateFromPreviousFilter: animateFromPreviousFilter)
}

final class ChatHistoryTransactionOpaqueState {
    let historyView: ChatHistoryView
    
    init(historyView: ChatHistoryView) {
        self.historyView = historyView
    }
}

private func extractAssociatedData(
    translateToLanguageSG: String?,
    translationSettings: TranslationSettings,
    chatLocation: ChatLocation,
    view: MessageHistoryView,
    automaticDownloadNetworkType: MediaAutoDownloadNetworkType,
    preferredStoryHighQuality: Bool,
    animatedEmojiStickers: [String: [StickerPackItem]],
    additionalAnimatedEmojiStickers: [String: [Int: StickerPackItem]],
    subject: ChatControllerSubject?,
    currentlyPlayingMessageId: MessageIndex?,
    isCopyProtectionEnabled: Bool,
    availableReactions: AvailableReactions?,
    availableMessageEffects: AvailableMessageEffects?,
    savedMessageTags: SavedMessageTags?,
    defaultReaction: MessageReaction.Reaction?,
    areStarReactionsEnabled: Bool,
    isPremium: Bool,
    alwaysDisplayTranscribeButton: ChatMessageItemAssociatedData.DisplayTranscribeButton,
    accountPeer: EnginePeer?,
    topicAuthorId: EnginePeer.Id?,
    hasBots: Bool,
    translateToLanguage: String?,
    maxReadStoryId: Int32?,
    recommendedChannels: RecommendedChannels?,
    audioTranscriptionTrial: AudioTranscription.TrialState,
    chatThemes: [TelegramTheme],
    deviceContactsNumbers: Set<String>,
    isInline: Bool,
    showSensitiveContent: Bool,
    isSuspiciousPeer: Bool
) -> ChatMessageItemAssociatedData {
    var automaticDownloadPeerId: EnginePeer.Id?
    var automaticMediaDownloadPeerType: MediaAutoDownloadPeerType = .channel
    var contactsPeerIds: Set<PeerId> = Set()
    var channelDiscussionGroup: ChatMessageItemAssociatedData.ChannelDiscussionGroupStatus = .unknown
    if case let .peer(peerId) = chatLocation {
        automaticDownloadPeerId = peerId
        
        if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.SecretChat {
            var isContact = false
            for entry in view.additionalData {
                if case let .peerIsContact(_, value) = entry {
                    isContact = value
                    break
                }
            }
            automaticMediaDownloadPeerType = isContact ? .contact : .otherPrivate
        } else if peerId.namespace == Namespaces.Peer.CloudGroup {
            automaticMediaDownloadPeerType = .group
            
            for entry in view.entries {
                if entry.attributes.authorIsContact, let peerId = entry.message.author?.id {
                    contactsPeerIds.insert(peerId)
                }
            }
        } else if peerId.namespace == Namespaces.Peer.CloudChannel {
            for entry in view.additionalData {
                if case let .peer(_, value) = entry {
                    if let channel = value as? TelegramChannel, case .group = channel.info {
                        automaticMediaDownloadPeerType = .group
                    }
                } else if case let .cachedPeerData(dataPeerId, cachedData) = entry, dataPeerId == peerId {
                    if let cachedData = cachedData as? CachedChannelData {
                        switch cachedData.linkedDiscussionPeerId {
                        case let .known(value):
                            channelDiscussionGroup = .known(value)
                        case .unknown:
                            channelDiscussionGroup = .unknown
                        }
                    }
                }
            }
            if automaticMediaDownloadPeerType == .group {
                for entry in view.entries {
                    if entry.attributes.authorIsContact, let peerId = entry.message.author?.id {
                        contactsPeerIds.insert(peerId)
                    }
                }
            }
        }
    } else if case let .replyThread(message) = chatLocation, message.isForumPost {
        automaticDownloadPeerId = message.peerId
    }
    
    return ChatMessageItemAssociatedData(translateToLanguageSG: translateToLanguageSG, translationSettings: translationSettings, /* MARK: Swiftgram */ automaticDownloadPeerType: automaticMediaDownloadPeerType, automaticDownloadPeerId: automaticDownloadPeerId, automaticDownloadNetworkType: automaticDownloadNetworkType, preferredStoryHighQuality: preferredStoryHighQuality, isRecentActions: false, subject: subject, contactsPeerIds: contactsPeerIds, channelDiscussionGroup: channelDiscussionGroup, animatedEmojiStickers: animatedEmojiStickers, additionalAnimatedEmojiStickers: additionalAnimatedEmojiStickers, currentlyPlayingMessageId: currentlyPlayingMessageId, isCopyProtectionEnabled: isCopyProtectionEnabled, availableReactions: availableReactions, availableMessageEffects: availableMessageEffects, savedMessageTags: savedMessageTags, defaultReaction: defaultReaction, areStarReactionsEnabled: areStarReactionsEnabled, isPremium: isPremium, accountPeer: accountPeer, alwaysDisplayTranscribeButton: alwaysDisplayTranscribeButton, topicAuthorId: topicAuthorId, hasBots: hasBots, translateToLanguage: translateToLanguage, maxReadStoryId: maxReadStoryId, recommendedChannels: recommendedChannels, audioTranscriptionTrial: audioTranscriptionTrial, chatThemes: chatThemes, deviceContactsNumbers: deviceContactsNumbers, isInline: isInline, showSensitiveContent: showSensitiveContent, isSuspiciousPeer: isSuspiciousPeer)
}

private extension ChatHistoryLocationInput {
    var isAtUpperBound: Bool {
        switch self.content {
        case .Navigation(index: .upperBound, anchorIndex: .upperBound, count: _, highlight: _):
                return true
        case let .Scroll(subject, anchorIndex, _, _, _, _, _):
            if case .upperBound = anchorIndex, case .upperBound = subject.index {
                return true
            } else {
                return false
            }
        default:
            return false
        }
    }
}

private struct ChatHistoryAnimatedEmojiConfiguration {
    static var defaultValue: ChatHistoryAnimatedEmojiConfiguration {
        return ChatHistoryAnimatedEmojiConfiguration(scale: 0.625)
    }
    
    public let scale: CGFloat
    
    fileprivate init(scale: CGFloat) {
        self.scale = scale
    }
    
    static func with(appConfiguration: AppConfiguration) -> ChatHistoryAnimatedEmojiConfiguration {
        if let data = appConfiguration.data, let scale = data["emojies_animated_zoom"] as? Double {
            return ChatHistoryAnimatedEmojiConfiguration(scale: CGFloat(scale))
        } else {
            return .defaultValue
        }
    }
}

private var nextClientId: Int32 = 1

public final class ChatHistoryListNodeImpl: ListView, ChatHistoryNode, ChatHistoryListNode {
    static let fixedAdMessageStableId: UInt32 = UInt32.max - 5000
    
    public let context: AccountContext
    private(set) var chatLocation: ChatLocation
    private let chatLocationContextHolder: Atomic<ChatLocationContextHolder?>
    private let source: ChatHistoryListSource
    private let subject: ChatControllerSubject?
    private(set) var tag: HistoryViewInputTag?
    private let controllerInteraction: ChatControllerInteraction
    private let selectedMessages: Signal<Set<MessageId>?, NoError>
    var messageTransitionNode: () -> ChatMessageTransitionNodeImpl?
    private let mode: ChatHistoryListMode
    
    var enableUnreadAlignment: Bool = true
    var areContentAnimationsEnabled: Bool = false
    
    private var historyView: ChatHistoryView?
    public var originalHistoryView: MessageHistoryView? {
        return self.historyView?.originalView
    }
    
    private let historyDisposable = MetaDisposable()
    private let readHistoryDisposable = MetaDisposable()
    
    private var dequeuedInitialTransitionOnLayout = false
    private var enqueuedHistoryViewTransitions: [ChatHistoryListViewTransition] = []
    private var hasActiveTransition = false
    var layoutActionOnViewTransition: ((ChatHistoryListViewTransition) -> (ChatHistoryListViewTransition, ListViewUpdateSizeAndInsets?), Int64?)?
    
    public let historyState = ValuePromise<ChatHistoryNodeHistoryState>()
    public var currentHistoryState: ChatHistoryNodeHistoryState?
    
    private let _initialData = Promise<ChatHistoryCombinedInitialData?>()
    private var didSetInitialData = false
    public var initialData: Signal<ChatHistoryCombinedInitialData?, NoError> {
        return self._initialData.get()
    }
    
    private let _cachedPeerDataAndMessages = Promise<(CachedPeerData?, [MessageId: Message]?)>()
    public var cachedPeerDataAndMessages: Signal<(CachedPeerData?, [MessageId: Message]?), NoError> {
        return self._cachedPeerDataAndMessages.get()
    }
    
    private var _buttonKeyboardMessage = Promise<Message?>(nil)
    private var currentButtonKeyboardMessage: Message?
    public var buttonKeyboardMessage: Signal<Message?, NoError> {
        return self._buttonKeyboardMessage.get()
    }
    
    private let maxVisibleIncomingMessageIndex = ValuePromise<MessageIndex>(ignoreRepeated: true)
    let canReadHistory = Promise<Bool>()
    private var canReadHistoryValue: Bool = false
    private var canReadHistoryDisposable: Disposable?
    
    var suspendReadingReactions: Bool = false {
        didSet {
            if self.suspendReadingReactions != oldValue {
                if !self.suspendReadingReactions {
                    self.attemptReadingReactions()
                }
            }
        }
    }

    private var messageIdsScheduledForMarkAsSeen = Set<MessageId>()
    private var messageIdsWithReactionsScheduledForMarkAsSeen = Set<MessageId>()
    
    private var chatHistoryLocationValue: ChatHistoryLocationInput? {
        didSet {
            if let chatHistoryLocationValue = self.chatHistoryLocationValue, chatHistoryLocationValue != oldValue {
                self.chatHistoryLocationPromise.set(chatHistoryLocationValue)
            }
        }
    }
    private let chatHistoryLocationPromise = ValuePromise<ChatHistoryLocationInput>()
    private var nextHistoryLocationId: Int32 = 1
    private func takeNextHistoryLocationId() -> Int32 {
        let id = self.nextHistoryLocationId
        self.nextHistoryLocationId += 5
        return id
    }
    
    private let ignoreMessagesInTimestampRangePromise = ValuePromise<ClosedRange<Int32>?>(nil)
    var ignoreMessagesInTimestampRange: ClosedRange<Int32>? = nil {
        didSet {
            if self.ignoreMessagesInTimestampRange != oldValue {
                self.ignoreMessagesInTimestampRangePromise.set(self.ignoreMessagesInTimestampRange)
            }
        }
    }
    
    private let ignoreMessageIdsPromise = ValuePromise<Set<EngineMessage.Id>>(Set())
    var ignoreMessageIds: Set<EngineMessage.Id> = Set() {
        didSet {
            if self.ignoreMessageIds != oldValue {
                self.ignoreMessageIdsPromise.set(self.ignoreMessageIds)
            }
        }
    }
    
    private let chatHasBotsPromise = ValuePromise<Bool>(false)
    var chatHasBots: Bool = false {
        didSet {
            if self.chatHasBots != oldValue {
                self.chatHasBotsPromise.set(self.chatHasBots)
            }
        }
    }
        
    private let galleryHiddenMesageAndMediaDisposable = MetaDisposable()
    
    private let messageProcessingManager = ChatMessageThrottledProcessingManager()
    private let messageWithReactionsProcessingManager = ChatMessageThrottledProcessingManager(submitInterval: 4.0)
    private let seenLiveLocationProcessingManager = ChatMessageThrottledProcessingManager()
    private let unsupportedMessageProcessingManager = ChatMessageThrottledProcessingManager()
    private let refreshMediaProcessingManager = ChatMessageThrottledProcessingManager()
    private let messageMentionProcessingManager = ChatMessageThrottledProcessingManager(delay: 0.2)
    private let unseenReactionsProcessingManager = ChatMessageThrottledProcessingManager(delay: 0.2, submitInterval: 0.0)
    private let extendedMediaProcessingManager = ChatMessageVisibleThrottledProcessingManager(interval: 5.0)
    private let translationProcessingManager = ChatMessageThrottledProcessingManager(submitInterval: 1.0)
    private let refreshStoriesProcessingManager = ChatMessageThrottledProcessingManager()
    private let factCheckProcessingManager = ChatMessageThrottledProcessingManager(submitInterval: 1.0)
    private let inlineGroupCallsProcessingManager = ChatMessageThrottledProcessingManager(submitInterval: 1.0)
    
    let prefetchManager: InChatPrefetchManager
    private var currentEarlierPrefetchMessages: [(Message, Media)] = []
    private var currentLaterPrefetchMessages: [(Message, Media)] = []
    private var currentPrefetchDirectionIsToLater: Bool = false
    
    private var maxVisibleMessageIndexReported: MessageIndex?
    var maxVisibleMessageIndexUpdated: ((MessageIndex) -> Void)?
    
    var scrolledToIndex: ((MessageHistoryScrollToSubject, Bool) -> Void)?
    var scrolledToSomeIndex: (() -> Void)?
    var beganDragging: (() -> Void)?
    
    private let hasVisiblePlayableItemNodesPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var hasVisiblePlayableItemNodes: Signal<Bool, NoError> {
        return self.hasVisiblePlayableItemNodesPromise.get()
    }
    
    private var isInteractivelyScrollingValue: Bool = false
    private let isInteractivelyScrollingPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var isInteractivelyScrolling: Signal<Bool, NoError> {
        return self.isInteractivelyScrollingPromise.get()
    }
    
    private var currentPresentationData: ChatPresentationData
    private var chatPresentationDataPromise: Promise<ChatPresentationData>
    private var presentationDataDisposable: Disposable?

    // Observer that flips `accessibilityInvisibleInsetOverride` so that, while
    // VoiceOver is running, the entire loaded message window is materialised
    // and present in the accessibility array. Same approach as in
    // `ChatListNode` — instead of patching VoiceOver navigation with timing
    // heuristics, we just give it a complete, stable list of elements.
    private var voiceOverStatusObserver: NSObjectProtocol?

    /// Throttle for the accessibility-layout-changed notifications we
    /// post on scroll. See `maybePostAccessibilityLayoutChangedOnScroll`.
    private var lastA11yLayoutChangedPostTime: CFTimeInterval = 0

    // Snapshot of the most recently produced accessibility array.  It is used
    // by the `[VO-CHAT] cursor` log to translate the focused element pointer
    // delivered by `UIAccessibility.elementFocusedNotification` into a
    // human-readable "X / N" position whenever VoiceOver moves between
    // messages.
    private var lastAccessibilityElements: [Any] = []
    private var lastFocusedElementIdentity: ObjectIdentifier?
    private var elementFocusedObserver: NSObjectProtocol?

    // Tracking for VoiceOver bounded-window edge advance + fly-away recovery.
    // Both paths live inline inside `handleVoiceOverFocusChanged`.
    //
    // Why: with the N=1 synthetic neighbour design in
    // `customAccessibilityElements`, the synthetic frame for the off-screen
    // sibling collapses onto the visible bubble at the clip edge. VoiceOver
    // can't reach it, fires `focus-left-list`, then re-anchors on `array[0]`
    // — which in reversed nav order is the newest message in the window —
    // and the cursor visibly «улетает» 6+ items away. We address this from
    // two sides:
    //   • A) Preemptively scroll when focus arrives at the visible edge in
    //     the direction the user is moving, so the next bubble has a real
    //     on-screen frame by the time VoiceOver tries to navigate to it.
    //   • B) Strap a recovery net: if focus does still leave the list and
    //     come back on a far-away `localIndex`, redirect it back to the
    //     last known one via `.layoutChanged`.
    private var voLastFocusedItemLocalIndex: Int?
    private var voFocusLostTimestamp: CFTimeInterval = 0
    private var voLastEdgeScrollTimestamp: CFTimeInterval = 0

    // Tracks message bubbles we *promoted* to a single accessibility leaf
    // (via `isAccessibilityElement = true`) while VoiceOver is active —
    // exactly the same trick `ChatListItemNode` uses unconditionally
    // (`ChatListItem.swift:1662`).  Promoting the bubble at the *node*
    // level is what stops UIKit from exposing the message's inner
    // subnodes (comments button, share button, action buttons, the
    // `AccessibilityAreaNode`, …) as separate accessibility elements,
    // which in turn keeps VoiceOver swipes traversing the conversation
    // strictly at the message-row level.  When VoiceOver turns off, we
    // revert every promoted node back to a container so other assistive
    // tools (Switch Control, automation, accessibility inspector) keep
    // seeing the granular tree.  Dead entries are dropped by
    // `NSHashTable.weakObjects()` automatically.
    private var voPromotedItemNodes: NSHashTable<ListViewItemNode> = NSHashTable.weakObjects()
    
    private let historyAppearsClearedPromise = ValuePromise<Bool>(false)
    var historyAppearsCleared: Bool = false {
        didSet {
            if self.historyAppearsCleared != oldValue {
                self.historyAppearsClearedPromise.set(self.historyAppearsCleared)
            }
        }
    }
    
    private let pendingUnpinnedAllMessagesPromise = ValuePromise<Bool>(false)
    var pendingUnpinnedAllMessages: Bool = false {
        didSet {
            if self.pendingUnpinnedAllMessages != oldValue {
                self.pendingUnpinnedAllMessagesPromise.set(self.pendingUnpinnedAllMessages)
            }
        }
    }
    
    private let pendingRemovedMessagesPromise = ValuePromise<Set<MessageId>>(Set())
    var pendingRemovedMessages: Set<MessageId> = Set() {
        didSet {
            if self.pendingRemovedMessages != oldValue {
                self.pendingRemovedMessagesPromise.set(self.pendingRemovedMessages)
            }
        }
    }
    
    private let justSentTextMessagePromise = ValuePromise<Bool>(false)
    var justSentTextMessage: Bool = false {
        didSet {
            if self.justSentTextMessage != oldValue {
                self.justSentTextMessagePromise.set(self.justSentTextMessage)
            }
        }
    }
    
    private var appliedScrollToMessageId: MessageIndex? = nil
    private let scrollToMessageIdPromise = Promise<MessageIndex?>(nil)
    private var pendingMessageNavigationAlignment: PendingMessageNavigationAlignment?
    private var isApplyingPendingMessageNavigationAlignment = false
    
    private let currentlyPlayingMessageIdPromise = Promise<(MessageIndex, Bool)?>(nil)
    private var appliedPlayingMessageId: (MessageIndex, Bool)? = nil
    
    private(set) var isScrollAtBottomPosition = false
    public var isScrollAtBottomPositionUpdated: (() -> Void)?
    
    private var interactiveReadActionDisposable: Disposable?
    private var interactiveReadReactionsDisposable: Disposable?
    private var displayUnseenReactionAnimationsTimestamps: [MessageId: Double] = [:]
    
    public var contentPositionChanged: (ListViewVisibleContentOffset) -> Void = { _ in }
    
    public private(set) var loadState: ChatHistoryNodeLoadState?
    public private(set) var loadStateUpdated: ((ChatHistoryNodeLoadState, Bool) -> Void)?
    private var additionalLoadStateUpdated: [(ChatHistoryNodeLoadState, Bool) -> Void] = []
    
    public private(set) var hasAtLeast3Messages: Bool = false
    public var hasAtLeast3MessagesUpdated: ((Bool) -> Void)?
    
    public private(set) var hasPlentyOfMessages: Bool = false
    public var hasPlentyOfMessagesUpdated: ((Bool) -> Void)?
    
    public private(set) var hasLotsOfMessages: Bool = false
    public var hasLotsOfMessagesUpdated: ((Bool) -> Void)?
    
    private var loadedMessagesFromCachedDataDisposable: Disposable?
    
    private var isSettingTopReplyThreadMessageShown: Bool = false
    let isTopReplyThreadMessageShown = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var topVisibleMessageRangeValueInitialized: Bool = false
    private var topVisibleMessageRangeValue: ChatTopVisibleMessageRange?
    private func updateTopVisibleMessageRange(_ value: ChatTopVisibleMessageRange?) {
        if value != self.topVisibleMessageRangeValue || !self.topVisibleMessageRangeValueInitialized {
            self.topVisibleMessageRangeValueInitialized = true
            self.topVisibleMessageRangeValue = value
            self.topVisibleMessageRange.set(.single(value))
        }
    }
    let topVisibleMessageRange = Promise<ChatTopVisibleMessageRange?>(nil)
    
    var isSelectionGestureEnabled = true

    private var overscrollView: ComponentHostView<Empty>?
    var nextChannelToRead: (peer: EnginePeer, threadData: (id: Int64, data: MessageHistoryThreadData)?, unreadCount: Int, location: TelegramEngine.NextUnreadChannelLocation)?
    var offerNextChannelToRead: Bool = false
    var nextChannelToReadDisplayName: Bool = false
    private var currentOverscrollExpandProgress: CGFloat = 0.0
    private var freezeOverscrollControl: Bool = false
    private var freezeOverscrollControlProgress: Bool = false
    private var feedback: HapticFeedback?
    var openNextChannelToRead: ((EnginePeer, (id: Int64, data: MessageHistoryThreadData)?, TelegramEngine.NextUnreadChannelLocation) -> Void)?
    private var contentInsetAnimator: DisplayLinkAnimator?

    private let adMessagesContext: AdMessagesHistoryContext?
    private var adMessagesDisposable: Disposable?
    private var preloadAdPeerName: String?
    private let preloadAdPeerDisposable = MetaDisposable()
    private var didSetupRecommendedChannelsPreload = false
    private let preloadRecommendedChannelsDisposable = MetaDisposable()
    private var seenAdIds: [Data] = []
    private var pendingDynamicAdMessages: [Message] = []
    private var pendingDynamicAdMessageInterval: Int?
    private var remainingDynamicAdMessageInterval: Int?
    private var remainingDynamicAdMessageDistance: CGFloat?
    private var nextPendingDynamicMessageId: Int32 = 1
    private var allAdMessages: (fixed: Message?, opportunistic: [Message], version: Int) = (nil, [], 0) {
        didSet {
            self.allAdMessagesPromise.set(.single(self.allAdMessages))
        }
    }
    private let allAdMessagesPromise = Promise<(fixed: Message?, opportunistic: [Message], version: Int)>((nil, [], 0))
    private var seenMessageIds = Set<MessageId>()
    
    private var refreshDisplayedItemRangeTimer: SwiftSignalKit.Timer?
    
    private var genericReactionEffect: String?
    private var genericReactionEffectDisposable: Disposable?
    
    private var visibleMessageRange = Atomic<VisibleMessageRange?>(value: nil)
    
    private let clientId: Atomic<Int32>
    
    private var translationLang: (fromLang: String?, toLang: String)?
    
    private var allowDustEffect: Bool = true
    private var dustEffectLayer: DustEffectLayer?
    
    var frozenMessageForScrollingReset: EngineMessage.Id?
    
    private var hasDisplayedBusinessBotMessageTooltip: Bool = false
    
    private let _isReady = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var isReady: Signal<Bool, NoError> {
        return self._isReady.get()
    }
    private var didSetReady: Bool = false
    
    private let initTimestamp: Double
    
    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>), chatLocation: ChatLocation, chatLocationContextHolder: Atomic<ChatLocationContextHolder?>, adMessagesContext: AdMessagesHistoryContext?, tag: HistoryViewInputTag?, source: ChatHistoryListSource, subject: ChatControllerSubject?, controllerInteraction: ChatControllerInteraction, selectedMessages: Signal<Set<MessageId>?, NoError>, mode: ChatHistoryListMode = .bubbles, rotated: Bool = false, isChatPreview: Bool, messageTransitionNode: @escaping () -> ChatMessageTransitionNodeImpl?) {
        self.initTimestamp = CFAbsoluteTimeGetCurrent()
        
        var tag = tag
        if case .pinnedMessages = subject {
            tag = .tag(.pinned)
        }
        
        self.context = context
        self.chatLocation = chatLocation
        self.chatLocationContextHolder = chatLocationContextHolder
        self.source = source
        self.subject = subject
        self.tag = tag
        self.controllerInteraction = controllerInteraction
        self.selectedMessages = selectedMessages
        self.messageTransitionNode = messageTransitionNode
        self.mode = mode
        
        if SGSimpleSettings.shared.disableSnapDeletionEffect { self.allowDustEffect = false }
        if let data = context.currentAppConfiguration.with({ $0 }).data {
            if let _ = data["ios_killswitch_disable_unread_alignment"] {
                self.enableUnreadAlignment = false
            }
            if let _ = data["ios_killswitch_disable_dust_effect"] {
                self.allowDustEffect = false
            }
        }
        
        let presentationData = updatedPresentationData.initial
        self.currentPresentationData = ChatPresentationData(theme: ChatPresentationThemeData(theme: presentationData.theme, wallpaper: presentationData.chatWallpaper), fontSize: presentationData.chatFontSize, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, disableAnimations: true, largeEmoji: presentationData.largeEmoji, chatBubbleCorners: presentationData.chatBubbleCorners, animatedEmojiScale: 1.0)
        
        self.chatPresentationDataPromise = Promise()
        
        self.prefetchManager = InChatPrefetchManager(context: context)
        
        self.adMessagesContext = adMessagesContext
        var adMessages: Signal<(interPostInterval: Int32?, messages: [Message], startDelay: Int32?, betweenDelay: Int32?), NoError>
        if case .bubbles = mode, let adMessagesContext {
            let peerId = adMessagesContext.peerId
            if peerId.namespace == Namespaces.Peer.CloudUser {
                adMessages = .single((nil, [], nil, nil))
            } else {
                if context.sharedContext.immediateExperimentalUISettings.fakeAds {
                    adMessages = context.engine.data.get(
                        TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)
                    )
                    |> map { peer -> (interPostInterval: Int32?, messages: [Message], startDelay: Int32?, betweenDelay: Int32?) in
                        let fakeAdMessages: [Message] = (0 ..< 10).map { i -> Message in
                            var attributes: [MessageAttribute] = []
                            
                            let mappedMessageType: AdMessageAttribute.MessageType = .sponsored
                            attributes.append(AdMessageAttribute(opaqueId: "fake_ad_\(i)".data(using: .utf8)!, messageType: mappedMessageType, url: "t.me/telegram", buttonText: "VIEW", sponsorInfo: nil, additionalInfo: nil, canReport: false, hasContentMedia: false, minDisplayDuration: nil, maxDisplayDuration: nil))
                            
                            var messagePeers = SimpleDictionary<PeerId, Peer>()
                            
                            if let peer {
                                messagePeers[peer.id] = peer._asPeer()
                            }
                            
                            let author: Peer = TelegramChannel(
                                id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1)),
                                accessHash: nil,
                                title: "Fake Ad",
                                username: nil,
                                photo: [],
                                creationDate: 0,
                                version: 0,
                                participationStatus: .left,
                                info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),
                                flags: [],
                                restrictionInfo: nil,
                                adminRights: nil,
                                bannedRights: nil,
                                defaultBannedRights: nil,
                                usernames: [],
                                storiesHidden: nil,
                                nameColor: .blue,
                                backgroundEmojiId: nil,
                                profileColor: nil,
                                profileBackgroundEmojiId: nil,
                                emojiStatus: nil,
                                approximateBoostLevel: nil,
                                subscriptionUntilDate: nil,
                                verificationIconFileId: nil,
                                sendPaidMessageStars: nil,
                                linkedMonoforumId: nil
                            )
                            messagePeers[author.id] = author
                            
                            let messageText = "Fake Ad N\(i)"
                            let messageHash = (messageText.hashValue &+ 31 &* peerId.hashValue) &* 31 &+ author.id.hashValue
                            let messageStableVersion = UInt32(bitPattern: Int32(truncatingIfNeeded: messageHash))
                            
                            return Message(
                                stableId: 0,
                                stableVersion: messageStableVersion,
                                id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: 0),
                                globallyUniqueId: nil,
                                groupingKey: nil,
                                groupInfo: nil,
                                threadId: nil,
                                timestamp: Int32.max - 1,
                                flags: [.Incoming],
                                tags: [],
                                globalTags: [],
                                localTags: [],
                                customTags: [],
                                forwardInfo: nil,
                                author: author,
                                text: messageText,
                                attributes: attributes,
                                media: [],
                                peers: messagePeers,
                                associatedMessages: SimpleDictionary<MessageId, Message>(),
                                associatedMessageIds: [],
                                associatedMedia: [:],
                                associatedThreadInfo: nil,
                                associatedStories: [:]
                            )
                        }
                        return (10, fakeAdMessages, nil, nil)
                    }
                } else {
                    adMessages = adMessagesContext.state
                }
            }
        } else {
            adMessages = .single((nil, [], nil, nil))
        }
        
        let clientId = Atomic<Int32>(value: nextClientId)
        self.clientId = clientId
        nextClientId += 1
        
        super.init()
        
        self.rotated = rotated
        if rotated {
            self.transform = CATransform3DMakeRotation(CGFloat(Double.pi), 0.0, 0.0, 1.0)
        }

        self.clipsToBounds = false
        
        self.beginAdMessageManagement(adMessages: adMessages)
        
        self.accessibilityPageScrolledString = { [weak self] row, count in
            if let strongSelf = self {
                return strongSelf.currentPresentationData.strings.VoiceOver_ScrollStatus(row, count).string
            } else {
                return ""
            }
        }
        self.accessibilityPageScrolledRangeString = { from, to, count in
            return "Сообщения с \(from) по \(to) из \(count)"
        }
        self.accessibilityAbsoluteScrollInfo = { [weak self] visibleLocalIndices in
            guard let strongSelf = self else {
                print("[VO-DEBUG] absoluteScrollInfo: self is nil")
                return nil
            }
            guard let historyView = (strongSelf.opaqueTransactionState as? ChatHistoryTransactionOpaqueState)?.historyView else {
                print("[VO-DEBUG] absoluteScrollInfo: no historyView in opaqueTransactionState")
                return nil
            }
            let entries = historyView.filteredEntries
            guard !entries.isEmpty, !visibleLocalIndices.isEmpty else {
                print("[VO-DEBUG] absoluteScrollInfo: entries=\(entries.count), visibleLocalIndices=\(visibleLocalIndices)")
                return nil
            }
            
            print("[VO-DEBUG] absoluteScrollInfo: entries.count=\(entries.count), visibleLocalIndices=\(visibleLocalIndices.sorted())")
            
            var minAbsolute: Int?
            var maxAbsolute: Int?
            var totalCount: Int?
            var locationsFound = 0
            var locationsNil = 0
            
            for localIndex in visibleLocalIndices {
                let entryIndex = entries.count - 1 - localIndex
                guard entryIndex >= 0, entryIndex < entries.count else {
                    print("[VO-DEBUG] absoluteScrollInfo: localIndex=\(localIndex) -> entryIndex=\(entryIndex) OUT OF BOUNDS (entries.count=\(entries.count))")
                    continue
                }
                let entry = entries[entryIndex]
                let location: MessageHistoryEntryLocation?
                switch entry {
                case let .MessageEntry(_, _, _, loc, _, _):
                    location = loc
                case let .MessageGroupEntry(_, messages, _):
                    location = messages.first?.4
                default:
                    location = nil
                }
                if let location = location {
                    locationsFound += 1
                    let absIndex = location.count - location.index
                    if let current = minAbsolute {
                        minAbsolute = min(current, absIndex)
                    } else {
                        minAbsolute = absIndex
                    }
                    if let current = maxAbsolute {
                        maxAbsolute = max(current, absIndex)
                    } else {
                        maxAbsolute = absIndex
                    }
                    totalCount = location.count
                } else {
                    locationsNil += 1
                }
            }
            
            print("[VO-DEBUG] absoluteScrollInfo: locationsFound=\(locationsFound), locationsNil=\(locationsNil), min=\(minAbsolute as Any), max=\(maxAbsolute as Any), total=\(totalCount as Any)")
            
            if let first = minAbsolute, let last = maxAbsolute, let total = totalCount {
                return (first: first, last: last, total: total)
            }
            return nil
        }
        self.accessibilityLayoutChangedOnScroll = false
        self.accessibilityStatusAnnouncementOnScroll = false
        self.accessibilityNavigationOrder = .reversed

        // VoiceOver buffer expansion.
        //
        // We widen `invisibleInset` while VO is active so that more
        // message nodes are materialised at once and
        // `customAccessibilityElements` can collect real
        // `composeBubbleAccessibilityPayload` data for them — allowing
        // swipes to traverse messages in array order instead of jumping
        // to "…" placeholders.
        //
        // **10_000 pt** is a deliberate compromise:
        //  • Earlier value 1_000_000 materialised *every* loaded entry
        //    at once.  On media-heavy channels with tall image bubbles
        //    (e.g. «ТАРАС СИДОРЕЦ💡» — 77 entries, span 63 551 pt,
        //    individual bubbles 1300–1644 pt) the resulting
        //    CoreAnimation Render Encoder commit ran out of its
        //    serialisation buffer and aborted with
        //    `Failed to allocate ... bytes` in
        //    `CA::Render::Encoder::grow` (logged 2026-05-13).
        //  • 20_000 fixed the crash but the user reported visible
        //    slowdown on channel entry — materialising even ~50
        //    medium bubbles up-front is still expensive for image-
        //    backed content.
        //  • 10_000 pt covers ~20-25 medium text bubbles or ~10
        //    media bubbles on each side of viewport — enough that
        //    swipe navigation flows over a screenful or two, but
        //    cheap enough that channel entry doesn't stall.
        //  • Past the buffer, ListView's edge-scroll mechanism
        //    materialises the next batch organically.  This is
        //    coarser than full materialisation but matches the
        //    UITableView accessibility model users are familiar
        //    with.
        //
        // If `customAccessibilityElements` consistently runs out of
        // entries on media-light channels, raise the value here in
        // 10k increments; for very heavy channels lower it further.
        let updateFullMaterialization: () -> Void = { [weak self] in
            guard let self else { return }
            let shouldForce = UIAccessibility.isVoiceOverRunning
            let desired: CGFloat? = shouldForce ? 10_000.0 : nil
            if self.accessibilityInvisibleInsetOverride != desired {
                let previous = self.accessibilityInvisibleInsetOverride
                self.accessibilityInvisibleInsetOverride = desired
                print("[VO-CHAT] full-materialisation toggled: voRunning=\(shouldForce) override=\(previous.map { String(format: "%.0f", $0) } ?? "nil")->\(desired.map { String(format: "%.0f", $0) } ?? "nil")")
            }

            // NOTE: tried `self.view.accessibilityElementsHidden =
            // shouldForce` here to force iOS to consult only our
            // `customAccessibilityElements` array, but it had the
            // opposite of the intended effect — VoiceOver landed on
            // the first proxy correctly, then on the very next swipe
            // dropped focus entirely and escaped to the navbar
            // (`NavigationButtonItemNode` in the captured logs).
            // Apparently iOS uses `customAccessibilityElements` only
            // for the initial query and relies on the subview tree
            // for sequential navigation between elements.  Hiding the
            // subtree therefore breaks the second-and-after step.
            //
            // We must accept a residual amount of `_ASDisplayView`
            // competition for spatial focus and address bubble-vs-
            // proxy conflicts by other means (e.g. matching focus
            // back to a proxy via `match=source-view` in the focus
            // handler, which is what already runs in ListView).

            // When VoiceOver turns off, demote every bubble we promoted to
            // a leaf back to a container.  Without this, Switch Control /
            // automation / accessibility inspector would keep seeing each
            // message as an opaque blob even after VoiceOver is gone.
            // Dead entries are dropped automatically by
            // `NSHashTable.weakObjects()`.
            if !shouldForce {
                // Restore every bubble we promoted to a leaf while
                // VoiceOver was running.  Switch Control, automation,
                // and the accessibility inspector all rely on the
                // bubble's own accessibility tree being visible again.
                for promotedNode in self.voPromotedItemNodes.allObjects {
                    promotedNode.isAccessibilityElement = false
                    promotedNode.view.accessibilityElementsHidden = false
                    promotedNode.accessibilityLabel = nil
                    promotedNode.accessibilityValue = nil
                    promotedNode.accessibilityHint = nil
                    promotedNode.accessibilityIdentifier = nil
                    promotedNode.view.accessibilityCustomActions = nil
                }
                self.voPromotedItemNodes.removeAllObjects()
            }
        }
        updateFullMaterialization()
        self.voiceOverStatusObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[VO-CHAT] voiceOverStatusDidChange notification received: voRunning=\(UIAccessibility.isVoiceOverRunning)")
            updateFullMaterialization()
        }
        self.elementFocusedObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVoiceOverFocusChanged(notification: notification)
        }

        self.accessibilityDirectionalAnnouncement = { [weak self] fromIndex, toIndex in
            guard let self, abs(toIndex - fromIndex) == 1 else { return nil }
            let strings = self.currentPresentationData.strings
            if toIndex < fromIndex {
                return strings.primaryComponent.dict["VoiceOver.Chat.NextMessage"]
                    ?? strings.secondaryComponent?.dict["VoiceOver.Chat.NextMessage"]
                    ?? "next message"
            } else {
                return strings.primaryComponent.dict["VoiceOver.Chat.PreviousMessage"]
                    ?? strings.secondaryComponent?.dict["VoiceOver.Chat.PreviousMessage"]
                    ?? "previous message"
            }
        }

        // **Custom VoiceOver rotor for messages.**
        //
        // Rationale: the standard `accessibilityElements` swipe-next
        // traversal in chat history is unreliable for fully off-screen
        // messages — VoiceOver filters elements whose
        // `accessibilityFrame` falls outside the focus engine's
        // "reachable region" (~1–2 viewport heights), so a 40 000pt
        // chat buffer can't be navigated end-to-end with horizontal
        // swipes alone.  A custom rotor gives us authoritative control:
        // iOS calls our `itemSearchBlock` for each `.next`/`.previous`
        // step, we compute the target `localIndex`, scroll the bubble
        // into the viewport via `transaction(scrollToItem:)`, and
        // return the now-materialised item node's view as the focus
        // target.  No spatial heuristic, no oscillation, works for
        // every message regardless of distance from the current scroll
        // offset.
        //
        // Activation: VoiceOver user finds the "Сообщения" rotor with
        // a two-finger rotation gesture (or vertical swipe with a
        // single finger after selecting it via the rotor menu), then
        // up/down swipes navigate one message at a time.
        let rotorName: String = self.currentPresentationData.strings.primaryComponent.dict["VoiceOver.Chat.MessagesRotor"]
            ?? self.currentPresentationData.strings.secondaryComponent?.dict["VoiceOver.Chat.MessagesRotor"]
            ?? "Сообщения"
        let messagesRotor = UIAccessibilityCustomRotor(name: rotorName) { [weak self] predicate in
            guard let self else { return nil }
            return self.rotorTarget(direction: predicate.searchDirection, currentItem: predicate.currentItem)
        }
        // `accessibilityCustomRotors` lives on UIView; defer until the
        // view is loaded.  Touching `self.view` from init can trigger
        // unexpected layout, so we install the rotor on the next run-
        // loop tick.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var existing = self.view.accessibilityCustomRotors ?? []
            existing.append(messagesRotor)
            self.view.accessibilityCustomRotors = existing
        }

        self.dynamicBounceEnabled = !self.currentPresentationData.disableAnimations
        self.experimentalSnapScrollToItem = false
        
        //self.debugInfo = true
        
        self.messageProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.updateViewCountForMessageIds(messageIds: Set(messageIds.map(\.messageId)), clientId: clientId.with { $0 })
        }
        self.messageWithReactionsProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.updateReactionsForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
        }
        self.seenLiveLocationProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.updateSeenLiveLocationForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
        }
        self.unsupportedMessageProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.updateUnsupportedMediaForMessageIds(messageIds: messageIds)
        }
        self.refreshMediaProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.refreshSecretMediaMediaForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
        }
        self.refreshStoriesProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.refreshStoriesForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
        }
        self.translationProcessingManager.process = { [weak self, weak context] messageIds in
            if let context, let translationLang = self?.translationLang {
                let _ = translateMessageIds(context: context, messageIds: Array(messageIds.map(\.messageId)), fromLang: translationLang.fromLang, toLang: translationLang.toLang, viaText: !context.isPremium || SGSimpleSettings.shared.translationBackend == SGSimpleSettings.TranslationBackend.gtranslate.rawValue).startStandalone()
            }
        }
        self.factCheckProcessingManager.process = { [weak context] messageIds in
            if let context {
                let _ = context.engine.messages.getMessagesFactCheck(messageIds: Array(messageIds.map(\.messageId))).startStandalone()
            }
        }
        
        self.messageMentionProcessingManager.process = { [weak self, weak context] messageIds in
            if let strongSelf = self {
                if strongSelf.canReadHistoryValue {
                    context?.account.viewTracker.updateMarkMentionsSeenForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
                } else {
                    strongSelf.messageIdsScheduledForMarkAsSeen.formUnion(messageIds.map(\.messageId))
                }
            }
        }
        
        self.unseenReactionsProcessingManager.process = { [weak self] messageIds in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.canReadHistoryValue && !strongSelf.suspendReadingReactions && !strongSelf.context.sharedContext.immediateExperimentalUISettings.skipReadHistory {
                strongSelf.context.account.viewTracker.updateMarkReactionsSeenForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
            } else {
                strongSelf.messageIdsWithReactionsScheduledForMarkAsSeen.formUnion(messageIds.map(\.messageId))
            }
        }
        
        self.extendedMediaProcessingManager.process = { [weak self] messageIds in
            guard let strongSelf = self else {
                return
            }
            strongSelf.context.account.viewTracker.updatedExtendedMediaForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
        }
        
        self.inlineGroupCallsProcessingManager.process = { [weak context] messageIds in
            context?.account.viewTracker.refreshInlineGroupCallsForMessageIds(messageIds: Set(messageIds.map(\.messageId)))
        }
        
        self.preloadPages = false
        
        self.beginChatHistoryTransitions(resetScrolling: false, switchedToAnotherSource: false)
        self.beginReadHistoryManagement()
        
        if let subject = subject, case let .message(messageSubject, highlight, _, setupReply) = subject {
            let initialSearchLocation: ChatHistoryInitialSearchLocation
            switch messageSubject {
            case let .id(id):
                initialSearchLocation = .id(id)
            case let .timestamp(timestamp):
                if let peerId = self.chatLocation.peerId {
                    initialSearchLocation = .index(MessageIndex(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: 1), timestamp: timestamp))
                } else {
                    //TODO:implement
                    initialSearchLocation = .index(MessageIndex.absoluteUpperBound())
                }
            }
            self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .InitialSearch(subject: MessageHistoryInitialSearchSubject(location: initialSearchLocation, quote: (highlight?.quote).flatMap { quote in MessageHistoryInitialSearchSubject.Quote(string: quote.string, offset: quote.offset) }, todoTaskId: highlight?.todoTaskId), count: historyMessageCount, highlight: highlight != nil, setupReply: setupReply), id: 0)
        } else if let subject = subject, case let .pinnedMessages(maybeMessageId) = subject, let messageId = maybeMessageId {
            self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .InitialSearch(subject: MessageHistoryInitialSearchSubject(location: .id(messageId)), count: historyMessageCount, highlight: true, setupReply: false), id: 0)
        } else {
            self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Initial(count: historyMessageCount), id: 0)
        }
        self.chatHistoryLocationPromise.set(self.chatHistoryLocationValue!)
        
        self.generalScrollDirectionUpdated = { [weak self] direction in
            guard let strongSelf = self else {
                return
            }
            let prefetchDirectionIsToLater = direction == .up
            if strongSelf.currentPrefetchDirectionIsToLater != prefetchDirectionIsToLater {
                strongSelf.currentPrefetchDirectionIsToLater = prefetchDirectionIsToLater
                if strongSelf.currentPrefetchDirectionIsToLater {
                    strongSelf.prefetchManager.updateMessages(strongSelf.currentLaterPrefetchMessages, directionIsToLater: strongSelf.currentPrefetchDirectionIsToLater)
                } else {
                    strongSelf.prefetchManager.updateMessages(strongSelf.currentEarlierPrefetchMessages, directionIsToLater: strongSelf.currentPrefetchDirectionIsToLater)
                }
            }
        }
        
        self.displayedItemRangeChanged = { [weak self] displayedRange, opaqueTransactionState in
            if let strongSelf = self, let transactionState = opaqueTransactionState as? ChatHistoryTransactionOpaqueState {
                strongSelf.processDisplayedItemRangeChanged(displayedRange: displayedRange, transactionState: transactionState)
            }
        }
        
        self.refreshDisplayedItemRangeTimer = SwiftSignalKit.Timer(timeout: 10.0, repeat: true, completion: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.updateVisibleItemRange(force: true)
        }, queue: .mainQueue())
        self.refreshDisplayedItemRangeTimer?.start()
        
        self.beginPresentationDataManagement(updated: updatedPresentationData.signal)
        
        self.visibleContentOffsetChanged = { [weak self] offset in
            if let strongSelf = self {
                strongSelf.contentPositionChanged(offset)
                strongSelf.maybePostAccessibilityLayoutChangedOnScroll()
                
                if strongSelf.tag == nil {
                    var atBottom = false
                    var offsetFromBottom: CGFloat?
                    switch offset {
                        case let .known(offsetValue):
                            if offsetValue.isLessThanOrEqualTo(0.0) {
                                atBottom = true
                                offsetFromBottom = offsetValue
                            }
                            //print("offsetValue: \(offsetValue)")
                        default:
                            break
                    }
                    
                    if atBottom != strongSelf.isScrollAtBottomPosition {
                        strongSelf.isScrollAtBottomPosition = atBottom
                        strongSelf.updateReadHistoryActions()
                        
                        strongSelf.isScrollAtBottomPositionUpdated?()
                    }

                    strongSelf.maybeUpdateOverscrollAction(offset: offsetFromBottom)
                }
                
                var lastMessageId: MessageId?
                if let historyView = (strongSelf.opaqueTransactionState as? ChatHistoryTransactionOpaqueState)?.historyView {
                    if historyView.originalView.laterId == nil && !historyView.originalView.holeLater {
                        lastMessageId = historyView.originalView.entries.last?.message.id
                    }
                }
                
                var maxMessage: MessageIndex?
                strongSelf.forEachVisibleMessageItemNode { itemNode in
                    if let item = itemNode.item {
                        var matches = false
                        if itemNode.frame.maxY < strongSelf.insets.top {
                            return
                        }
                        if itemNode.frame.minY >= strongSelf.insets.top {
                            matches = true
                        } else if itemNode.frame.minY >= strongSelf.insets.top - 100.0 {
                            matches = true
                        } else if let lastMessageId {
                            for (message, _) in item.content {
                                if message.id == lastMessageId {
                                    matches = true
                                }
                            }
                        }
                        
                        if matches {
                            for (message, _) in item.content {
                                if strongSelf.chatLocation.threadId != nil {
                                    if message.id.namespace != Namespaces.Message.Cloud {
                                        matches = false
                                        break
                                    }
                                }
                            }
                        }
                        
                        if matches {
                            var maxItemIndex: MessageIndex?
                            for (message, _) in item.content {
                                if let maxItemIndexValue = maxItemIndex {
                                    if maxItemIndexValue < message.index {
                                        maxItemIndex = message.index
                                    }
                                } else {
                                    maxItemIndex = message.index
                                }
                            }
                            
                            if let maxItemIndex {
                                if let maxMessageValue = maxMessage {
                                    if maxMessageValue < maxItemIndex {
                                        maxMessage = maxItemIndex
                                    }
                                } else {
                                    maxMessage = maxItemIndex
                                }
                            }
                        }
                    }
                }
                if let maxMessage {
                    strongSelf.updateMaxVisibleReadIncomingMessageIndex(maxMessage)
                }
            }
        }
        
        self.loadedMessagesFromCachedDataDisposable = (self._cachedPeerDataAndMessages.get() |> map { dataAndMessages -> MessageId? in
            return dataAndMessages.0?.messageIds.first
        } |> distinctUntilChanged(isEqual: { $0 == $1 })
        |> mapToSignal { messageId -> Signal<Void, NoError> in
            if let messageId = messageId {
                return context.engine.messages.getMessagesLoadIfNecessary([messageId])
                |> `catch` { _ in
                    return .single(.result([]))
                }
                |> map { _ -> Void in return Void() }
            } else {
                return .complete()
            }
        }).startStrict()
        
        self.beganInteractiveDragging = { [weak self] _ in
            self?.isInteractivelyScrollingValue = true
            self?.isInteractivelyScrollingPromise.set(true)
            self?.beganDragging?()
            //self?.updateHistoryScrollingArea(transition: .immediate)
        }

        self.endedInteractiveDragging = { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.offerNextChannelToRead, strongSelf.currentOverscrollExpandProgress >= 0.99 {
                if let nextChannelToRead = strongSelf.nextChannelToRead {
                    strongSelf.freezeOverscrollControl = true
                    strongSelf.openNextChannelToRead?(nextChannelToRead.peer, nextChannelToRead.threadData, nextChannelToRead.location)
                } else {
                    strongSelf.freezeOverscrollControlProgress = true
                    strongSelf.scroller.contentInset = UIEdgeInsets(top: 94.0 + 12.0, left: 0.0, bottom: 0.0, right: 0.0)
                    Queue.mainQueue().after(0.3, {
                        let animator = DisplayLinkAnimator(duration: 0.2, from: 1.0, to: 0.0, update: { rawT in
                            guard let strongSelf = self else {
                                return
                            }
                            let t = listViewAnimationCurveEaseInOut(rawT)
                            let value = (94.0 + 12.0) * t
                            strongSelf.scroller.contentInset = UIEdgeInsets(top: value, left: 0.0, bottom: 0.0, right: 0.0)
                        }, completion: {
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.contentInsetAnimator = nil
                            strongSelf.scroller.contentInset = UIEdgeInsets()
                            strongSelf.freezeOverscrollControlProgress = false
                        })
                        strongSelf.contentInsetAnimator = animator
                    })
                }
            }
        }
        
        self.didEndScrolling = { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isInteractivelyScrollingValue = false
            strongSelf.isInteractivelyScrollingPromise.set(false)
            //strongSelf.updateHistoryScrollingArea(transition: .immediate)
        }

        /*self.updateScrollingIndicator = { [weak self] scrollingState, transition in
            guard let strongSelf = self else {
                return
            }
            strongSelf.scrollingState = scrollingState
            strongSelf.updateHistoryScrollingArea(transition: transition)
        }*/
        
        let selectionRecognizer = ChatHistoryListSelectionRecognizer(target: self, action: #selector(self.selectionPanGesture(_:)))
        selectionRecognizer.shouldBegin = { [weak self] in
            guard let strongSelf = self else {
                return false
            }
            return strongSelf.isSelectionGestureEnabled
        }
        self.view.addGestureRecognizer(selectionRecognizer)
        
        self.loadNextGenericReactionEffect(context: context)
    }
    
    deinit {
        self.historyDisposable.dispose()
        self.readHistoryDisposable.dispose()
        self.interactiveReadActionDisposable?.dispose()
        self.interactiveReadReactionsDisposable?.dispose()
        self.canReadHistoryDisposable?.dispose()
        self.loadedMessagesFromCachedDataDisposable?.dispose()
        self.preloadAdPeerDisposable.dispose()
        self.preloadRecommendedChannelsDisposable.dispose()
        self.refreshDisplayedItemRangeTimer?.invalidate()
        self.genericReactionEffectDisposable?.dispose()
        self.adMessagesDisposable?.dispose()
        self.presentationDataDisposable?.dispose()
        if let observer = self.voiceOverStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.elementFocusedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func makeMessageAccessibilityElement(for itemNode: ASDisplayNode) -> UIAccessibilityElement? {
        let label = itemNode.view.accessibilityLabel ?? ""
        let value = itemNode.view.accessibilityValue ?? ""
        guard !label.isEmpty || !value.isEmpty else {
            return nil
        }
        
        let element = makeAccessibilityElement(of: itemNode, container: self, trackFocus: true)
        element.accessibilityLabel = label
        element.accessibilityValue = value
        element.accessibilityTraits = itemNode.view.accessibilityTraits
        element.accessibilityHint = itemNode.view.accessibilityHint
        element.accessibilityIdentifier = itemNode.view.accessibilityIdentifier
        return element
    }

    private func accessibilityData(for object: Any, clippedTo visibleScreenRect: CGRect) -> (label: String?, value: String?, hint: String?, identifier: String?, traits: UIAccessibilityTraits, customActions: [UIAccessibilityCustomAction]?, frame: CGRect)? {
        let frame: CGRect
        let label: String?
        let value: String?
        let hint: String?
        let identifier: String?
        let traits: UIAccessibilityTraits
        let customActions: [UIAccessibilityCustomAction]?

        if let element = object as? UIAccessibilityElement {
            frame = element.accessibilityFrame.intersection(visibleScreenRect)
            label = element.accessibilityLabel
            value = element.accessibilityValue
            hint = element.accessibilityHint
            identifier = element.accessibilityIdentifier
            traits = element.accessibilityTraits
            customActions = element.accessibilityCustomActions
        } else if let view = object as? UIView {
            let sourceFrame = view.isAccessibilityElement ? view.accessibilityFrame : UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
            frame = sourceFrame.intersection(visibleScreenRect)
            label = view.accessibilityLabel
            value = view.accessibilityValue
            hint = view.accessibilityHint
            identifier = view.accessibilityIdentifier
            traits = view.accessibilityTraits
            customActions = view.accessibilityCustomActions
        } else {
            return nil
        }

        guard !frame.isNull, frame.width > 1.0, frame.height > 1.0 else {
            return nil
        }

        return (label, value, hint, identifier, traits, customActions, frame)
    }

    /// Walks the **subnode** tree of a message item (`ASDisplayNode` level,
    /// not `UIView`) and produces a single composed accessibility payload
    /// built primarily from `AccessibilityAreaNode` instances and from any
    /// other subnode that opts into `isAccessibilityElement = true` (custom
    /// reactions, share/comments buttons, etc.).
    ///
    /// Why subnodes, not subviews?  `ChatMessageBubbleItemNode` calls
    /// `messageAccessibilityArea.updateFrameClippedToAccessibilityContainers(...)`
    /// which sets `isAccessibilityElement = false` and frame to `.zero`
    /// whenever the bubble is currently clipped off-screen — a Telegram
    /// optimisation to avoid laying out an accessibility frame for items
    /// the user cannot see.  When the bubble materialises but is still
    /// outside the visible window (full-materialisation mode), the area's
    /// `accessibilityLabel` / `accessibilityValue` / `accessibilityCustomActions`
    /// are *still set correctly* (the bubble's "common" accessibility
    /// payload is recomputed on every layout pass), they just aren't being
    /// surfaced as a UIKit leaf.  Walking the node tree lets us read the
    /// data straight off the `AccessibilityAreaNode`, bypassing the leaf
    /// gate, so VoiceOver can speak the actual message text instead of
    /// whichever stray leaf (e.g. "1 комментарий") happens to still be
    /// active.
    /// Walk the ASDisplayKit subnode tree of a bubble and clear
    /// `isAccessibilityElement` on every descendant.  This eliminates
    /// `_ASDisplayView` leaves (date+status, reactions, share button,
    /// comments button, link previews, text segments) that VoiceOver
    /// otherwise picks up as spatial focus competitors next to our
    /// pooled proxies and the bubble's promoted leaf — the
    /// `focus-handler-skip reason=focus-left-list type=_ASDisplayView`
    /// (and its `offscreen-uiview-ignored` cousin) cascade in the
    /// logs that strands the cursor after two-three swipes.
    ///
    /// Notes on safety:
    ///
    /// • We walk `subnodes` (ASDisplayKit's own tree), not
    ///   `view.subviews`.  An earlier attempt that walked
    ///   `subviews` triggered an `objc_terminate` abort, almost
    ///   certainly from mutating `isAccessibilityElement` on a
    ///   `_ASDisplayView` whose backing node had assertions about
    ///   its accessibility state.  Subnode traversal stays inside
    ///   the framework's own hierarchy.
    ///
    /// • We DON'T demote the root (the item node itself) — it is
    ///   promoted as the single bubble-level leaf elsewhere, which
    ///   is what keeps `proxy.sourceView` a valid focus context.
    ///
    /// • No restore on VoiceOver-off: the affected subnodes are
    ///   recycled along with the bubble on next layout / cell
    ///   reuse; fresh instances come with default accessibility
    ///   flags.  The bubble-level promotion is undone in the
    ///   normal `voPromotedItemNodes` cleanup loop.
    fileprivate static func suppressCompetingLeaves(in node: ASDisplayNode, isRoot: Bool) {
        if !isRoot {
            // **Unconditional** demotion at both node- and view-level.
            //
            // The previous revision gated the node-level set behind
            // `if node.isAccessibilityElement { ... }`, which silently
            // skipped the (very common) case where the *node* reports
            // `false` but the backing `_ASDisplayView` is treated as
            // an accessibility leaf by VoiceOver anyway — either
            // because UIKit infers it from a non-nil
            // `accessibilityLabel` / `accessibilityValue`, or because
            // ASDisplayKit's own
            // `CollectAccessibilityElementsForView` exposes the view
            // as a container when `[subnode accessibilityElementCount]
            // > 0` (see `_ASDisplayViewAccessiblity.mm:252`). Those
            // are the leaves that VoiceOver picks up as spatial
            // competitors to our pooled proxies, manifesting as the
            // "focus ping-pong between two visually-adjacent bubbles"
            // logged with `focus-handler-skip reason=focus-left-list
            // type=_ASDisplayView` / `offscreen-uiview-ignored`.
            //
            // Setting `node.isAccessibilityElement = false` forwards
            // to the view at load time, but only if the view *was
            // not yet loaded* when the property was assigned. For
            // already-loaded views we also reach for `node.view`
            // directly and stamp the same flag — plus null the
            // `accessibilityLabel/value/hint/customActions` chain so
            // UIKit's implicit-leaf heuristics have nothing left to
            // grab onto.
            //
            // We still DO NOT walk `view.subviews` here — the older
            // attempt that did crashed with `_objc_terminate` on
            // async image / layout, almost certainly because mutating
            // accessibility flags on a `_ASDisplayView` *during* its
            // owning node's layout pass violates an invariant inside
            // ASDisplayKit. By staying on `node.subnodes` we touch
            // only views whose backing nodes are part of our managed
            // subtree, where the framework expects mutations to be
            // legal between layout passes.
            node.isAccessibilityElement = false
            // CRITICAL: `node.view` is undefined on layer-backed nodes
            // (e.g. `ASImageNode` for chat photo thumbnails). The
            // `isNodeLoaded` check is *not* enough — layer-backed
            // nodes load their CALayer but never an associated view,
            // and `-[ASDisplayNode view]` aborts with
            // `'Call to -view undefined on layer-backed nodes'` if we
            // touch it. Skip them entirely.
            if node.isNodeLoaded && !node.isLayerBacked {
                // **Only** demote the leaf flag here. We intentionally
                // do NOT null `accessibilityLabel/value/hint/customActions`
                // on the backing view, even though that would also
                // disarm UIKit's implicit-leaf heuristic — because
                // `composeBubbleAccessibilityPayload` re-reads those
                // very properties from the AccessibilityAreaNode
                // subtree on *every* `customAccessibilityElements`
                // call (see `walk(_:isRoot:)` at line ~1701). Nulling
                // them turns every subsequent pass's payload into
                // `nil`, which surfaces in the logs as
                // `noData=75 finalCount=75` and gives every element
                // the placeholder label `"…"` — VoiceOver then reads
                // "ellipsis" for every message.
                //
                // Keeping the labels intact means UIKit MIGHT still
                // pick the view up as an implicit accessibility leaf
                // (since `_ASDisplayView`'s view-side
                // `isAccessibilityElement` can be flipped by other
                // signals), but in practice raw `_ASDisplayView`s
                // default to `false` and respect the explicit set
                // we make immediately above. If the leaf
                // competition resurfaces we move on to variant B
                // (override `accessibilityElements` on the bubble
                // root) rather than vandalising the payload.
                node.view.isAccessibilityElement = false
            }
        }
        for sub in node.subnodes ?? [] {
            suppressCompetingLeaves(in: sub, isRoot: false)
        }
    }

    /// Post `UIAccessibility.layoutChanged` on scroll to keep the
    /// accessibility-frame cache fresh.
    ///
    /// `customAccessibilityElements` stamps a synthetic
    /// `accessibilityFrame` onto every materialised bubble view. Those
    /// frames are computed against the *current* on-screen geometry —
    /// but if the list scrolls afterwards (programmatic
    /// `scrollVoiceOverFocusToItem`, momentum scroll, or a user's
    /// 3-finger VoiceOver scroll), the underlying bubbles move on
    /// screen while the cached `accessibilityFrame` values stay frozen
    /// at the old positions. VoiceOver's touch-explore hit-tests
    /// against those stale frames and finds nothing at the tap point —
    /// reproduced in user logs as "after 3-finger swipe, tap on a
    /// visible bubble stops focusing it".
    ///
    /// Posting `.layoutChanged` tells UIKit to invalidate its
    /// accessibility tree, which causes the next interaction (tap or
    /// swipe) to re-query `accessibilityElements` and rebuild fresh
    /// frames.
    ///
    /// Throttled to 100 ms because `visibleContentOffsetChanged`
    /// fires on every display-link tick during a flick scroll.
    private func maybePostAccessibilityLayoutChangedOnScroll() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let now = CACurrentMediaTime()
        if now - self.lastA11yLayoutChangedPostTime < 0.1 {
            return
        }
        self.lastA11yLayoutChangedPostTime = now
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// Locate the bubble's main `AccessibilityAreaNode` by walking the
    /// node subtree of a materialised message item.  Most chat rows have
    /// exactly one such node (`ChatMessageBubbleItemNode.messageAccessibility
    /// Area`), populated with the row's full label, value, traits and
    /// custom actions; auxiliary nodes (date separators, comments
    /// buttons, share buttons, reactions, …) live elsewhere in the tree
    /// and are intentionally not used as the row's leaf so that
    /// VoiceOver swipe traversal stays at the message-row granularity.
    /// Returns the *first* AccessibilityAreaNode found in pre-order
    /// traversal — which, in `ChatMessageBubbleItemNode`, is the
    /// canonical message area added to the node hierarchy in the
    /// initialiser.
    private func findMessageAccessibilityArea(in node: ASDisplayNode) -> AccessibilityAreaNode? {
        if let area = node as? AccessibilityAreaNode {
            return area
        }
        if let subnodes = node.subnodes {
            for subnode in subnodes {
                if let area = self.findMessageAccessibilityArea(in: subnode) {
                    return area
                }
            }
        }
        return nil
    }

    private func composeBubbleAccessibilityPayload(for itemNode: ListViewItemNode, clippedTo visibleScreenRect: CGRect) -> (label: String, value: String?, hint: String?, identifier: String?, traits: UIAccessibilityTraits, customActions: [UIAccessibilityCustomAction]?)? {
        // AAN-only label so VoiceOver speaks the message text — and just
        // the message text — when the cursor lands on the bubble.  Inner
        // leaves (comments button, share button, reaction chips, …) used
        // to be glued onto the label too, which gave the user a clumsy
        // "2 комментария, Фотография" instead of "Фотография".  Their
        // payload is preserved as `accessibilityCustomActions` so it
        // remains reachable through the rotor while VO is active.
        var primaryLabel: String?
        var primaryValue: String?
        var primaryHint: String?
        var primaryIdentifier: String?
        var primaryTraits: UIAccessibilityTraits = []
        var combinedActions: [UIAccessibilityCustomAction] = []
        var didFindAreaNode = false

        func walk(_ node: ASDisplayNode, isRoot: Bool) {
            if node.isHidden {
                return
            }
            if let area = node as? AccessibilityAreaNode {
                didFindAreaNode = true
                if primaryLabel == nil, let label = area.accessibilityLabel, !label.isEmpty, !label.hasPrefix("<") {
                    primaryLabel = label
                }
                if primaryValue == nil, let value = area.accessibilityValue, !value.isEmpty, !value.hasPrefix("<") {
                    primaryValue = value
                }
                if primaryHint == nil, let hint = area.accessibilityHint, !hint.isEmpty {
                    primaryHint = hint
                }
                if primaryIdentifier == nil, let identifier = area.accessibilityIdentifier, !identifier.isEmpty {
                    primaryIdentifier = identifier
                }
                primaryTraits.formUnion(area.accessibilityTraits)
                if let actions = area.view.accessibilityCustomActions {
                    combinedActions.append(contentsOf: actions)
                }
                return
            }
            if !isRoot, node.isAccessibilityElement {
                // Non-AAN leaf (comments / share / reactions): expose only
                // its custom actions, and synthesise an action with the
                // leaf's own label so the user can tap it via the rotor.
                if let actions = node.view.accessibilityCustomActions {
                    combinedActions.append(contentsOf: actions)
                }
                if let label = node.accessibilityLabel,
                   !label.isEmpty,
                   !label.hasPrefix("<") {
                    let nodeRef = node
                    let action = UIAccessibilityCustomAction(name: label) { _ in
                        return nodeRef.view.accessibilityActivate()
                    }
                    combinedActions.append(action)
                }
                return
            }
            for subnode in node.subnodes ?? [] {
                walk(subnode, isRoot: false)
            }
        }

        walk(itemNode, isRoot: true)

        if !didFindAreaNode || primaryLabel == nil {
            // Fall back to the UIView walker for oddball cells (date
            // headers, unread / loading markers, ad cells, …) that don't
            // embed an `AccessibilityAreaNode`.
            if let viewLeaf = self.collectMessageAccessibilityData(in: itemNode.view, clippedTo: visibleScreenRect) {
                return (
                    label: viewLeaf.label,
                    value: viewLeaf.value,
                    hint: viewLeaf.hint,
                    identifier: viewLeaf.identifier,
                    traits: viewLeaf.traits,
                    customActions: viewLeaf.customActions
                )
            }
        }

        guard let primaryLabel else {
            return nil
        }
        return (
            label: primaryLabel,
            value: primaryValue,
            hint: primaryHint,
            identifier: primaryIdentifier,
            traits: primaryTraits,
            customActions: combinedActions.isEmpty ? nil : combinedActions
        )
    }

    /// Walks the subview hierarchy of a message item and produces a single
    /// composed accessibility payload built **only** from real accessibility
    /// leaves (i.e. views whose `isAccessibilityElement == true`).  Each chat
    /// message exposes one primary leaf (`AccessibilityAreaNode`) carrying
    /// the message body label; richer messages may expose extra leaves for
    /// reactions or action buttons.  We combine their labels, custom actions
    /// and frames so VoiceOver hears the message as a single entity.
    private func collectMessageAccessibilityData(in rootView: UIView, clippedTo visibleScreenRect: CGRect) -> (label: String, value: String?, hint: String?, identifier: String?, traits: UIAccessibilityTraits, customActions: [UIAccessibilityCustomAction]?, frame: CGRect)? {
        var labels: [String] = []
        var primaryValue: String?
        var primaryHint: String?
        var primaryIdentifier: String?
        var combinedTraits: UIAccessibilityTraits = []
        var combinedActions: [UIAccessibilityCustomAction] = []
        var combinedFrame: CGRect?

        func append(label: String?, value: String?, hint: String?, identifier: String?, traits: UIAccessibilityTraits, actions: [UIAccessibilityCustomAction]?, frame: CGRect) {
            if let label, !label.isEmpty, !label.hasPrefix("<") {
                labels.append(label)
            } else if let value, !value.isEmpty, !value.hasPrefix("<") {
                labels.append(value)
            }
            if primaryValue == nil, let value, !value.isEmpty, !value.hasPrefix("<") {
                primaryValue = value
            }
            if primaryHint == nil, let hint, !hint.isEmpty {
                primaryHint = hint
            }
            if primaryIdentifier == nil, let identifier, !identifier.isEmpty {
                primaryIdentifier = identifier
            }
            combinedTraits.formUnion(traits)
            if let actions, !actions.isEmpty {
                combinedActions.append(contentsOf: actions)
            }
            if !frame.isNull, frame.width > 1.0, frame.height > 1.0 {
                if let current = combinedFrame {
                    combinedFrame = current.union(frame)
                } else {
                    combinedFrame = frame
                }
            }
        }

        func walk(_ view: UIView, isRoot: Bool) {
            if view.isHidden {
                return
            }
            if view.isAccessibilityElement {
                let rawFrame = view.accessibilityFrame.isNull
                    ? UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
                    : view.accessibilityFrame
                let frame = rawFrame.intersection(visibleScreenRect)
                append(
                    label: view.accessibilityLabel,
                    value: view.accessibilityValue,
                    hint: view.accessibilityHint,
                    identifier: view.accessibilityIdentifier,
                    traits: view.accessibilityTraits,
                    actions: view.accessibilityCustomActions,
                    frame: frame
                )
                // Don't descend into a leaf — its own children are private.
                return
            }
            if let elements = view.accessibilityElements {
                for element in elements {
                    if let element = element as? UIAccessibilityElement {
                        let frame = element.accessibilityFrame.intersection(visibleScreenRect)
                        append(
                            label: element.accessibilityLabel,
                            value: element.accessibilityValue,
                            hint: element.accessibilityHint,
                            identifier: element.accessibilityIdentifier,
                            traits: element.accessibilityTraits,
                            actions: element.accessibilityCustomActions,
                            frame: frame
                        )
                    } else if let nestedView = element as? UIView {
                        walk(nestedView, isRoot: false)
                    }
                }
                return
            }
            for subview in view.subviews {
                walk(subview, isRoot: false)
            }
        }

        walk(rootView, isRoot: true)

        guard !labels.isEmpty, let frame = combinedFrame else {
            return nil
        }
        let composedLabel = labels.joined(separator: ", ")
        return (
            label: composedLabel,
            value: primaryValue,
            hint: primaryHint,
            identifier: primaryIdentifier,
            traits: combinedTraits,
            customActions: combinedActions.isEmpty ? nil : combinedActions,
            frame: frame
        )
    }

    override public func customAccessibilityElements() -> [Any]? {
        var accessibilityElements: [Any] = []
        let trackDirectionalFocus = self.accessibilityDirectionalAnnouncement != nil
        var directionalCandidates: [(localIndex: Int, order: Int, element: Any)] = []
        var activeLocalIndices = Set<Int>()
        let contentOffset = self.scroller.contentOffset
        let visibleTop: CGFloat
        let visibleBottom: CGFloat
        if self.rotated {
            visibleTop = contentOffset.y + self.insets.bottom
            visibleBottom = contentOffset.y + self.visibleSize.height - self.insets.top
        } else {
            visibleTop = contentOffset.y + self.insets.top
            visibleBottom = contentOffset.y + self.visibleSize.height - self.insets.bottom
        }

        let voIsRunning = UIAccessibility.isVoiceOverRunning

        let visibleBoundsRect = CGRect(
            x: 0.0,
            y: self.rotated ? self.insets.bottom : self.insets.top,
            width: self.visibleSize.width,
            height: max(0.0, self.visibleSize.height - self.insets.top - self.insets.bottom)
        )
        // VoiceOver full-materialisation mode (see `accessibilityInvisibleInsetOverride`).
        // While VO is active we want the accessibility array to contain *every*
        // materialised message in the conversation, not just the on-screen ones.
        // To do that we widen both the local content-space rect (used for picking
        // item nodes) and the screen-space rect (used by `accessibilityData` to
        // clip child frames) to effectively unbounded values, so frames are
        // passed through with their natural geometry.  ListView's
        // `scrollAccessibilityFocusIntoViewIfNeeded` then pages the focused
        // element into view as the user swipes.
        let isFullMaterializationActive = self.accessibilityInvisibleInsetOverride != nil
        let visibleRect: CGRect
        if isFullMaterializationActive {
            let huge = CGFloat(1_000_000_000.0)
            visibleRect = CGRect(x: -huge / 2.0, y: -huge / 2.0, width: huge, height: huge)
        } else {
            visibleRect = CGRect(x: 0.0, y: visibleTop, width: self.visibleSize.width, height: max(0.0, visibleBottom - visibleTop))
        }
        var visibleScreenRect = UIAccessibility.convertToScreenCoordinates(visibleBoundsRect, in: self.view)
        if isFullMaterializationActive {
            let huge = CGFloat(1_000_000_000.0)
            visibleScreenRect = CGRect(x: -huge / 2.0, y: -huge / 2.0, width: huge, height: huge)
        } else {
            var currentClippingNode: ASDisplayNode? = self
            while let clippingNode = currentClippingNode {
                if let clippingContainer = clippingNode as? AccessibilityClippingContainer, let clippingFrame = clippingContainer.accessibilityClippingFrameInScreenCoordinates() {
                    visibleScreenRect = visibleScreenRect.intersection(clippingFrame)
                    if visibleScreenRect.isNull || visibleScreenRect.width <= 1.0 || visibleScreenRect.height <= 1.0 {
                        if voIsRunning {
                            print("[VO-CHAT] customAccessibilityElements: clipped-to-empty visibleScreenRect, returning nil")
                        }
                        self.updateAccessibilityDirectionalElements([])
                        return nil
                    }
                }
                currentClippingNode = clippingNode.supernode
            }
        }
        if voIsRunning {
            print("[VO-CHAT] customAccessibilityElements: enter rotated=\(self.rotated) fullMode=\(isFullMaterializationActive) trackDir=\(trackDirectionalFocus) contentOffsetY=\(Int(contentOffset.y)) visibleSize=\(Int(self.visibleSize.width))x\(Int(self.visibleSize.height)) windowY=[\(Int(visibleTop))..\(Int(visibleBottom))] navOrder=\(self.accessibilityNavigationOrder == .reversed ? "reversed" : "automatic")")
        }
        var voTotalNodesVisited = 0
        // Variant Y iterates only over materialised item nodes, so the
        // "filtered by rect" bucket from the old proxy-based path is
        // always zero; keep the variable for log-format compatibility
        // but make it `let` so the compiler doesn't flag it.
        let voNodesFilteredByRect = 0
        var voNodesWithoutData = 0
        var voItemFrameLog: [(li: Int, y: CGFloat, h: CGFloat)] = []

        if trackDirectionalFocus {
            // ── VARIANT Y: direct UIView accessibility leaves ────────
            //
            // The previous design built a `FocusTrackingAccessibility
            // Element` proxy per `filteredEntries` entry. It produced
            // two competing accessibility elements per visible bubble
            // (the proxy AND the promoted bubble view itself), causing
            // VoiceOver's spatial scan to ping-pong between them and
            // backtrack after 1-2 forward swipes.
            //
            // We now expose the bubble views themselves as VoiceOver
            // leaves — one bubble = one element. Visible bubbles use
            // their **real** screen frames (so single-finger tap on
            // a message works). Off-screen materialised bubbles get a
            // synthetic `accessibilityFrame` inside the visible clip
            // (staggered slot, 1pt tall) so iOS doesn't filter them
            // out as unreachable during spatial swipe traversal.
            //
            // When VoiceOver focuses an off-screen bubble (synthetic
            // frame inside clip, real frame outside), the handler in
            // `ListView.handleSystemAccessibilityFocusNotification`
            // detects the real-vs-clip mismatch and calls
            // `scrollVoiceOverFocusToItem(at:)` to bring the row
            // into the viewport. On the next refresh that bubble
            // moves into the `visible` bucket and gets its real
            // frame back.
            //
            // Tap UX is preserved: VoiceOver uses `accessibilityFrame`
            // for finger-on-screen hit-testing, and the visible
            // bubbles' accessibility frames cover their entire real
            // on-screen extents. Off-screen synthetic frames are
            // 1pt tall slots that the user is extremely unlikely to
            // brush with their finger (they sit at the very top or
            // bottom edge of the clip, outside where bubble bodies
            // are physically drawn).
            //
            // Trade-offs accepted:
            //  • No "next message" / "previous message" announcement
            //    on swipe — that hook is wired through
            //    `FocusTrackingAccessibilityElement.focused/focusLost`
            //    callbacks, which UIView leaves don't trigger. VO
            //    simply speaks the new bubble's label, which IS the
            //    announcement of the next message.
            //  • The accessibility array changes as messages
            //    materialise/dematerialise during scroll — this is
            //    the standard `UITableView` model and iOS handles
            //    it natively.
            //
            // Collect materialised item nodes once; we need the set
            // to bucket them into above-visible / visible / below-
            // visible groups in a second pass.
            let synthClip = self.accessibilityClippingFrameInScreenCoordinates()
                ?? UIAccessibility.convertToScreenCoordinates(
                    CGRect(
                        x: 0.0,
                        y: self.rotated ? self.insets.bottom : self.insets.top,
                        width: self.visibleSize.width,
                        height: max(0.0, self.visibleSize.height - self.insets.top - self.insets.bottom)
                    ),
                    in: self.view
                )

            struct CollectedItem {
                let localIndex: Int
                let itemNode: ListViewItemNode
                let realFrame: CGRect
                /// `realFrame` clipped to the visible window. For
                /// visible items this is what we hand to
                /// `accessibilityFrame` so VoiceOver's spatial scan
                /// stays bounded inside the viewport — a tall bubble
                /// whose body extends far below the screen no longer
                /// drags the cursor 1000+pt off-screen.
                let clippedFrame: CGRect
                let payload: (label: String, value: String?, hint: String?, identifier: String?, traits: UIAccessibilityTraits, customActions: [UIAccessibilityCustomAction]?)
                let isVisible: Bool
                let isAboveVisible: Bool
            }
            // A bubble counts as "visible" only if a substantial slice
            // of it is actually inside the clip. The previous bare
            // `realFrame.intersects(synthClip)` test admitted tall
            // media bubbles (1500pt+) that merely *grazed* the
            // viewport edge — they then received their full,
            // mostly-off-screen real frame as `accessibilityFrame`,
            // and VoiceOver's spatial scan happily jumped the cursor
            // onto them across the whole array (the chat=79 / chat=84
            // "jump to position 1" loop in the logs). 44pt ≈ one
            // tap-target's worth of on-screen content — enough to be
            // a genuine focus target, small enough not to reject a
            // short text bubble at the viewport edge.
            //
            // **However**, an absolute 44pt threshold excludes short
            // service cells (pinned-message indicator, unread divider,
            // date headers — typically 28..40pt tall) even when they
            // are *fully* on-screen, because their entire intersection
            // is < 44pt. The user observed VoiceOver "skipping past"
            // these placeholders. We therefore lower the bar for cells
            // whose natural height is below the 44pt floor: a cell is
            // visible if ≥ 90% of its own height is on-screen.
            //
            // The tall-bubble protection is preserved: for a 1500pt
            // bubble, `min(44, 1500*0.9)` is still 44, so the original
            // 44pt requirement applies.
            let kMinVisibleHeight: CGFloat = 44.0
            var collected: [CollectedItem] = []
            self.forEachItemNode { node in
                guard let itemNode = node as? ListViewItemNode, let localIndex = itemNode.index else { return }
                voTotalNodesVisited += 1
                activeLocalIndices.insert(localIndex)
                if voIsRunning {
                    voItemFrameLog.append((li: localIndex, y: itemNode.frame.minY, h: itemNode.frame.height))
                }

                guard let payload = self.composeBubbleAccessibilityPayload(for: itemNode, clippedTo: visibleScreenRect),
                      !payload.label.isEmpty else {
                    voNodesWithoutData += 1
                    return
                }

                let realFrame = UIAccessibility.convertToScreenCoordinates(itemNode.bounds, in: itemNode.view)
                let intersection = realFrame.isNull ? CGRect.null : realFrame.intersection(synthClip)
                // Per-item required-visible-height: 44pt for tall cells,
                // 90% of natural height for short cells (placeholders).
                let requiredVisibleHeight: CGFloat
                if realFrame.isNull {
                    requiredVisibleHeight = kMinVisibleHeight
                } else {
                    requiredVisibleHeight = min(kMinVisibleHeight, realFrame.height * 0.9)
                }
                let isVisible = !realFrame.isNull
                    && !intersection.isNull
                    && intersection.height >= requiredVisibleHeight
                    && intersection.width > 1.0
                // `clippedFrame` is the on-screen slice; falls back to
                // the raw real frame when there's no intersection
                // (so off-screen items still carry a sane value).
                let clippedFrame = intersection.isNull ? realFrame : intersection
                // Above-visible: bubble's bottom is above the clip top.
                // Used to decide which synthetic stagger band to use.
                let isAboveVisible = !realFrame.isNull && realFrame.maxY <= synthClip.minY

                if voIsRunning {
                    itemNode.view.accessibilityElementsHidden = false
                    itemNode.isAccessibilityElement = true
                    itemNode.accessibilityLabel = payload.label
                    itemNode.accessibilityValue = payload.value
                    itemNode.accessibilityHint = payload.hint
                    itemNode.accessibilityIdentifier = payload.identifier
                    itemNode.accessibilityTraits = payload.traits
                    itemNode.view.accessibilityCustomActions = payload.customActions
                    ChatHistoryListNodeImpl.suppressCompetingLeaves(in: itemNode, isRoot: true)
                    self.voPromotedItemNodes.add(itemNode)
                }

                collected.append(CollectedItem(
                    localIndex: localIndex,
                    itemNode: itemNode,
                    realFrame: realFrame,
                    clippedFrame: clippedFrame,
                    payload: payload,
                    isVisible: isVisible,
                    isAboveVisible: isAboveVisible
                ))
            }

            // ── Synthetic accessibilityFrame: BOUNDED packed stagger ─
            //
            // Visible bubble   → real screen frame.
            // Off-screen above → packed stagger immediately above the
            //                    visible bubble's top edge, **limited
            //                    to `kSynthNeighbours` closest items**.
            // Off-screen below → packed stagger immediately below,
            //                    same limit.
            // Far off-screen   → default (real off-screen) frame —
            //                    VoiceOver filters them out as
            //                    unreachable, they're effectively
            //                    invisible to swipe traversal until
            //                    they become adjacent.
            //
            // Bounding the synthetic stagger to a small N (3 each
            // side) is what guarantees swipe = exactly +1 step in
            // localIndex order, regardless of how cramped the
            // above/below band is. With unbounded stagger, when
            // the visible bubble sits near the clip edge (e.g. the
            // newest message at the bottom of viewport, with little
            // room below), 10+ synthetic slots get clamped to the
            // clip edge and collapse to the same y — VoiceOver's
            // spatial scan can't tell them apart, picks one
            // arbitrarily, and the cursor jumps by N items at once
            // (observed in user logs as li=58 → li=43 skip-15).
            //
            // With only 3 neighbour slots per side, the packed
            // sub-band is always ~1.5pt tall and fits even at the
            // very top/bottom of the clip. The far items are
            // unreachable via swipe in one transaction but become
            // reachable on the next scroll (when one of the
            // neighbour slots is focused, the list scrolls so
            // that item comes into view, and the next refresh
            // promotes the next-closest off-screen item into a
            // neighbour slot — the user advances one step per swipe
            // continuously).
            // Single synthetic neighbour per side: VoiceOver picks the
            // closest spatial neighbour, and with N=1 that's
            // unambiguously the array-adjacent off-screen bubble. With
            // N=3 (the previous setting) VoiceOver sometimes picked
            // the 2nd or 3rd slot, causing observable "jump 2-3
            // messages" on a single swipe at the array edge.
            let kSynthNeighbours = 1

            let visibleItems = collected.filter { $0.isVisible }
            // Compute the visible band extent from the **clipped**
            // frames, not the raw real frames. A tall bubble's real
            // frame can stretch hundreds of pt past the viewport; using
            // it here would push the synthetic neighbour stagger bands
            // off-screen. The clipped frame is the on-screen slice, so
            // the stagger bands hug the actual visible content.
            let visibleTopY: CGFloat
            let visibleBottomY: CGFloat
            if let firstClipped = visibleItems.first?.clippedFrame {
                visibleTopY = visibleItems.reduce(firstClipped.minY) { min($0, $1.clippedFrame.minY) }
                visibleBottomY = visibleItems.reduce(firstClipped.maxY) { max($0, $1.clippedFrame.maxY) }
            } else {
                let midY = synthClip.midY
                visibleTopY = midY
                visibleBottomY = midY
            }

            // All off-screen items, sorted by localIndex asc.
            let aboveAll = collected.filter { !$0.isVisible && $0.isAboveVisible }
                .sorted { $0.localIndex < $1.localIndex }
            let belowAll = collected.filter { !$0.isVisible && !$0.isAboveVisible }
                .sorted { $0.localIndex < $1.localIndex }
            // Neighbours: take the closest-to-visible items from each
            // side. In a **non-rotated** ListView (e.g. chat list) the
            // localIndex order matches the visual top-to-bottom order, so
            // `aboveAll` (sorted asc) ends with the items closest to the
            // visible top → take the *suffix*; `belowAll` starts with the
            // items closest to the visible bottom → take the *prefix*.
            //
            // In a **rotated** ListView (chat history) the layer is
            // 180°-flipped, so the localIndex order is *visually inverted*:
            // the highest localIndex sits at the top of the viewport, and
            // items visually above the viewport have **larger** localIndex
            // than the topmost visible bubble. `aboveAll` is therefore the
            // tail end of the localIndex range, and the item closest to
            // the visible top is the *smallest* localIndex in `aboveAll`
            // → take the *prefix*. Symmetrically for `belowAll`.
            //
            // Without this rotation-aware swap the bounded sliding window
            // picked the farthest off-screen items as "neighbours" in
            // rotated mode (observed: `firstSorted=0 lastSorted=87` for a
            // visible window around li=47..52). When VoiceOver then tried
            // to navigate from the visible edge to those far neighbours,
            // their synthetic frames were degenerate, focus fell off, and
            // UIKit's accessibility auto-scroll yanked the chat to the
            // far end of the buffer (contentOffsetY +1000pt jump).
            let aboveNeighbours: ArraySlice<CollectedItem>
            let belowNeighbours: ArraySlice<CollectedItem>
            if self.rotated {
                aboveNeighbours = aboveAll.prefix(kSynthNeighbours)
                belowNeighbours = belowAll.suffix(kSynthNeighbours)
            } else {
                aboveNeighbours = aboveAll.suffix(kSynthNeighbours)
                belowNeighbours = belowAll.prefix(kSynthNeighbours)
            }

            let synthHeight: CGFloat = 1.0
            let synthStep: CGFloat = 0.5
            let synthWidth = max(1.0, synthClip.width)
            let synthX = synthClip.minX

            // Above neighbours: closest to visible at the bottom of
            // their sub-band (just above `visibleTopY`); further
            // neighbours stack up by `synthStep`. Clamped to
            // `synthClip.minY`.
            let aboveNeighboursArr = Array(aboveNeighbours)
            for (i, item) in aboveNeighboursArr.enumerated() {
                let reversedIndex = aboveNeighboursArr.count - 1 - i
                let yDesired = visibleTopY - 1.0 - synthHeight - CGFloat(reversedIndex) * synthStep
                let y = max(synthClip.minY, yDesired)
                item.itemNode.view.accessibilityFrame = CGRect(
                    x: synthX, y: y, width: synthWidth, height: synthHeight
                )
            }
            for item in visibleItems {
                // Hand VoiceOver the **clipped** on-screen slice, not
                // the raw real frame. For a normal bubble fully inside
                // the viewport these are identical; for a tall bubble
                // that overflows the viewport, the clipped frame keeps
                // the cursor's spatial anchor inside the screen so the
                // next swipe finds the adjacent neighbour slot instead
                // of jumping across the array.
                item.itemNode.view.accessibilityFrame = item.clippedFrame
            }
            let belowNeighboursArr = Array(belowNeighbours)
            for (i, item) in belowNeighboursArr.enumerated() {
                let yDesired = visibleBottomY + 1.0 + CGFloat(i) * synthStep
                let y = min(synthClip.maxY - synthHeight, yDesired)
                item.itemNode.view.accessibilityFrame = CGRect(
                    x: synthX, y: y, width: synthWidth, height: synthHeight
                )
            }
            // Far off-screen items: **fully demote them and keep them
            // out of the array**.
            //
            // The earlier approach left far items promoted
            // (`isAccessibilityElement = true`) with their default
            // (real off-screen) `accessibilityFrame`, on the
            // assumption that VoiceOver would filter out elements
            // whose frame lies outside the screen. It does not — on a
            // transient focus loss VoiceOver re-scans the *whole*
            // accessibility tree and reliably re-anchors onto a far
            // item near array position 3 (the chat=65 / chat=76 /
            // chat=83 … "always jump to position=3" cascade in the
            // logs).
            //
            // The robust fix is a true bounded sliding window: only
            // the visible bubbles and the `kSynthNeighbours` items on
            // each side are exposed to VoiceOver at all. Far items are
            // demoted to non-leaves (`isAccessibilityElement = false`)
            // AND omitted from `directionalCandidates`, so VoiceOver
            // physically cannot land on them — there is nothing in the
            // tree to land on. As the user swipes onto a neighbour
            // slot, `scrollVoiceOverFocusToItem` scrolls it into view
            // and the next refresh promotes the next-closest far item
            // into a neighbour slot. The window slides one step at a
            // time; the array never contains a element the user
            // can't reach in a single swipe.
            let aboveNeighbourSet = Set(aboveNeighboursArr.map { $0.localIndex })
            let belowNeighbourSet = Set(belowNeighboursArr.map { $0.localIndex })
            let visibleSet = Set(visibleItems.map { $0.localIndex })
            for item in collected {
                let isExposed = visibleSet.contains(item.localIndex)
                    || aboveNeighbourSet.contains(item.localIndex)
                    || belowNeighbourSet.contains(item.localIndex)
                if isExposed {
                    directionalCandidates.append((
                        localIndex: item.localIndex,
                        order: 0,
                        element: item.itemNode.view as Any
                    ))
                } else {
                    // Far item: demote so VoiceOver's spatial / re-scan
                    // logic can't re-anchor onto it.
                    //
                    // `isAccessibilityElement = false` alone is NOT
                    // enough — VoiceOver's recovery / spatial scan
                    // walks the subview tree directly (the
                    // `accessibilityElements` override on the
                    // container is consulted for swipe-next, but
                    // recovery after focus-loss falls back to subview
                    // traversal). The result was an observable jump
                    // from a visible bubble (e.g. li=47) to li=0 at
                    // the far edge of the materialised buffer when
                    // VoiceOver lost focus.
                    //
                    // Setting `view.accessibilityElementsHidden = true`
                    // hides the *entire subtree* (root + every
                    // descendant) from accessibility scans of any
                    // kind, including the spatial recovery path. The
                    // bubble's UIView still exists for layout/render,
                    // it just doesn't surface as an accessibility
                    // target while it's outside the sliding window.
                    // When the bubble re-enters the window on the
                    // next refresh, pass 1 sets
                    // `accessibilityElementsHidden = false` so it is
                    // visible to VoiceOver again.
                    item.itemNode.isAccessibilityElement = false
                    if item.itemNode.isNodeLoaded {
                        item.itemNode.view.isAccessibilityElement = false
                        item.itemNode.view.accessibilityElementsHidden = true
                    }
                }
            }
        } else {
            self.forEachItemNode({ node in
                voTotalNodesVisited += 1
                let intersection = node.frame.intersection(visibleRect)
                guard !intersection.isNull, intersection.height > node.frame.height * 0.5 else {
                    return
                }
                if let element = self.makeMessageAccessibilityElement(for: node) {
                    accessibilityElements.append(element)
                } else {
                    addAccessibilityChildren(of: node, container: self, to: &accessibilityElements)
                }
            })
        }
        if !trackDirectionalFocus && accessibilityElements.isEmpty {
            self.forEachItemNode({ node in
                let intersection = node.frame.intersection(visibleRect)
                guard !intersection.isNull, intersection.height > 1.0 else {
                    return
                }
                if let element = self.makeMessageAccessibilityElement(for: node) {
                    accessibilityElements.append(element)
                } else {
                    addAccessibilityChildren(of: node, container: self, to: &accessibilityElements)
                }
            })
        }
        if trackDirectionalFocus {
            accessibilityElements = directionalCandidates.sorted(by: { lhs, rhs in
                if lhs.localIndex != rhs.localIndex {
                    return lhs.localIndex < rhs.localIndex
                } else {
                    return lhs.order < rhs.order
                }
            }).map(\.element)
            // Variant Y no longer uses the `FocusTrackingAccessibility
            // Element` pool — drain it completely on every call so
            // stale proxies don't linger. The pool stays available
            // for ChatListNode (separate instance).
            self.cleanupDirectionalElementPool(activeLocalIndices: [])
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
        self.updateAccessibilityDirectionalElements(accessibilityElements)
        self.lastAccessibilityElements = accessibilityElements

        if voIsRunning {
            let firstIndex = directionalCandidates.first?.localIndex
            let lastIndex = directionalCandidates.last?.localIndex
            let activeRange: String
            if let lo = activeLocalIndices.min(), let hi = activeLocalIndices.max() {
                activeRange = "\(lo)..\(hi)"
            } else {
                activeRange = "empty"
            }
            print("[VO-CHAT] customAccessibilityElements: exit visited=\(voTotalNodesVisited) filteredByRect=\(voNodesFilteredByRect) noData=\(voNodesWithoutData) directionalCandidates=\(directionalCandidates.count) activeIndices=\(activeLocalIndices.count) activeRange=\(activeRange) firstSorted=\(firstIndex.map(String.init) ?? "nil") lastSorted=\(lastIndex.map(String.init) ?? "nil") finalCount=\(accessibilityElements.count)")
            // Diagnostic: log content-Y of every materialised item so we can
            // see whether items spread across thousands of points or are
            // packed contiguously.
            if !voItemFrameLog.isEmpty {
                let sortedFrames = voItemFrameLog.sorted { $0.li < $1.li }
                let minY = sortedFrames.map { $0.y }.min() ?? 0
                let maxY = sortedFrames.map { $0.y + $0.h }.max() ?? 0
                let summary = sortedFrames.prefix(6).map { "li=\($0.li) y=\(Int($0.y)) h=\(Int($0.h))" }.joined(separator: " | ")
                let tail = sortedFrames.suffix(3).map { "li=\($0.li) y=\(Int($0.y)) h=\(Int($0.h))" }.joined(separator: " | ")
                print("[VO-CHAT] item-frames: span=\(Int(minY))..\(Int(maxY)) (Δ=\(Int(maxY - minY))) head=[\(summary)] tail=[\(tail)]")
            }
        }

        return accessibilityElements.isEmpty ? nil : accessibilityElements
    }

    private func handleVoiceOverFocusChanged(notification: Notification) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        guard let userInfo = notification.userInfo else { return }
        let focusedAny = userInfo[UIAccessibility.focusedElementUserInfoKey]
        let unfocusedAny = userInfo[UIAccessibility.unfocusedElementUserInfoKey]

        // The system fires this notification globally; we only want to log
        // when focus enters/moves inside *our* accessibility array.
        let elements = self.lastAccessibilityElements
        guard !elements.isEmpty else {
            return
        }

        func position(of focusedElement: AnyObject?) -> Int? {
            guard let focusedElement else { return nil }
            for (index, element) in elements.enumerated() {
                if let elementObject = element as AnyObject?, elementObject === focusedElement {
                    return index
                }
            }
            // VoiceOver routinely focuses the actual UIView of an
            // accessibility leaf (e.g. `AccessibilityAreaNode.view`)
            // instead of the proxy element we returned from
            // `customAccessibilityElements`.  Map UIView focus back to
            // the corresponding proxy by source view so the cursor
            // log reflects real progression instead of spamming
            // `focus-left-list` each swipe.
            if let focusedView = focusedElement as? UIView {
                for (index, element) in elements.enumerated() {
                    if let tracked = element as? FocusTrackingAccessibilityElement,
                       let sourceView = tracked.sourceView,
                       sourceView === focusedView {
                        return index
                    }
                }
            }
            return nil
        }

        let focusedObject = focusedAny as AnyObject?
        let unfocusedObject = unfocusedAny as AnyObject?
        let focusedPosition = position(of: focusedObject)
        let unfocusedPosition = position(of: unfocusedObject)

        // Track only meaningful transitions inside our list.  Focus that
        // leaves our list is logged once with `position=outside`, then we
        // stop spamming until focus returns.
        let totalLoaded = elements.count
        var totalChat: Int?
        var absolutePosition: Int?
        var focusedLocalIndex: Int?
        if let focusedPosition {
            // Resolve the source view for absolute-scroll info regardless
            // of whether the array stores `FocusTrackingAccessibilityElement`
            // wrappers (off-VoiceOver path) or the bubble views themselves
            // (full-materialisation path that landed identity-stable
            // leaves directly into the array).
            let element = elements[focusedPosition]
            let sourceView: UIView?
            if let tracked = element as? FocusTrackingAccessibilityElement {
                sourceView = tracked.sourceView
            } else if let view = element as? UIView {
                sourceView = view
            } else {
                sourceView = nil
            }
            if let sourceView, let info = self.computeAbsoluteScrollInfo(forFocusedSourceView: sourceView) {
                absolutePosition = info.position
                totalChat = info.total
            }
            if let sourceView {
                focusedLocalIndex = self.voLocalIndex(forFocusedSourceView: sourceView)
            }
        }

        if let focusedPosition {
            let identity = ObjectIdentifier(focusedObject!)
            if self.lastFocusedElementIdentity == identity {
                return
            }

            // ── B) Catch fly-away.
            //
            // Symptom (see logs that triggered this code):
            //   • Cursor at li=47 (position=7/8, top-edge of an 8-item
            //     reversed-nav window).
            //   • User swipes.  VoiceOver can't navigate to the synthetic
            //     above-neighbour (degenerate frame at the clip edge),
            //     fires `focus-left-list` → re-anchors on `array[0]` =
            //     li=53 = chat=133 (six items in the opposite direction).
            //
            // Heuristic: a fresh focus that lands on a localIndex far away
            // from the last known one, within a short window after focus
            // left the list, is a recovery — redirect VoiceOver back to
            // the previously focused bubble.  The user's swipe is then
            // re-issued from the right place instead of the cursor
            // disappearing to the far end of the buffer.
            //
            // The redirect itself triggers another focus event for the
            // restored bubble; the same-localIndex check on the next entry
            // (diff == 0) keeps it from looping.  `voFocusLostTimestamp`
            // is cleared as a belt-and-braces guard so a single
            // `focus-left-list` can only redirect once.
            if let focusedLocalIndex,
               let lastLocalIndex = self.voLastFocusedItemLocalIndex,
               self.voFocusLostTimestamp > 0,
               CACurrentMediaTime() - self.voFocusLostTimestamp < 0.5,
               abs(focusedLocalIndex - lastLocalIndex) > 2 {
                // **Experiment:** suppress the `.layoutChanged` post we used
                // to do here. Posting it with the previously-focused bubble
                // as argument turned out to be coincident with a large jump
                // in `contentOffsetY` (~+1000pt) and a wholesale re-layout
                // of materialised items (li=0 changed height 289→326, span
                // Δ 7922→9784). Hypothesis: iOS treats the post as a
                // structural-layout signal and triggers a layout pass that
                // shifts the scroll anchor. Skip the post for this run and
                // see whether the offset jump persists; if it does, the
                // cause is elsewhere (the redirect is innocent), if it
                // disappears we've found it. Either way we still consume
                // the bogus focus event (return) so the cursor logger
                // doesn't sing about the fly-away.
                _ = lastLocalIndex
                print("[VO-CHAT] fly-away-suppress (no-redirect) from-li=\(focusedLocalIndex) -> last-li=\(lastLocalIndex)")
                self.voFocusLostTimestamp = 0
                self.lastFocusedElementIdentity = nil
                return
            }

            self.lastFocusedElementIdentity = identity

            let element = elements[focusedPosition]
            let rawLabel = (element as? UIAccessibilityElement)?.accessibilityLabel
                ?? (element as? UIView)?.accessibilityLabel
                ?? ""
            let labelSnippet: String = {
                let trimmed = rawLabel.replacingOccurrences(of: "\n", with: " ")
                if trimmed.isEmpty {
                    return "<no-label>"
                }
                return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
            }()

            let humanPosition = focusedPosition + 1
            let absolute = absolutePosition.map(String.init) ?? "?"
            let total = totalChat.map(String.init) ?? "?"
            let prevPosition = unfocusedPosition.map { $0 + 1 }
            print("[VO-CHAT] cursor: position=\(humanPosition)/\(totalLoaded) (chat=\(absolute)/\(total)) prev=\(prevPosition.map(String.init) ?? "outside") localOrderIndex=\(focusedPosition) label='\(labelSnippet)'")

            // Edge-extend scroll. When the user's focus lands on the
            // edge of the visible-localIndex range (or beyond, on a
            // synthetic-neighbour slot whose real frame is off-screen),
            // preemptively scroll the list so the next adjacent bubble
            // becomes a real visible item. Without this, the user
            // navigates to the synthetic-neighbour slot, has no further
            // element to swipe to, focus is lost, and VoiceOver re-anchors
            // on whatever the first usable element in `accessibilityElements`
            // is — visible as a "fly-away" jump 6-10 positions back.
            //
            // The cascade that bit an earlier iteration of this code
            // (preemptive scroll → `_ASDisplayView` fallback → ListView's
            // scroll-to-uiview for li=0 → +1000pt jump) is now blocked
            // by three guards that run higher in the stack:
            //   1. Rotation-aware prefix/suffix in
            //      `customAccessibilityElements` so the bounded window
            //      contains the *closest* neighbours, not the farthest.
            //   2. `accessibilityElementsHidden`-aware skip in
            //      `ListView.handleSystemAccessibilityFocusNotification`.
            //   3. `accessibilityShouldAllowScrollToItem(at:)` veto for
            //      targets far from the last known live focus.
            // With those in place, `scrollVoiceOverFocusToItem` here can
            // only scroll to an adjacent target near the live focus.
            //
            // Triggering criterion: focused localIndex is at-or-beyond
            // the visible edge in the direction we want to extend. The
            // `<=` / `>=` covers both visible-edge bubbles (top/bottom
            // of `visibleRange`) and synthetic-neighbour focus
            // (`focusedLocalIndex` outside the range entirely).
            //
            // Debounce 0.2s keeps repeated focus events at the same edge
            // from queueing multiple scroll transactions on top of one
            // another.
            if let focusedLocalIndex,
               let visibleRange = self.voVisibleLocalIndexRange(),
               CACurrentMediaTime() - self.voLastEdgeScrollTimestamp > 0.2 {
                var extendTarget: Int?
                if focusedLocalIndex <= visibleRange.top, focusedLocalIndex > 0 {
                    extendTarget = focusedLocalIndex - 1
                } else if focusedLocalIndex >= visibleRange.bottom {
                    extendTarget = focusedLocalIndex + 1
                }
                if let target = extendTarget {
                    self.voLastEdgeScrollTimestamp = CACurrentMediaTime()
                    print("[VO-CHAT] edge-extend-scroll focusedLi=\(focusedLocalIndex) visible=\(visibleRange.top)..\(visibleRange.bottom) -> li=\(target)")
                    self.voForceScrollToItem(at: target)
                }
            }
            self.voLastFocusedItemLocalIndex = focusedLocalIndex ?? self.voLastFocusedItemLocalIndex
        } else if let unfocusedPosition, self.lastFocusedElementIdentity != nil {
            self.lastFocusedElementIdentity = nil
            // Mark when focus left the list so the B-path above can
            // distinguish a recovery refocus from a deliberate user
            // re-engagement. Keep `voLastFocusedItemLocalIndex` intact —
            // that's the anchor we redirect back to.
            self.voFocusLostTimestamp = CACurrentMediaTime()
            let focusedKind: String
            let focusedLabel: String
            if let focusedAny {
                focusedKind = String(describing: type(of: focusedAny))
                let label = (focusedAny as? UIAccessibilityElement)?.accessibilityLabel
                    ?? (focusedAny as? UIView)?.accessibilityLabel
                    ?? ""
                let trimmed = label.replacingOccurrences(of: "\n", with: " ")
                focusedLabel = trimmed.isEmpty ? "<no-label>" : (trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed)
            } else {
                focusedKind = "nil"
                focusedLabel = "<nil>"
            }
            let focusedFrame: String
            if let element = focusedAny as? UIAccessibilityElement {
                let f = element.accessibilityFrame
                focusedFrame = "[\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
            } else if let view = focusedAny as? UIView {
                let f = UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
                focusedFrame = "[\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
            } else {
                focusedFrame = "<no-frame>"
            }
            print("[VO-CHAT] cursor: focus-left-list from=\(unfocusedPosition + 1)/\(totalLoaded) -> kind=\(focusedKind) frame=\(focusedFrame) label='\(focusedLabel)'")
        }
    }

    /// Custom rotor backend.  Resolves the next message target on each
    /// `.next` / `.previous` step the user takes inside the "Сообщения"
    /// rotor.
    ///
    /// Mapping conventions:
    ///   • `localIndex 0` is the *oldest* message in the loaded buffer.
    ///   • `localIndex entryCount-1` is the *newest*.
    ///   • Rotor `.next` advances toward newer messages; `.previous`
    ///     toward older.
    ///
    /// Why no spatial math: standard VoiceOver swipe filters
    /// `accessibilityElements` whose frame falls outside the focus
    /// engine's reachable region, which drops chat history's far
    /// off-screen bubbles before traversal.  With a rotor, iOS hands
    /// us the navigation step explicitly, we scroll the target into
    /// view via `transaction(scrollToItem:)` (synchronous, materialises
    /// the item), and return its `UIView` as the focus target — no
    /// reachable-region check applies.
    private func rotorTarget(direction: UIAccessibilityCustomRotor.Direction, currentItem: UIAccessibilityCustomRotorItemResult) -> UIAccessibilityCustomRotorItemResult? {
        let entryCount: Int
        if let entries = (self.opaqueTransactionState as? ChatHistoryTransactionOpaqueState)?.historyView.filteredEntries {
            entryCount = entries.count
        } else {
            entryCount = 0
        }
        guard entryCount > 0 else { return nil }

        // Resolve the current `localIndex` from whatever element iOS
        // reports as currently focused.  Three flavours:
        //  1. A `FocusTrackingAccessibilityElement` proxy carrying our
        //     `pinnedLocalIndex` (set in `reuseOrCreateDirectionalElement`).
        //  2. A `UIView` that is `itemNode.view` for some bubble — walk
        //     the view tree to recover the enclosing item node.
        //  3. Anything else (navbar, input bar, …) — start from the
        //     edge of the loaded buffer.
        var currentLocalIndex: Int? = nil
        if let trackingElement = currentItem.targetElement as? FocusTrackingAccessibilityElement,
           let pinned = trackingElement.pinnedLocalIndex {
            currentLocalIndex = pinned
        } else if let focusedView = currentItem.targetElement as? UIView {
            self.forEachItemNode { node in
                guard currentLocalIndex == nil,
                      let itemNode = node as? ListViewItemNode,
                      let index = itemNode.index else { return }
                if itemNode.view === focusedView || focusedView.isDescendant(of: itemNode.view) {
                    currentLocalIndex = index
                }
            }
        }

        let targetLocalIndex: Int
        if let currentLocalIndex {
            targetLocalIndex = direction == .next ? currentLocalIndex + 1 : currentLocalIndex - 1
        } else {
            // No anchor in the chat — default to the newest message for
            // `.next` and the oldest for `.previous`, matching how
            // `Mail.app` opens its message rotor.
            targetLocalIndex = direction == .next ? entryCount - 1 : 0
        }
        guard targetLocalIndex >= 0, targetLocalIndex < entryCount else {
            print("[VO-CHAT] rotor: out-of-range direction=\(direction == .next ? "next" : "previous") current=\(currentLocalIndex.map(String.init) ?? "nil") target=\(targetLocalIndex) entryCount=\(entryCount)")
            return nil
        }

        // Bring the target bubble into the viewport.  This goes through
        // ListView's normal scroll machinery, materialising the item
        // node if it's currently outside the render buffer.
        self.scrollVoiceOverFocusToItem(at: targetLocalIndex)

        // After the synchronous transaction, the item node should be
        // present in `self.itemNodes`.  Find it and return its view.
        var targetView: UIView? = nil
        self.forEachItemNode { node in
            guard targetView == nil,
                  let itemNode = node as? ListViewItemNode,
                  itemNode.index == targetLocalIndex else { return }
            targetView = itemNode.view
        }
        guard let target = targetView else {
            print("[VO-CHAT] rotor: target-not-materialised target=\(targetLocalIndex)")
            return nil
        }
        print("[VO-CHAT] rotor: \(direction == .next ? "next" : "previous") current=\(currentLocalIndex.map(String.init) ?? "nil") target=\(targetLocalIndex)")
        return UIAccessibilityCustomRotorItemResult(targetElement: target, targetRange: nil)
    }

    private func computeAbsoluteScrollInfo(forFocusedSourceView sourceView: UIView) -> (position: Int, total: Int)? {
        guard let provider = self.accessibilityAbsoluteScrollInfo else { return nil }
        var matchedLocalIndex: Int?
        self.forEachItemNode({ node in
            guard matchedLocalIndex == nil else { return }
            guard let itemNode = node as? ListViewItemNode, let itemIndex = itemNode.index else { return }
            // The proxy element's `sourceView` is set to the bubble's
            // `AccessibilityAreaNode.view`, which is a *descendant* of
            // `itemNode.view`, not the item node itself.  Plain identity
            // comparison would miss every match.  Walk the view tree
            // upward to recover the enclosing item node.
            if itemNode.view === sourceView || sourceView.isDescendant(of: itemNode.view) {
                matchedLocalIndex = itemIndex
            }
        })
        guard let localIndex = matchedLocalIndex else { return nil }
        guard let info = provider([localIndex]) else { return nil }
        return (position: info.first, total: info.total)
    }

    /// Force-scroll the list to bring an item into view, bypassing the
    /// geometric `alreadyOnScreen` short-circuit in the base
    /// `scrollVoiceOverFocusToItem`. The base implementation tests
    /// `itemNode.frame.intersection(...)` in ListView's local space — that
    /// works for an unrotated chat list, but in this rotated history list
    /// the local-space coordinates don't line up with screen visibility,
    /// so a fully off-screen bubble can look "already on screen" and the
    /// scroll silently becomes a no-op.
    ///
    /// Used by the edge-extend path in `handleVoiceOverFocusChanged` to
    /// pull the next adjacent bubble into the viewport when the user's
    /// focus reaches the visible edge of the bounded sliding window.
    /// `accessibilityShouldAllowScrollToItem(at:)` still gates the call so
    /// a stray request to a far-away `localIndex` doesn't drag the list
    /// to the wrong end of the buffer.
    private func voForceScrollToItem(at localIndex: Int) {
        guard self.accessibilityShouldAllowScrollToItem(at: localIndex) else {
            print("[VO-CHAT] force-scroll-veto li=\(localIndex)")
            return
        }
        print("[VO-CHAT] force-scroll-transaction li=\(localIndex)")
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
    }

    /// Veto bogus scroll-to-uiview triggered from
    /// `ListView.handleSystemAccessibilityFocusNotification`.
    ///
    /// After VoiceOver loses anchor at the edge of the bounded window, it
    /// can briefly re-focus on a parent `_ASDisplayView` that happens to
    /// be one of our materialised item nodes — but a far one (e.g. li=0
    /// while the user is around li=47). `ListView`'s off-screen-uiview
    /// branch would then react with a real `scrollVoiceOverFocusToItem`,
    /// dragging the chat to the far end of the buffer. We let ListView
    /// know that any such target whose `localIndex` is far from the
    /// user's last live-focused bubble is not a legitimate VoiceOver
    /// target.
    override public func accessibilityShouldAllowScrollToItem(at localIndex: Int) -> Bool {
        guard let lastKnown = self.voLastFocusedItemLocalIndex else {
            return true
        }
        let maxJump = 5
        if abs(localIndex - lastKnown) > maxJump {
            return false
        }
        return true
    }

    private func voLocalIndex(forFocusedSourceView sourceView: UIView) -> Int? {
        var matched: Int?
        self.forEachItemNode({ node in
            guard matched == nil else { return }
            guard let itemNode = node as? ListViewItemNode, let itemIndex = itemNode.index else { return }
            if itemNode.view === sourceView || sourceView.isDescendant(of: itemNode.view) {
                matched = itemIndex
            }
        })
        return matched
    }

    private func voBubbleView(forLocalIndex localIndex: Int) -> UIView? {
        var found: UIView?
        self.forEachItemNode({ node in
            guard found == nil else { return }
            guard let itemNode = node as? ListViewItemNode, itemNode.index == localIndex else { return }
            if itemNode.isNodeLoaded {
                found = itemNode.view
            }
        })
        return found
    }

    /// Visible-edge localIndex range in this list.  Used by the edge-scroll
    /// trigger in `handleVoiceOverFocusChanged` to detect whether the user
    /// has just landed on the topmost or bottommost visible bubble.
    ///
    /// Mirrors the visibility test used by `customAccessibilityElements`
    /// (44pt minimum on-screen height) so the two stay in sync — an item
    /// counts as "edge" only if `customAccessibilityElements` would have
    /// placed it as a `visibleItems` entry (not a synthetic neighbour).
    private func voVisibleLocalIndexRange() -> (top: Int, bottom: Int)? {
        let clipFrame: CGRect
        if let frame = self.accessibilityClippingFrameInScreenCoordinates() {
            clipFrame = frame
        } else {
            clipFrame = UIAccessibility.convertToScreenCoordinates(
                CGRect(
                    x: 0.0,
                    y: self.rotated ? self.insets.bottom : self.insets.top,
                    width: self.visibleSize.width,
                    height: max(0.0, self.visibleSize.height - self.insets.top - self.insets.bottom)
                ),
                in: self.view
            )
        }
        let kMinVisibleHeight: CGFloat = 44.0
        var minIdx: Int?
        var maxIdx: Int?
        self.forEachItemNode({ node in
            guard let itemNode = node as? ListViewItemNode, let idx = itemNode.index else { return }
            guard itemNode.isNodeLoaded else { return }
            let realFrame = UIAccessibility.convertToScreenCoordinates(itemNode.bounds, in: itemNode.view)
            guard !realFrame.isNull else { return }
            let intersection = realFrame.intersection(clipFrame)
            // Mirror `customAccessibilityElements`: 44pt for tall cells,
            // 90% of natural height for short service cells (pinned /
            // unread / date headers) so they aren't silently skipped
            // from the visibility-range calculation either.
            let requiredVisibleHeight = min(kMinVisibleHeight, realFrame.height * 0.9)
            guard !intersection.isNull,
                  intersection.height >= requiredVisibleHeight,
                  intersection.width > 1.0 else { return }
            if let lo = minIdx { minIdx = min(lo, idx) } else { minIdx = idx }
            if let hi = maxIdx { maxIdx = max(hi, idx) } else { maxIdx = idx }
        })
        if let lo = minIdx, let hi = maxIdx {
            return (top: lo, bottom: hi)
        }
        return nil
    }
    
    public func updateTag(tag: HistoryViewInputTag?) {
        if self.tag == tag {
            return
        }
        self.tag = tag
        
        self.beginChatHistoryTransitions(resetScrolling: true, switchedToAnotherSource: false)
    }
    
    public func updateChatLocation(chatLocation: ChatLocation) {
        if self.chatLocation == chatLocation {
            return
        }
        self.chatLocation = chatLocation
        
        self.interactiveReadActionDisposable?.dispose()
        self.interactiveReadActionDisposable = nil
        
        self.beginChatHistoryTransitions(resetScrolling: true, switchedToAnotherSource: false)
        self.beginReadHistoryManagement()
    }
    
    private func beginAdMessageManagement(adMessages: Signal<(interPostInterval: Int32?, messages: [Message], startDelay: Int32?, betweenDelay: Int32?), NoError>) {
        self.adMessagesDisposable = (adMessages
        |> deliverOnMainQueue).startStrict(next: { [weak self] interPostInterval, messages, _, _ in
            guard let self else {
                return
            }
            
            if let interPostInterval = interPostInterval {
                self.pendingDynamicAdMessages = messages
                self.pendingDynamicAdMessageInterval = Int(interPostInterval)
                
                if self.remainingDynamicAdMessageInterval == nil {
                    self.remainingDynamicAdMessageInterval = Int(interPostInterval)
                }
                if self.remainingDynamicAdMessageDistance == nil {
                    self.remainingDynamicAdMessageDistance = self.bounds.height
                }
                
                self.allAdMessages = (messages.first, [], 0)
            } else {
                var adPeerName: String?
                if let adAttribute = messages.first?.adAttribute, let parsedUrl = parseAdUrl(sharedContext: self.context.sharedContext, context: self.context, url: adAttribute.url), case let .peer(reference, _) = parsedUrl, case let .name(peerName) = reference {
                    adPeerName = peerName
                }
                
                if self.preloadAdPeerName != adPeerName {
                    self.preloadAdPeerName = adPeerName
                    if let adPeerName {
                        let context = self.context
                        let combinedDisposable = DisposableSet()
                        self.preloadAdPeerDisposable.set(combinedDisposable)
                        combinedDisposable.add(context.engine.peers.resolvePeerByName(name: adPeerName, referrer: nil).startStrict(next: { result in
                            if case let .result(maybePeer) = result, let peer = maybePeer {
                                combinedDisposable.add(context.account.viewTracker.polledChannel(peerId: peer.id).startStrict())
                                combinedDisposable.add(context.account.addAdditionalPreloadHistoryPeerId(peerId: peer.id))
                            }
                        }))
                    } else {
                        self.preloadAdPeerDisposable.set(nil)
                    }
                }
                
                self.allAdMessages = (messages.first, [], 0)
            }
        }).strict()
    }
    
    private let fixedCombinedReadStates = Atomic<MessageHistoryViewReadState?>(value: nil)
    private let currentViewVersion = Atomic<Int?>(value: nil)
    private let previousView = Atomic<(ChatHistoryView, Int, Set<MessageId>?, Int)?>(value: nil)
    private let previousHistoryAppearsCleared = Atomic<Bool?>(value: nil)
    
    private func beginChatHistoryTransitions(resetScrolling: Bool, switchedToAnotherSource: Bool) {
        self.historyDisposable.set(nil)
        self._isReady.set(false)
        
        let context = self.context
        let chatLocation = self.chatLocation
        let subject = self.subject
        let source = self.source
        let tag = self.tag
        let chatLocationContextHolder = self.chatLocationContextHolder
        let controllerInteraction = self.controllerInteraction
        let selectedMessages = self.selectedMessages
        let messageTransitionNode = self.messageTransitionNode
        let mode = self.mode
        let rotated = self.rotated
        
        var resetScrollingMessageId: (index: MessageIndex, offset: CGFloat)?
        
        let useRootInterfaceStateForThread: Bool
        if case let .replyThread(message) = self.chatLocation, message.peerId == self.context.account.peerId, message.threadId == self.context.account.peerId.toInt64() {
            useRootInterfaceStateForThread = true
        } else {
            useRootInterfaceStateForThread = false
        }
        
        var resetScrolling = resetScrolling
        if resetScrolling {
            if let frozenMessageForScrollingReset = self.frozenMessageForScrollingReset {
                self.forEachVisibleMessageItemNode { itemNode in
                    if resetScrollingMessageId != nil {
                        return
                    }
                    if let item = itemNode.item, item.message.id == frozenMessageForScrollingReset {
                        let distanceToNode = self.insets.top - itemNode.frame.minY
                        resetScrollingMessageId = (item.message.index, -distanceToNode)
                    }
                }
            }
            
            self.forEachVisibleMessageItemNode { itemNode in
                if resetScrollingMessageId != nil {
                    return
                }
                if let item = itemNode.item {
                    let distanceToNode = self.insets.top - itemNode.frame.minY
                    resetScrollingMessageId = (item.message.index, -distanceToNode)
                }
            }
            
            if let resetScrollingMessageId {
                self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Scroll(subject: MessageHistoryScrollToSubject(index: .message(resetScrollingMessageId.index), quote: nil), anchorIndex: .message(resetScrollingMessageId.index), sourceIndex: .message(resetScrollingMessageId.index), scrollPosition: .top(resetScrollingMessageId.offset), animated: false, highlight: false, setupReply: false), id: (self.chatHistoryLocationValue?.id).flatMap({ $0 + 1 }) ?? 0)
            } else {
                self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Initial(count: historyMessageCount), id: (self.chatHistoryLocationValue?.id).flatMap({ $0 + 1 }) ?? 0)
            }
        }
        self.frozenMessageForScrollingReset = nil
        
        var appendMessagesFromTheSameGroup = false
        if case .pinnedMessages = subject {
            appendMessagesFromTheSameGroup = true
        }
        
        let fixedCombinedReadStates = self.fixedCombinedReadStates
        
        var isScheduledMessages = false
        if let subject = self.subject, case .scheduledMessages = subject {
            isScheduledMessages = true
        }
        var isAuxiliaryChat = isScheduledMessages
        if case .replyThread = self.chatLocation {
            isAuxiliaryChat = true
        }
        
        var additionalData: [AdditionalMessageHistoryViewData] = []
        if case let .peer(peerId) = self.chatLocation {
            additionalData.append(.cachedPeerData(peerId))
            additionalData.append(.cachedPeerDataMessages(peerId))
            additionalData.append(.peerNotificationSettings(peerId))
            if peerId.namespace == Namespaces.Peer.CloudChannel {
                additionalData.append(.cacheEntry(cachedChannelAdminRanksEntryId(peerId: peerId)))
            }
            additionalData.append(.peer(peerId))
            if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.SecretChat {
                additionalData.append(.peerIsContact(peerId))
            }
        }
        if !isAuxiliaryChat {
            additionalData.append(.totalUnreadState)
        }
        if case let .replyThread(replyThreadMessage) = self.chatLocation {
            additionalData.append(.cachedPeerData(replyThreadMessage.peerId))
            additionalData.append(.peerNotificationSettings(replyThreadMessage.peerId))
            if replyThreadMessage.peerId.namespace == Namespaces.Peer.CloudChannel {
                additionalData.append(.cacheEntry(cachedChannelAdminRanksEntryId(peerId: replyThreadMessage.peerId)))
                additionalData.append(.peer(replyThreadMessage.peerId))
            }
            
            additionalData.append(.message(replyThreadMessage.effectiveTopId))
        }

        let currentViewVersion = self.currentViewVersion
        
        var historyViewUpdate: Signal<(ChatHistoryViewUpdate, Int, ChatHistoryLocationInput?, ClosedRange<Int32>?, Set<MessageId>), NoError>
        var isFirstTime = true
        var isSavedMusic = false
        var canReorder = false
        if case let .custom(messages, at, quote, isSavedMusicValue, canReorderValue, _) = self.source {
            isSavedMusic = isSavedMusicValue
            canReorder = canReorderValue
            historyViewUpdate = messages
            |> map { messages, _, hasMore in
                let version = currentViewVersion.modify({ value in
                    if let value = value {
                        return value + 1
                    } else {
                        return 0
                    }
                })!
                
                let scrollPosition: ChatHistoryViewScrollPosition?
                if isFirstTime, let messageIndex = messages.first(where: { $0.id == at })?.index {
                    scrollPosition = .index(subject: MessageHistoryScrollToSubject(index: .message(messageIndex), quote: quote.flatMap { quote in MessageHistoryScrollToSubject.Quote(string: quote.text, offset: quote.offset) }), position: .center(.bottom), directionHint: .Down, animated: false, highlight: false, displayLink: false, setupReply: false)
                    isFirstTime = false
                } else {
                    scrollPosition = nil
                }
                
                return (ChatHistoryViewUpdate.HistoryView(view: MessageHistoryView(tag: nil, namespaces: .all, entries: messages.reversed().map { MessageHistoryEntry(message: $0, isRead: false, location: nil, monthLocation: nil, attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false)) }, holeEarlier: hasMore, holeLater: false, isLoading: false), type: .Generic(type: version > 0 ? ViewUpdateType.Generic : ViewUpdateType.Initial), scrollPosition: scrollPosition, flashIndicators: false, originalScrollPosition: nil, initialData: ChatHistoryCombinedInitialData(initialData: nil, buttonKeyboardMessage: nil, cachedData: nil, cachedDataMessages: nil, readStateData: nil), id: 0), version, nil, nil, Set())
            }
        } else if case let .customView(historyView) = self.source {
            historyViewUpdate = combineLatest(queue: .mainQueue(),
                self.chatHistoryLocationPromise.get(),
                self.ignoreMessagesInTimestampRangePromise.get(),
                self.ignoreMessageIdsPromise.get()
            )
            |> distinctUntilChanged(isEqual: { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return false
                }
                if lhs.1 != rhs.1 {
                    return false
                }
                if lhs.2 != rhs.2 {
                    return false
                }
                return true
            })
            |> mapToSignal { location, _, _ -> Signal<((MessageHistoryView, ViewUpdateType), ChatHistoryLocationInput?), NoError> in
                return historyView
                |> map { historyView in
                    return (historyView, location)
                }
            }
            |> map { viewAndUpdate, location in
                let (view, update) = viewAndUpdate
                
                let version = currentViewVersion.modify({ value in
                    if let value = value {
                        return value + 1
                    } else {
                        return 0
                    }
                })!
                
                var scrollPositionValue: ChatHistoryViewScrollPosition?
                if let location {
                    switch location.content {
                    case let .Scroll(subject, _, _, scrollPosition, animated, highlight, setupReply):
                        scrollPositionValue = .index(subject: subject, position: scrollPosition, directionHint: .Up, animated: animated, highlight: highlight, displayLink: false, setupReply: setupReply)
                    default:
                        break
                    }
                }
                
                return (
                    ChatHistoryViewUpdate.HistoryView(
                        view: view,
                        type: .Generic(type: update),
                        scrollPosition: scrollPositionValue,
                        flashIndicators: false,
                        originalScrollPosition: nil,
                        initialData: ChatHistoryCombinedInitialData(
                            initialData: nil,
                            buttonKeyboardMessage: nil,
                            cachedData: nil,
                            cachedDataMessages: nil,
                            readStateData: nil
                        ),
                        id: location?.id ?? 0
                    ),
                    version,
                    location,
                    nil,
                    Set()
                )
            }
        } else {
            historyViewUpdate = combineLatest(queue: .mainQueue(),
                self.chatHistoryLocationPromise.get(),
                self.ignoreMessagesInTimestampRangePromise.get(),
                self.ignoreMessageIdsPromise.get()
            )
            |> distinctUntilChanged(isEqual: { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return false
                }
                if lhs.1 != rhs.1 {
                    return false
                }
                if lhs.2 != rhs.2 {
                    return false
                }
                return true
            })
            |> mapToSignal { location, ignoreMessagesInTimestampRange, ignoreMessageIds in
                return chatHistoryViewForLocation(location, ignoreMessagesInTimestampRange: ignoreMessagesInTimestampRange, ignoreMessageIds: ignoreMessageIds, context: context, chatLocation: chatLocation, chatLocationContextHolder: chatLocationContextHolder, scheduled: isScheduledMessages, fixedCombinedReadStates: fixedCombinedReadStates.with { $0 }, tag: tag, appendMessagesFromTheSameGroup: appendMessagesFromTheSameGroup, additionalData: additionalData, orderStatistics: [.combinedLocation], useRootInterfaceStateForThread: useRootInterfaceStateForThread)
                |> beforeNext { viewUpdate in
                    switch viewUpdate {
                        case let .HistoryView(view, _, _, _, _, _, _):
                            let _ = fixedCombinedReadStates.swap(view.fixedReadStates)
                        default:
                            break
                    }
                }
                |> map { view -> (ChatHistoryViewUpdate, Int, ChatHistoryLocationInput?, ClosedRange<Int32>?, Set<MessageId>) in
                    let version = currentViewVersion.modify({ value in
                        if let value = value {
                            return value + 1
                        } else {
                            return 0
                        }
                    })!
                    return (view, version, location, ignoreMessagesInTimestampRange, ignoreMessageIds)
                }
            }
        }
        
        let previousView = self.previousView
        let automaticDownloadNetworkType = context.account.networkType
        |> map { type -> MediaAutoDownloadNetworkType in
            switch type {
                case .none, .wifi:
                    return .wifi
                case .cellular:
                    return .cellular
            }
        }
        |> distinctUntilChanged
        
        let chatHistoryEntriesForViewState = Atomic<ChatHistoryEntriesForViewState>(value: ChatHistoryEntriesForViewState())
        
        let animatedEmojiStickers: Signal<[String: [StickerPackItem]], NoError> = context.animatedEmojiStickers
        let additionalAnimatedEmojiStickers = context.additionalAnimatedEmojiStickers
        
        let previousHistoryAppearsCleared = self.previousHistoryAppearsCleared
                
        let updatingMedia = context.account.pendingUpdateMessageManager.updatingMessageMedia
        |> map { value -> [MessageId: ChatUpdatingMessageMedia] in
            var result = value
            for id in value.keys {
                if id.peerId != chatLocation.peerId {
                    result.removeValue(forKey: id)
                }
            }
            return result
        }
        |> distinctUntilChanged
        
        let customChannelDiscussionReadState: Signal<MessageId?, NoError>
        if case let .peer(peerId) = chatLocation, peerId.namespace == Namespaces.Peer.CloudChannel {
            customChannelDiscussionReadState = context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.LinkedDiscussionPeerId(id: peerId),
                TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)
            )
            |> mapToSignal { linkedDiscussionPeerId, peer -> Signal<PeerId?, NoError> in
                guard case let .channel(peer) = peer, case .broadcast = peer.info else {
                    return .single(nil)
                }
                guard case let .known(value) = linkedDiscussionPeerId else {
                    return .single(nil)
                }
                return .single(value)
            }
            |> distinctUntilChanged
            |> mapToSignal { discussionPeerId -> Signal<MessageId?, NoError> in
                guard let discussionPeerId = discussionPeerId else {
                    return .single(nil)
                }
                
                return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.PeerReadCounters(id: discussionPeerId))
                |> map { readCounters -> MessageId? in
                    guard let state = readCounters._asReadCounters() else {
                        return nil
                    }
                    for (namespace, namespaceState) in state.states {
                        if namespace == Namespaces.Message.Cloud {
                            switch namespaceState {
                            case let .idBased(maxIncomingReadId, _, _, _, _):
                                return MessageId(peerId: discussionPeerId, namespace: Namespaces.Message.Cloud, id: maxIncomingReadId)
                            default:
                                break
                            }
                        }
                    }
                    return nil
                }
                |> distinctUntilChanged
            }
        } else {
            customChannelDiscussionReadState = .single(nil)
        }
        
        let customThreadOutgoingReadState: Signal<MessageId?, NoError>
        if case .replyThread = chatLocation {
            customThreadOutgoingReadState = context.chatLocationOutgoingReadState(for: chatLocation, contextHolder: chatLocationContextHolder)
        } else {
            customThreadOutgoingReadState = .single(nil)
        }
        
        let availableReactions: Signal<AvailableReactions?, NoError> = (context as! AccountContextImpl).availableReactions
        let availableMessageEffects: Signal<AvailableMessageEffects?, NoError> = (context as! AccountContextImpl).availableMessageEffects
        
        let savedMessageTags: Signal<SavedMessageTags?, NoError>
        if chatLocation.peerId == self.context.account.peerId {
            savedMessageTags = context.engine.stickers.savedMessageTagData()
        } else {
            savedMessageTags = .single(nil)
        }
        
        let peerReactionSettings: Signal<EnginePeerCachedInfoItem<PeerReactionSettings>?, NoError>
        if let peerId = chatLocation.peerId {
            peerReactionSettings = self.context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.ReactionSettings(id: peerId)
            )
            |> map(Optional.init)
        } else {
            peerReactionSettings = .single(nil)
        }
        
        let defaultReaction: Signal<(MessageReaction.Reaction?, Bool), NoError> = combineLatest(
            self.context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)
            ),
            peerReactionSettings,
            self.context.account.postbox.preferencesView(keys: [PreferencesKeys.reactionSettings])
        )
        |> map { peer, peerReactionSettings, preferencesView -> (MessageReaction.Reaction?, Bool) in
            var areStarsEnabled: Bool = false
            if let peerReactionSettings, let value = peerReactionSettings.knownValue?.starsAllowed {
                areStarsEnabled = value
            }
            
            let reactionSettings: ReactionSettings
            if let entry = preferencesView.values[PreferencesKeys.reactionSettings], let value = entry.get(ReactionSettings.self) {
                reactionSettings = value
            } else {
                reactionSettings = .default
            }
            var hasPremium = false
            if case let .user(user) = peer {
                hasPremium = user.isPremium
            }
            return (reactionSettings.effectiveQuickReaction(hasPremium: hasPremium), areStarsEnabled)
        }
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            return lhs.0 == rhs.0 && lhs.1 == rhs.1
        })
        
        let accountPeer = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> map { peer -> EnginePeer? in
            return peer
        }
        |> distinctUntilChanged

        let topicAuthorId: Signal<EnginePeer.Id?, NoError>
        if let peerId = chatLocation.peerId, let threadId = chatLocation.threadId {
            topicAuthorId = context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
                TelegramEngine.EngineData.Item.Peer.ThreadData(id: peerId, threadId: threadId)
            )
            |> map { peer, data -> EnginePeer.Id? in
                guard let peer else {
                    return nil
                }
                if case let .channel(channel) = peer, channel.flags.contains(.isMonoforum) {
                    return nil
                }
                
                return data?.author
            }
            |> distinctUntilChanged
        } else {
            topicAuthorId = .single(nil)
        }

        let audioTranscriptionSuggestion = combineLatest(
            ApplicationSpecificNotice.getAudioTranscriptionSuggestion(accountManager: context.sharedContext.accountManager),
            self.justSentTextMessagePromise.get()
        )
        
        let translationState: Signal<ChatTranslationState?, NoError>
        if let peerId = chatLocation.peerId, peerId.namespace != Namespaces.Peer.SecretChat && peerId != context.account.peerId && subject != .scheduledMessages {
            translationState = chatTranslationState(context: context, peerId: peerId, threadId: self.chatLocation.threadId)
        } else {
            translationState = .single(nil)
        }
        
        let promises = combineLatest(
            self.historyAppearsClearedPromise.get(),
            self.pendingUnpinnedAllMessagesPromise.get(),
            self.pendingRemovedMessagesPromise.get(),
            self.currentlyPlayingMessageIdPromise.get(),
            self.scrollToMessageIdPromise.get(),
            self.chatHasBotsPromise.get(),
            self.allAdMessagesPromise.get()
        )
        
        let contentSettings = self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ContentSettings())
        
        let maxReadStoryId: Signal<Int32?, NoError>
        if let peerId = self.chatLocation.peerId, peerId.namespace == Namespaces.Peer.CloudUser {
            maxReadStoryId = self.context.account.postbox.combinedView(keys: [PostboxViewKey.storiesState(key: .peer(peerId))])
            |> map { views -> Int32? in
                guard let view = views.views[PostboxViewKey.storiesState(key: .peer(peerId))] as? StoryStatesView else {
                    return nil
                }
                if let state = view.value?.get(Stories.PeerState.self) {
                    return state.maxReadId
                } else {
                    return nil
                }
            }
            |> distinctUntilChanged
        } else {
            maxReadStoryId = .single(nil)
        }
        
        let recommendedChannels: Signal<RecommendedChannels?, NoError>
        if let peerId = self.chatLocation.peerId, peerId.namespace == Namespaces.Peer.CloudChannel {
            recommendedChannels = self.context.engine.peers.recommendedChannels(peerId: peerId)
        } else {
            recommendedChannels = .single(nil)
        }
        
        let audioTranscriptionTrial = self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.AudioTranscriptionTrial())
        
        let chatThemes = self.context.engine.themes.getChatThemes(accountManager: self.context.sharedContext.accountManager)
        
        let deviceContactsNumbers = self.context.sharedContext.deviceContactPhoneNumbers.get()
        |> distinctUntilChanged
        
        let premiumConfiguration = PremiumConfiguration.with(appConfiguration: self.context.currentAppConfiguration.with { $0 })
        
        let preferredStoryHighQuality: Signal<Bool, NoError> = combineLatest(
            context.sharedContext.automaticMediaDownloadSettings
            |> map { settings in
                return settings.highQualityStories
            }
            |> distinctUntilChanged,
            context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)
            )
        )
        |> map { setting, peer -> Bool in
            let isPremium = peer?.isPremium ?? false
            return setting && isPremium
        }
        |> distinctUntilChanged
        
        let stopHistoryViewUpdates: Signal<Bool, NoError>
        if let peerId = chatLocation.peerId, (chatLocation.threadId == EngineMessage.newTopicThreadId || chatLocation.threadId == nil) {
            stopHistoryViewUpdates = Signal<Bool, NoError>.single(false)
            |> then(
                self.context.account.pendingMessageManager.newTopicEvents(peerId: peerId)
                |> mapToSignal { event -> Signal<Bool, NoError> in
                    if case .willMove = event {
                        return .single(true)
                    } else {
                        return .never()
                    }
                }
                |> take(1)
            )
        } else {
            stopHistoryViewUpdates = .single(false)
        }
        
        let historyViewUpdateValue = historyViewUpdate
        historyViewUpdate = stopHistoryViewUpdates |> mapToSignal { value in
            if value {
                return .never()
            } else {
                return historyViewUpdateValue
            }
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var measure_isFirstTime = true
        let messageViewQueue = Queue.mainQueue()
        let historyViewTransitionDisposable = (combineLatest(queue: messageViewQueue,
            self.context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.translationSettings]) |> take(1),
            historyViewUpdate |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_historyViewUpdate"),
            self.chatPresentationDataPromise.get() |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_chatPresentationData"),
            selectedMessages |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_selectedMessages"),
            updatingMedia |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_updatingMedia"),
            automaticDownloadNetworkType |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_automaticDownloadNetworkType"),
            preferredStoryHighQuality |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_preferredStoryHighQuality"),
            animatedEmojiStickers |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_animatedEmojiStickers"),
            additionalAnimatedEmojiStickers |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_additionalAnimatedEmojiStickers"),
            customChannelDiscussionReadState |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_customChannelDiscussionReadState"),
            customThreadOutgoingReadState |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_customThreadOutgoingReadState"),
            availableReactions |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_availableReactions"),
            availableMessageEffects |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_availableMessageEffects"),
            savedMessageTags |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_savedMessageTags"),
            defaultReaction |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_defaultReaction"),
            accountPeer |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_accountPeer"),
            audioTranscriptionSuggestion |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_audioTranscriptionSuggestion"),
            promises |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_promises"),
            topicAuthorId |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_topicAuthorId"),
            translationState |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_translationState"),
            maxReadStoryId |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_maxReadStoryId"),
            recommendedChannels |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_recommendedChannels"),
            audioTranscriptionTrial |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_audioTranscriptionTrial"),
            chatThemes |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_chatThemes"),
            deviceContactsNumbers |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_deviceContactsNumbers"),
            contentSettings |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_contentSettings")
        ) |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_firstChatHistoryTransition")).startStrict(next: { [weak self] sharedData, /* MARK: Swiftgram */ update, chatPresentationData, selectedMessages, updatingMedia, networkType, preferredStoryHighQuality, animatedEmojiStickers, additionalAnimatedEmojiStickers, customChannelDiscussionReadState, customThreadOutgoingReadState, availableReactions, availableMessageEffects, savedMessageTags, defaultReaction, accountPeer, suggestAudioTranscription, promises, topicAuthorId, translationState, maxReadStoryId, recommendedChannels, audioTranscriptionTrial, chatThemes, deviceContactsNumbers, contentSettings in
            let (historyAppearsCleared, pendingUnpinnedAllMessages, pendingRemovedMessages, currentlyPlayingMessageIdAndType, scrollToMessageId, chatHasBots, allAdMessages) = promises
            
            if measure_isFirstTime {
                measure_isFirstTime = false
                #if DEBUG
                let deltaTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                print("Chat load time: \(deltaTime) ms")
                #endif
            }
            
            let translationSettings: TranslationSettings
            if let current = sharedData.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) {
                translationSettings = current
            } else {
                translationSettings = TranslationSettings.defaultSettings
            }
            
            func applyHole() {
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        if update.2 != strongSelf.chatHistoryLocationValue {
                            return
                        }
                        
                        let historyView = (strongSelf.opaqueTransactionState as? ChatHistoryTransactionOpaqueState)?.historyView
                        let displayRange = strongSelf.displayedItemRange
                        if let filteredEntries = historyView?.filteredEntries, let visibleRange = displayRange.visibleRange {
                            var anchorIndex: MessageIndex?
                            loop: for index in visibleRange.firstIndex ..< filteredEntries.count {
                                switch filteredEntries[filteredEntries.count - 1 - index] {
                                case let .MessageEntry(message, _, _, _, _, _):
                                    if message.adAttribute == nil {
                                        anchorIndex = message.index
                                        break loop
                                    }
                                case let .MessageGroupEntry(_, messages, _):
                                    for (message, _, _, _, _) in messages {
                                        if message.adAttribute == nil {
                                            anchorIndex = message.index
                                            break loop
                                        }
                                    }
                                default:
                                    break
                                }
                            }
                            if anchorIndex == nil, let historyView = historyView {
                                for entry in historyView.originalView.entries {
                                    anchorIndex = entry.message.index
                                    break
                                }
                            }
                            if let anchorIndex = anchorIndex {
                                strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Navigation(index: .message(anchorIndex), anchorIndex: .message(anchorIndex), count: historyMessageCount, highlight: false), id: (strongSelf.chatHistoryLocationValue?.id).flatMap({ $0 + 1 }) ?? 0)
                            }
                        } else {
                            if let subject = subject, case let .message(messageSubject, highlight, _, setupReply) = subject {
                                let initialSearchLocation: ChatHistoryInitialSearchLocation
                                switch messageSubject {
                                case let .id(id):
                                    initialSearchLocation = .id(id)
                                case let .timestamp(timestamp):
                                    if let peerId = strongSelf.chatLocation.peerId {
                                        initialSearchLocation = .index(MessageIndex(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: 1), timestamp: timestamp))
                                    } else {
                                        //TODO:implement
                                        initialSearchLocation = .index(.absoluteUpperBound())
                                    }
                                }
                                strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .InitialSearch(subject: MessageHistoryInitialSearchSubject(location: initialSearchLocation, quote: (highlight?.quote).flatMap { quote in MessageHistoryInitialSearchSubject.Quote(string: quote.string, offset: quote.offset) }, todoTaskId: highlight?.todoTaskId), count: historyMessageCount, highlight: highlight != nil, setupReply: setupReply), id: (strongSelf.chatHistoryLocationValue?.id).flatMap({ $0 + 1 }) ?? 0)
                            } else if let subject = subject, case let .pinnedMessages(maybeMessageId) = subject, let messageId = maybeMessageId {
                                strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .InitialSearch(subject: MessageHistoryInitialSearchSubject(location: .id(messageId)), count: historyMessageCount, highlight: true, setupReply: false), id: (strongSelf.chatHistoryLocationValue?.id).flatMap({ $0 + 1 }) ?? 0)
                            } else if var chatHistoryLocation = strongSelf.chatHistoryLocationValue {
                                chatHistoryLocation.id += 1
                                strongSelf.chatHistoryLocationValue = chatHistoryLocation
                            } else {
                                strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Initial(count: historyMessageCount), id: (strongSelf.chatHistoryLocationValue?.id).flatMap({ $0 + 1 }) ?? 0)
                            }
                        }
                    }
                }
            }
            
            let initialData: ChatHistoryCombinedInitialData?
            switch update.0 {
            case let .Loading(combinedInitialData, type):
                initialData = combinedInitialData
                
                if resetScrolling, let previousViewValue = previousView.with({ $0 })?.0 {
                    let filteredEntries: [ChatHistoryEntry] = []
                    let processedView = ChatHistoryView(originalView: MessageHistoryView(tag: nil, namespaces: .all, entries: [], holeEarlier: false, holeLater: false, isLoading: true), filteredEntries: filteredEntries, associatedData: previousViewValue.associatedData, lastHeaderId: 0, id: previousViewValue.id, locationInput: previousViewValue.locationInput, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set())
                    let previousValueAndVersion = previousView.swap((processedView, update.1, selectedMessages, allAdMessages.version))
                    let previous = previousValueAndVersion?.0
                    let previousSelectedMessages = previousValueAndVersion?.2
                    
                    if let previousVersion = previousValueAndVersion?.1 {
                        assert(update.1 >= previousVersion)
                    }
                    
                    var reason: ChatHistoryViewTransitionReason
                    reason = ChatHistoryViewTransitionReason.InteractiveChanges
                    
                    let disableAnimations = true
                    let forceSynchronous = true
                    
                    let rawTransition = preparedChatHistoryViewTransition(from: previous, to: processedView, reason: reason, reverse: false, chatLocation: chatLocation, source: source, controllerInteraction: controllerInteraction, scrollPosition: nil, scrollAnimationCurve: nil, initialData: initialData?.initialData, keyboardButtonsMessage: nil, cachedData: initialData?.cachedData, cachedDataMessages: initialData?.cachedDataMessages, readStateData: initialData?.readStateData, flashIndicators: false, updatedMessageSelection: previousSelectedMessages != selectedMessages, messageTransitionNode: messageTransitionNode(), allUpdated: false)
                    var mappedTransition = mappedChatHistoryViewListTransition(context: context, chatLocation: chatLocation, associatedData: previousViewValue.associatedData, controllerInteraction: controllerInteraction, mode: mode, lastHeaderId: 0, isSavedMusic: isSavedMusic, canReorder: canReorder, animateFromPreviousFilter: resetScrolling, transition: rawTransition)
                    
                    if disableAnimations {
                        mappedTransition.options.remove(.AnimateInsertion)
                        mappedTransition.options.remove(.AnimateAlpha)
                        mappedTransition.options.remove(.AnimateTopItemPosition)
                        mappedTransition.options.remove(.RequestItemInsertionAnimations)
                    }
                    if forceSynchronous || resetScrolling {
                        mappedTransition.options.insert(.Synchronous)
                    }
                    if resetScrolling {
                        mappedTransition.options.insert(.AnimateAlpha)
                        mappedTransition.options.insert(.AnimateFullTransition)
                    }
                    
                    if resetScrolling {
                        resetScrolling = false
                    }
                    
                    Queue.mainQueue().async {
                        guard let strongSelf = self else {
                            return
                        }
                        if strongSelf.appliedPlayingMessageId?.0 != currentlyPlayingMessageIdAndType?.0 {
                            strongSelf.appliedPlayingMessageId = currentlyPlayingMessageIdAndType
                        }
                        if strongSelf.appliedScrollToMessageId != scrollToMessageId {
                            strongSelf.appliedScrollToMessageId = scrollToMessageId
                        }
                        strongSelf.enqueueHistoryViewTransition(mappedTransition)
                    }
                }
                
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        let cachedData = initialData?.cachedData
                        let cachedDataMessages = initialData?.cachedDataMessages
                        
                        strongSelf._cachedPeerDataAndMessages.set(.single((cachedData, cachedDataMessages)))
                        
                        let loadState: ChatHistoryNodeLoadState = .loading(false)
                        if strongSelf.loadState != loadState {
                            strongSelf.loadState = loadState
                            strongSelf.loadStateUpdated?(loadState, false)
                            for f in strongSelf.additionalLoadStateUpdated {
                                f(loadState, false)
                            }
                        }
                        
                        let historyState: ChatHistoryNodeHistoryState = .loading
                        if strongSelf.currentHistoryState != historyState {
                            strongSelf.currentHistoryState = historyState
                            strongSelf.historyState.set(historyState)
                        }
                        
                        if !strongSelf.didSetInitialData {
                            strongSelf.didSetInitialData = true
                            var combinedInitialData = combinedInitialData
                            combinedInitialData?.cachedData = nil
                            strongSelf._initialData.set(.single(combinedInitialData))
                        }
                        
                        strongSelf._isReady.set(true)
                        if !strongSelf.didSetReady {
                            strongSelf.didSetReady = true
                            #if DEBUG
                            let deltaTime = (CFAbsoluteTimeGetCurrent() - strongSelf.initTimestamp) * 1000.0
                            print("Chat init to dequeue time: \(deltaTime) ms")
                            #endif
                        }
                    }
                }
                
                if case .Generic(.FillHole) = type {
                    applyHole()
                    return
                }
                
                return
            case let .HistoryView(view, type, scrollPosition, flashIndicators, originalScrollPosition, data, id):
                if case .Generic(.FillHole) = type {
                    applyHole()
                    return
                }
                
                initialData = data
                var updatedScrollPosition = scrollPosition
                
                var reverse = false
                var reverseGroups = false
                var includeSearchEntry = false
                if case let .list(search, reverseValue, reverseGroupsValue, _, _, _) = mode {
                    includeSearchEntry = search
                    reverse = reverseValue
                    reverseGroups = reverseGroupsValue
                }
                
                
                var isPremium = false
                if case let .user(user) = accountPeer, user.isPremium {
                    isPremium = true
                }
                
                var audioTranscriptionProvidedByBoost = false
                var autoTranslate = false
                var isCopyProtectionEnabled: Bool = data.initialData?.peer?.isCopyProtectionEnabled ?? false
                for entry in view.additionalData {
                    if case let .peer(_, maybePeer) = entry, let peer = maybePeer {
                        isCopyProtectionEnabled = peer.isCopyProtectionEnabled
                        if let channel = peer as? TelegramChannel {
                            autoTranslate = channel.flags.contains(.autoTranslateEnabled)
                            if let boostLevel = channel.approximateBoostLevel, boostLevel >= premiumConfiguration.minGroupAudioTranscriptionLevel {
                                audioTranscriptionProvidedByBoost = true
                            }
                        }
                    }
                }
                let alwaysDisplayTranscribeButton = ChatMessageItemAssociatedData.DisplayTranscribeButton(
                    canBeDisplayed: suggestAudioTranscription.0 < 2,
                    displayForNotConsumed: suggestAudioTranscription.1,
                    providedByGroupBoost: audioTranscriptionProvidedByBoost
                )

                // MARK: Swiftgram
                // var translateToLanguage: (fromLang: String, toLang: String)?
                // if let translationState, (isPremium || autoTranslate)  && translationState.isEnabled {
                    var languageCode = translationState?.toLang ?? chatPresentationData.strings.baseLanguageCode
                    let rawSuffix = "-raw"
                    if languageCode.hasSuffix(rawSuffix) {
                        languageCode = String(languageCode.dropLast(rawSuffix.count))
                    }
                    languageCode = normalizeTranslationLanguage(languageCode)
                    let translateToLanguageSG = languageCode
                // }
                var translateToLanguage: (fromLang: String, toLang: String)?
                if let translationState, (isPremium || autoTranslate || true) && translationState.isEnabled {
                    translateToLanguage = (normalizeTranslationLanguage(translationState.fromLang), normalizeTranslationLanguage(languageCode))
                }
                
                var isSuspiciousPeer = false
                if let cachedUserData = data.cachedData as? CachedUserData, let peerStatusSettings = cachedUserData.peerStatusSettings, peerStatusSettings.flags.contains(.canBlock) || peerStatusSettings.flags.contains(.canReport) {
                    isSuspiciousPeer = true
                }
                
                let associatedData = extractAssociatedData(translateToLanguageSG: translateToLanguageSG, translationSettings: translationSettings, /* MARK: Swiftgram */ chatLocation: chatLocation, view: view, automaticDownloadNetworkType: networkType, preferredStoryHighQuality: preferredStoryHighQuality, animatedEmojiStickers: animatedEmojiStickers, additionalAnimatedEmojiStickers: additionalAnimatedEmojiStickers, subject: subject, currentlyPlayingMessageId: currentlyPlayingMessageIdAndType?.0, isCopyProtectionEnabled: isCopyProtectionEnabled, availableReactions: availableReactions, availableMessageEffects: availableMessageEffects, savedMessageTags: savedMessageTags, defaultReaction: defaultReaction.0, areStarReactionsEnabled: defaultReaction.1, isPremium: isPremium, alwaysDisplayTranscribeButton: alwaysDisplayTranscribeButton, accountPeer: accountPeer, topicAuthorId: topicAuthorId, hasBots: chatHasBots, translateToLanguage: translateToLanguage?.toLang, maxReadStoryId: maxReadStoryId, recommendedChannels: recommendedChannels, audioTranscriptionTrial: audioTranscriptionTrial, chatThemes: chatThemes, deviceContactsNumbers: deviceContactsNumbers, isInline: !rotated, showSensitiveContent: contentSettings.ignoreContentRestrictionReasons.contains("sensitive"), isSuspiciousPeer: isSuspiciousPeer)
                
                var includeEmbeddedSavedChatInfo = false
                if case let .replyThread(message) = chatLocation, message.peerId == context.account.peerId, !rotated {
                    includeEmbeddedSavedChatInfo = true
                }
                
                let previousChatHistoryEntriesForViewState = chatHistoryEntriesForViewState.with({ $0 })
                
                let (filteredEntries, updatedChatHistoryEntriesForViewState) = chatHistoryEntriesForView(
                    currentState: previousChatHistoryEntriesForViewState,
                    context: context,
                    location: chatLocation,
                    view: view,
                    includeUnreadEntry: mode == .bubbles,
                    includeEmptyEntry: mode == .bubbles && tag == nil,
                    includeChatInfoEntry: mode == .bubbles,
                    includeSearchEntry: includeSearchEntry && tag != nil,
                    includeEmbeddedSavedChatInfo: includeEmbeddedSavedChatInfo,
                    reverse: reverse,
                    groupMessages: mode == .bubbles,
                    reverseGroupedMessages: reverseGroups,
                    selectedMessages: selectedMessages,
                    presentationData: chatPresentationData,
                    historyAppearsCleared: historyAppearsCleared,
                    skipViewOnceMedia: mode != .bubbles,
                    pendingUnpinnedAllMessages: pendingUnpinnedAllMessages,
                    pendingRemovedMessages: pendingRemovedMessages,
                    associatedData: associatedData,
                    updatingMedia: updatingMedia,
                    customChannelDiscussionReadState: customChannelDiscussionReadState,
                    customThreadOutgoingReadState: customThreadOutgoingReadState,
                    cachedData: data.cachedData,
                    adMessage: allAdMessages.fixed,
                    dynamicAdMessages: allAdMessages.opportunistic
                )
                let lastHeaderId = filteredEntries.last.flatMap { listMessageDateHeaderId(timestamp: $0.index.timestamp) } ?? 0
                let processedView = ChatHistoryView(originalView: view, filteredEntries: filteredEntries, associatedData: associatedData, lastHeaderId: lastHeaderId, id: id, locationInput: update.2, ignoreMessagesInTimestampRange: update.3, ignoreMessageIds: update.4)
                let previousValueAndVersion = previousView.swap((processedView, update.1, selectedMessages, allAdMessages.version))
                let _ = chatHistoryEntriesForViewState.swap(updatedChatHistoryEntriesForViewState)
                let previous = previousValueAndVersion?.0
                let previousSelectedMessages = previousValueAndVersion?.2
                
                if let previousVersion = previousValueAndVersion?.1 {
                    assert(update.1 >= previousVersion)
                }
                                
                if scrollPosition == nil, let originalScrollPosition = originalScrollPosition {
                    switch originalScrollPosition {
                    case let .index(subject, position, _, _, highlight, displayLink, setupReply):
                        if case .upperBound = subject.index {
                            if let previous = previous, previous.filteredEntries.isEmpty {
                                updatedScrollPosition = .index(subject: subject, position: position, directionHint: .Down, animated: false, highlight: highlight, displayLink: displayLink, setupReply: setupReply)
                            }
                        }
                    default:
                        break
                    }
                }
                
                var reason: ChatHistoryViewTransitionReason
                
                let previousHistoryAppearsClearedValue = previousHistoryAppearsCleared.swap(historyAppearsCleared)
                if previousHistoryAppearsClearedValue != nil && previousHistoryAppearsClearedValue != historyAppearsCleared && !historyAppearsCleared {
                    reason = ChatHistoryViewTransitionReason.Initial(fadeIn: !processedView.filteredEntries.isEmpty)
                } else if let previous = previous, previous.id == processedView.id, previous.originalView.entries == processedView.originalView.entries {
                    reason = ChatHistoryViewTransitionReason.InteractiveChanges
                    updatedScrollPosition = nil
                } else if let previous = previous, previous.id == processedView.id, previous.ignoreMessageIds != processedView.ignoreMessageIds {
                    reason = ChatHistoryViewTransitionReason.InteractiveChanges
                    updatedScrollPosition = nil
                } else {
                    switch type {
                        case let .Initial(fadeIn):
                            reason = ChatHistoryViewTransitionReason.Initial(fadeIn: fadeIn)
                        case let .Generic(genericType):
                            switch genericType {
                                case .InitialUnread, .Initial:
                                    reason = ChatHistoryViewTransitionReason.Initial(fadeIn: false)
                                case .Generic:
                                    reason = ChatHistoryViewTransitionReason.InteractiveChanges
                                case .UpdateVisible:
                                    reason = ChatHistoryViewTransitionReason.Reload
                                case .FillHole:
                                    reason = ChatHistoryViewTransitionReason.HoleReload
                            }
                    }
                }
                
                var disableAnimations = false
                var forceSynchronous = false
                
                if let strongSelf = self {
                    if !strongSelf.areContentAnimationsEnabled {
                        disableAnimations = true
                    }
                }
                
                if switchedToAnotherSource {
                    disableAnimations = true
                }
                
                if let previousValueAndVersion = previousValueAndVersion, allAdMessages.version != previousValueAndVersion.3 {
                    reason = ChatHistoryViewTransitionReason.Reload
                    disableAnimations = true
                    forceSynchronous = true
                }
                
                var scrollAnimationCurve: ListViewAnimationCurve? = nil
                if let strongSelf = self, case .default = source {
                    if let translateToLanguage {
                        strongSelf.translationLang = (fromLang: translateToLanguage.fromLang, toLang: translateToLanguage.toLang)
                    } else {
                        strongSelf.translationLang = nil
                    }
                    if strongSelf.appliedScrollToMessageId == nil, let scrollToMessageId = scrollToMessageId {
                        updatedScrollPosition = .index(subject: MessageHistoryScrollToSubject(index: .message(scrollToMessageId), quote: nil), position: .center(.top), directionHint: .Up, animated: true, highlight: false, displayLink: true, setupReply: false)
                        scrollAnimationCurve = .Spring(duration: 0.4)
                    } else {
                        let wasPlaying = strongSelf.appliedPlayingMessageId != nil
                        if strongSelf.appliedPlayingMessageId?.0 != currentlyPlayingMessageIdAndType?.0, let (currentlyPlayingMessageId, currentlyPlayingVideo) = currentlyPlayingMessageIdAndType {
                            if isFirstTime {
                            } else if case let .peer(peerId) = chatLocation, currentlyPlayingMessageId.id.peerId != peerId {
                            } else {
                                var isChat = false
                                if case .peer = chatLocation {
                                    isChat = true
                                }
                                
                                if (isChat && (wasPlaying || currentlyPlayingVideo)) || (!isChat && !wasPlaying && currentlyPlayingVideo) {
                                    var currentIsVisible = true
                                    var nextIsVisible = false
                                    if let appliedPlayingMessageId = strongSelf.appliedPlayingMessageId {
                                        currentIsVisible = false
                                        strongSelf.forEachVisibleMessageItemNode({ view in
                                            if view.item?.message.id == appliedPlayingMessageId.0.id && appliedPlayingMessageId.1 == true {
                                                currentIsVisible = true
                                            }
                                        })
                                    }
                                    strongSelf.forEachVisibleMessageItemNode({ view in
                                        if view.item?.message.id == currentlyPlayingMessageId.id {
                                            nextIsVisible = true
                                        }
                                    })
                                    if currentIsVisible && nextIsVisible && currentlyPlayingVideo {
                                        updatedScrollPosition = .index(subject: MessageHistoryScrollToSubject(index: .message(currentlyPlayingMessageId), quote: nil), position: .center(.bottom), directionHint: .Up, animated: true, highlight: true, displayLink: true, setupReply: false)
                                        scrollAnimationCurve = .Spring(duration: 0.4)
                                    }
                                }
                            }
                        }
                    }
                    isFirstTime = false
                }
                
                if let strongSelf = self {
                    if let recommendedChannels, !recommendedChannels.channels.isEmpty && !recommendedChannels.isHidden {
                        if !strongSelf.didSetupRecommendedChannelsPreload {
                            strongSelf.didSetupRecommendedChannelsPreload = true
                            let preloadDisposable = DisposableSet()
                            for channel in recommendedChannels.channels.prefix(5) {
                                preloadDisposable.add(strongSelf.context.account.viewTracker.polledChannel(peerId: channel.peer.id).startStrict())
                                preloadDisposable.add(strongSelf.context.account.addAdditionalPreloadHistoryPeerId(peerId: channel.peer.id))
                            }
                            strongSelf.preloadRecommendedChannelsDisposable.set(preloadDisposable)
                        }
                    } else {
                        strongSelf.didSetupRecommendedChannelsPreload = false
                        strongSelf.preloadRecommendedChannelsDisposable.set(nil)
                    }
                }

                if let strongSelf = self, updatedScrollPosition == nil, case .InteractiveChanges = reason, case let .known(offset) = strongSelf.visibleContentOffset(), abs(offset) <= 0.9, let previous = previous {
                    var fillsScreen = true
                    switch strongSelf.visibleBottomContentOffset() {
                    case let .known(bottomOffset):
                        if bottomOffset <= strongSelf.visibleSize.height - strongSelf.insets.bottom {
                            fillsScreen = false
                        }
                    default:
                        break
                    }

                    var previousNumAds = 0
                    for entry in previous.filteredEntries {
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            if message.adAttribute != nil {
                                previousNumAds += 1
                            }
                        }
                    }

                    var updatedNumAds = 0
                    var firstNonAdIndex: MessageIndex?
                    for entry in processedView.filteredEntries.reversed() {
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            if message.adAttribute != nil {
                                updatedNumAds += 1
                            } else {
                                if firstNonAdIndex == nil {
                                    firstNonAdIndex = message.index
                                }
                            }
                        }
                    }

                    if fillsScreen, let firstNonAdIndex = firstNonAdIndex, previousNumAds == 0, updatedNumAds != 0 {
                        updatedScrollPosition = .index(subject: MessageHistoryScrollToSubject(index: .message(firstNonAdIndex), quote: nil), position: .top(0.0), directionHint: .Up, animated: false, highlight: false, displayLink: false, setupReply: false)
                        disableAnimations = true
                    }
                }
                
                if let strongSelf = self, updatedScrollPosition == nil, case .InteractiveChanges = reason, let previous = previous, case let .known(offset) = strongSelf.visibleContentOffset(), abs(offset) <= 320.0 {
                    var hadJoin = false
                    var hadAd = false
                    for entry in previous.filteredEntries.reversed() {
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            if let action = message.media.first(where: { $0 is TelegramMediaAction }) as? TelegramMediaAction, case .joinedChannel = action.action {
                                hadJoin = true
                                break
                            } else if message.adAttribute != nil {
                                hadAd = true
                            }
                        }
                    }
                    
                    if !hadJoin && hadAd {
                        for entry in processedView.filteredEntries.reversed() {
                            if case let .MessageEntry(message, _, _, _, _, _) = entry {
                                if message.adAttribute == nil {
                                    if let action = message.media.first(where: { $0 is TelegramMediaAction }) as? TelegramMediaAction, case .joinedChannel = action.action {
                                        updatedScrollPosition = .index(subject: MessageHistoryScrollToSubject(index: .message(message.index), quote: nil), position: .top(0.0), directionHint: .Up, animated: true, highlight: false, displayLink: false, setupReply: false)
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
                
                var forceUpdateAll = false
                if let previous = previous, previous.associatedData.isPremium != processedView.associatedData.isPremium {
                    forceUpdateAll = true
                }
                
                var keyboardButtonsMessage = view.topTaggedMessages.first
                if let keyboardButtonsMessageValue = keyboardButtonsMessage, keyboardButtonsMessageValue.isRestricted(platform: "ios", contentSettings: context.currentContentSettings.with({ $0 })) {
                    keyboardButtonsMessage = nil
                }
                
                let rawTransition = preparedChatHistoryViewTransition(from: previous, to: processedView, reason: reason, reverse: reverse, chatLocation: chatLocation, source: source, controllerInteraction: controllerInteraction, scrollPosition: updatedScrollPosition, scrollAnimationCurve: scrollAnimationCurve, initialData: initialData?.initialData, keyboardButtonsMessage: keyboardButtonsMessage, cachedData: initialData?.cachedData, cachedDataMessages: initialData?.cachedDataMessages, readStateData: initialData?.readStateData, flashIndicators: flashIndicators, updatedMessageSelection: previousSelectedMessages != selectedMessages, messageTransitionNode: messageTransitionNode(), allUpdated: !isSavedMusic || forceUpdateAll)
                var mappedTransition = mappedChatHistoryViewListTransition(context: context, chatLocation: chatLocation, associatedData: associatedData, controllerInteraction: controllerInteraction, mode: mode, lastHeaderId: lastHeaderId, isSavedMusic: isSavedMusic, canReorder: processedView.filteredEntries.count > 1 && canReorder, animateFromPreviousFilter: resetScrolling, transition: rawTransition)
                
                if disableAnimations {
                    mappedTransition.options.remove(.AnimateInsertion)
                    mappedTransition.options.remove(.AnimateAlpha)
                    mappedTransition.options.remove(.AnimateTopItemPosition)
                    mappedTransition.options.remove(.RequestItemInsertionAnimations)
                }
                if forceSynchronous || resetScrolling || switchedToAnotherSource {
                    mappedTransition.options.insert(.Synchronous)
                }
                if resetScrolling {
                    mappedTransition.options.insert(.AnimateAlpha)
                    mappedTransition.options.insert(.AnimateFullTransition)
                }
                
                if resetScrolling {
                    resetScrolling = false
                }
                
                Queue.mainQueue().async {
                    guard let strongSelf = self else {
                        return
                    }
                    if strongSelf.appliedPlayingMessageId?.0 != currentlyPlayingMessageIdAndType?.0 {
                        strongSelf.appliedPlayingMessageId = currentlyPlayingMessageIdAndType
                    }
                    if strongSelf.appliedScrollToMessageId != scrollToMessageId {
                        strongSelf.appliedScrollToMessageId = scrollToMessageId
                    }
                    strongSelf.enqueueHistoryViewTransition(mappedTransition)
                }
            }
        })
        
        self.historyDisposable.set(historyViewTransitionDisposable.strict())
    }
    
    func stopHistoryUpdates() {
        self.historyDisposable.set(nil)
    }
    
    private func beginReadHistoryManagement() {
        let previousMaxIncomingMessageIndexByNamespace = Atomic<[MessageId.Namespace: MessageIndex]>(value: [:])
        let readHistory = combineLatest(self.maxVisibleIncomingMessageIndex.get(), self.canReadHistory.get())
        
        self.readHistoryDisposable.set((readHistory |> deliverOnMainQueue).startStrict(next: { [weak self] messageIndex, canRead in
            guard let strongSelf = self else {
                return
            }
            if !canRead {
                return
            }
            
            var apply = false
            let _ = previousMaxIncomingMessageIndexByNamespace.modify { dict in
                let previousIndex = dict[messageIndex.id.namespace]
                if previousIndex == nil || previousIndex! < messageIndex {
                    apply = true
                    var dict = dict
                    dict[messageIndex.id.namespace] = messageIndex
                    return dict
                }
                return dict
            }
            if apply {
                switch strongSelf.chatLocation {
                case .peer, .replyThread:
                    if !strongSelf.context.sharedContext.immediateExperimentalUISettings.skipReadHistory && !strongSelf.context.account.isSupportUser {
                        strongSelf.context.applyMaxReadIndex(for: strongSelf.chatLocation, contextHolder: strongSelf.chatLocationContextHolder, messageIndex: messageIndex)
                    }
                case .customChatContents:
                    break
                }
            }
        }).strict())
        
        self.canReadHistoryDisposable?.dispose()
        self.canReadHistoryDisposable = (self.canReadHistory.get() |> deliverOnMainQueue).startStrict(next: { [weak self, weak context] value in
            if let strongSelf = self {
                if strongSelf.canReadHistoryValue != value {
                    strongSelf.canReadHistoryValue = value
                    strongSelf.controllerInteraction.canReadHistory = value
                    strongSelf.updateReadHistoryActions()

                    if strongSelf.canReadHistoryValue && !strongSelf.suspendReadingReactions && !strongSelf.messageIdsScheduledForMarkAsSeen.isEmpty {
                        let messageIds = strongSelf.messageIdsScheduledForMarkAsSeen
                        strongSelf.messageIdsScheduledForMarkAsSeen.removeAll()
                        context?.account.viewTracker.updateMarkMentionsSeenForMessageIds(messageIds: messageIds)
                    }
                    
                    strongSelf.attemptReadingReactions()
                }
            }
        }).strict()
    }
    
    private func beginPresentationDataManagement(updated: Signal<PresentationData, NoError>) {
        let appConfiguration = self.context.account.postbox.preferencesView(keys: [PreferencesKeys.appConfiguration])
        |> take(1)
        |> map { view in
            return view.values[PreferencesKeys.appConfiguration]?.get(AppConfiguration.self) ?? .defaultValue
        }
        
        var didSetPresentationData = false
        self.presentationDataDisposable = (combineLatest(queue: .mainQueue(),
            updated |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_beginPresentationDataManagement_updated"),
            appConfiguration |> debug_measureTimeToFirstEvent(label: "chatHistoryNode_beginPresentationDataManagement_appConfiguration")
        )
        |> deliverOnMainQueue).startStrict(next: { [weak self] presentationData, appConfiguration in
            if let strongSelf = self {
                let previousTheme = strongSelf.currentPresentationData.theme
                let previousStrings = strongSelf.currentPresentationData.strings
                let previousWallpaper = strongSelf.currentPresentationData.theme.wallpaper
                let previousAnimatedEmojiScale = strongSelf.currentPresentationData.animatedEmojiScale
                
                let animatedEmojiConfig = ChatHistoryAnimatedEmojiConfiguration.with(appConfiguration: appConfiguration)
                
                if !didSetPresentationData || previousTheme !== presentationData.theme || previousStrings !== presentationData.strings || previousWallpaper != presentationData.chatWallpaper || previousAnimatedEmojiScale != animatedEmojiConfig.scale {
                    didSetPresentationData = true
                    
                    let themeData = ChatPresentationThemeData(theme: presentationData.theme, wallpaper: presentationData.chatWallpaper)
                    let chatPresentationData = ChatPresentationData(theme: themeData, fontSize: presentationData.chatFontSize, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, disableAnimations: true, largeEmoji: presentationData.largeEmoji, chatBubbleCorners: presentationData.chatBubbleCorners, animatedEmojiScale: animatedEmojiConfig.scale)
                    
                    strongSelf.currentPresentationData = chatPresentationData
                    strongSelf.dynamicBounceEnabled = false
                    
                    strongSelf.forEachItemHeaderNode { itemHeaderNode in
                        if let dateNode = itemHeaderNode as? ChatMessageDateHeaderNodeImpl {
                            dateNode.updatePresentationData(chatPresentationData, context: strongSelf.context)
                        } else if let avatarNode = itemHeaderNode as? ChatMessageAvatarHeaderNodeImpl {
                            avatarNode.updatePresentationData(chatPresentationData, context: strongSelf.context)
                        } else if let dateNode = itemHeaderNode as? ListMessageDateHeaderNode {
                            dateNode.updateThemeAndStrings(theme: presentationData.theme, strings: presentationData.strings)
                        }
                    }
                    strongSelf.chatPresentationDataPromise.set(.single(chatPresentationData))
                }
            }
        }).strict()
    }
    
    private func attemptReadingReactions() {
        if self.canReadHistoryValue && !self.suspendReadingReactions && !self.context.sharedContext.immediateExperimentalUISettings.skipReadHistory && !self.messageIdsWithReactionsScheduledForMarkAsSeen.isEmpty {
            let messageIds = self.messageIdsWithReactionsScheduledForMarkAsSeen
            
            let _ = self.displayUnseenReactionAnimations(messageIds: Array(messageIds))
            
            self.messageIdsWithReactionsScheduledForMarkAsSeen.removeAll()
            self.context.account.viewTracker.updateMarkReactionsSeenForMessageIds(messageIds: messageIds)
        }
        
        if self.canReadHistoryValue {
            self.forEachVisibleMessageItemNode { itemNode in
                itemNode.unreadMessageRangeUpdated()
            }
        }
    }
    
    func takeGenericReactionEffect() -> String? {
        let result = self.genericReactionEffect
        self.loadNextGenericReactionEffect(context: self.context)
        
        return result
    }
    
    private func loadNextGenericReactionEffect(context: AccountContext) {
        self.genericReactionEffectDisposable?.dispose()
        self.genericReactionEffectDisposable = (ReactionContextNode.randomGenericReactionEffect(context: context) |> deliverOnMainQueue).startStrict(next: { [weak self] path in
            guard let strongSelf = self else {
                return
            }
            strongSelf.genericReactionEffect = path
        })
    }
    
    public func setLoadStateUpdated(_ f: @escaping (ChatHistoryNodeLoadState, Bool) -> Void) {
        self.loadStateUpdated = f
    }
    
    public func addSetLoadStateUpdated(_ f: @escaping (ChatHistoryNodeLoadState, Bool) -> Void) {
        self.additionalLoadStateUpdated.append(f)
    }

    private func maybeUpdateOverscrollAction(offset: CGFloat?) {
        if self.freezeOverscrollControl {
            return
        }
        if let offset = offset, offset < -0.1, self.offerNextChannelToRead, let chatControllerNode = self.controllerInteraction.chatControllerNode() as? ChatControllerNode, chatControllerNode.shouldAllowOverscrollActions {
            let overscrollView: ComponentHostView<Empty>
            if let current = self.overscrollView {
                overscrollView = current
            } else {
                overscrollView = ComponentHostView<Empty>()
                self.overscrollView = overscrollView
                self.view.superview?.insertSubview(overscrollView, aboveSubview: self.view)
            }

            let expandDistance = max(-offset - 12.0, 0.0)
            let expandProgress: CGFloat = min(1.0, expandDistance / 94.0)

            let previousType = self.currentOverscrollExpandProgress >= 1.0
            let currentType = expandProgress >= 1.0

            if previousType != currentType, currentType {
                if self.feedback == nil {
                    self.feedback = HapticFeedback()
                }
                if let _ = nextChannelToRead {
                    self.feedback?.tap()
                } else {
                    self.feedback?.success()
                }
            }

            self.currentOverscrollExpandProgress = expandProgress

            var overscrollFrame = CGRect(origin: CGPoint(x: 0.0, y: self.insets.top), size: CGSize(width: self.bounds.width, height: 94.0))
            if self.freezeOverscrollControlProgress {
                overscrollFrame.origin.y -= max(0.0, 94.0 - expandDistance)
            }

            overscrollView.frame = self.view.convert(overscrollFrame, to: self.view.superview!)

            let _ = overscrollView.update(
                transition: .immediate,
                component: AnyComponent(ChatOverscrollControl(
                    backgroundColor: selectDateFillStaticColor(theme: self.currentPresentationData.theme.theme, wallpaper: self.currentPresentationData.theme.wallpaper),
                    foregroundColor: bubbleVariableColor(variableColor: self.currentPresentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: self.currentPresentationData.theme.wallpaper),
                    peer: self.nextChannelToRead?.peer,
                    threadData: (self.nextChannelToRead?.threadData).flatMap { threadData in
                        return ChatOverscrollThreadData(
                            id: threadData.id,
                            data: threadData.data
                        )
                    },
                    isForumThread: self.chatLocation.threadId != nil,
                    unreadCount: self.nextChannelToRead?.unreadCount ?? 0,
                    location: self.nextChannelToRead?.location ?? .same,
                    context: self.context,
                    expandDistance: self.freezeOverscrollControl ? 94.0 : expandDistance,
                    freezeProgress: false,
                    absoluteRect: CGRect(origin: CGPoint(x: overscrollFrame.minX, y: self.bounds.height - overscrollFrame.minY), size: overscrollFrame.size),
                    absoluteSize: self.bounds.size,
                    wallpaperNode: chatControllerNode.backgroundNode
                )),
                environment: {},
                containerSize: CGSize(width: self.bounds.width, height: 200.0)
            )
        } else if let overscrollView = self.overscrollView {
            self.overscrollView = nil
            overscrollView.removeFromSuperview()
        }
    }
    
    func refreshPollActionsForVisibleMessages() {
        let _ = self.clientId.swap(nextClientId)
        nextClientId += 1
        
        self.updateVisibleItemRange(force: true)
    }
    
    func refocusOnUnreadMessagesIfNeeded() {
        self.forEachItemNode({ itemNode in
            if let itemNode = itemNode as? ChatUnreadItemNode {
                self.ensureItemNodeVisible(itemNode, animated: false, overflow: 0.0, curve: .Default(duration: nil))
            }
        })
    }
    
    private func maybeInsertPendingAdMessage(historyView: ChatHistoryView, toLaterRange: (Int, Int), toEarlierRange: (Int, Int)) {
        if self.pendingDynamicAdMessages.isEmpty {
            return
        }
        
        let selectedRange: (Int, Int)
        if self.currentPrefetchDirectionIsToLater {
            selectedRange = (toLaterRange.0 + 1, toLaterRange.1)
        } else {
            selectedRange = (toEarlierRange.0, toEarlierRange.1 - 1)
        }
        
        if selectedRange.0 <= selectedRange.1 {
            var insertionTimestamp: Int32?
            if self.currentPrefetchDirectionIsToLater {
                outer: for i in selectedRange.0 ... selectedRange.1 {
                    if historyView.originalView.laterId == nil && i >= historyView.filteredEntries.count - 4 {
                        break
                    }
                    
                    switch historyView.filteredEntries[i] {
                    case let .MessageEntry(message, _, _, _, _, _):
                        if message.id.namespace == Namespaces.Message.Cloud {
                            insertionTimestamp = message.timestamp
                            break outer
                        }
                    case let .MessageGroupEntry(_, messages, _):
                        for (message, _, _, _, _) in messages {
                            if message.id.namespace == Namespaces.Message.Cloud {
                                insertionTimestamp = message.timestamp
                                break outer
                            }
                        }
                    default:
                        break
                    }
                }
            } else {
                outer: for i in (selectedRange.0 ... selectedRange.1).reversed() {
                    switch historyView.filteredEntries[i] {
                    case let .MessageEntry(message, _, _, _, _, _):
                        if message.id.namespace == Namespaces.Message.Cloud {
                            insertionTimestamp = message.timestamp
                            break outer
                        }
                    case let .MessageGroupEntry(_, messages, _):
                        for (message, _, _, _, _) in messages {
                            if message.id.namespace == Namespaces.Message.Cloud {
                                insertionTimestamp = message.timestamp
                                break outer
                            }
                        }
                    default:
                        break
                    }
                }
            }
            if let insertionTimestamp = insertionTimestamp {
                let initialMessage = self.pendingDynamicAdMessages.removeFirst()
                let message = Message(
                    stableId: UInt32.max - 1 - UInt32(self.nextPendingDynamicMessageId),
                    stableVersion: initialMessage.stableVersion,
                    id: MessageId(peerId: initialMessage.id.peerId, namespace: initialMessage.id.namespace, id: self.nextPendingDynamicMessageId),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: insertionTimestamp,
                    flags: initialMessage.flags,
                    tags: initialMessage.tags,
                    globalTags: initialMessage.globalTags,
                    localTags: initialMessage.localTags,
                    customTags: initialMessage.customTags,
                    forwardInfo: initialMessage.forwardInfo,
                    author: initialMessage.author,
                    text: /*"\(initialMessage.adAttribute!.opaqueId.hashValue)" + */initialMessage.text,
                    attributes: initialMessage.attributes,
                    media: initialMessage.media,
                    peers: initialMessage.peers,
                    associatedMessages: initialMessage.associatedMessages,
                    associatedMessageIds: initialMessage.associatedMessageIds,
                    associatedMedia: initialMessage.associatedMedia,
                    associatedThreadInfo: initialMessage.associatedThreadInfo,
                    associatedStories: initialMessage.associatedStories
                )
                self.nextPendingDynamicMessageId += 1
                
                var allAdMessages = self.allAdMessages
                if allAdMessages.fixed?.adAttribute?.opaqueId == message.adAttribute?.opaqueId {
                    allAdMessages.fixed = self.pendingDynamicAdMessages.first?.withUpdatedStableVersion(stableVersion: UInt32(self.nextPendingDynamicMessageId))
                }
                allAdMessages.opportunistic.append(message)
                allAdMessages.version += 1
                self.allAdMessages = allAdMessages
            }
        }
        //TODO:loc mark all ads as seen
    }
    
    func markAdAsSeen(opaqueId: Data) {
        for i in 0 ..< self.pendingDynamicAdMessages.count {
            if let pendingAttribute = self.pendingDynamicAdMessages[i].adAttribute, pendingAttribute.opaqueId == opaqueId {
                self.pendingDynamicAdMessages.remove(at: i)
                break
            }
        }
        if !self.seenAdIds.contains(opaqueId) {
            self.seenAdIds.append(opaqueId)
            self.adMessagesContext?.markAsSeen(opaqueId: opaqueId)
        }
    }
    
    private func processDisplayedItemRangeChanged(displayedRange: ListViewDisplayedItemRange, transactionState: ChatHistoryTransactionOpaqueState) {
        let historyView = transactionState.historyView
        var isTopReplyThreadMessageShownValue = false
        var topVisibleMessageRange: ChatTopVisibleMessageRange?
        let isLoading = historyView.originalView.isLoading
        let translateToLanguage = transactionState.historyView.associatedData.translateToLanguage
        
        if let visible = displayedRange.visibleRange {
            let indexRange = (historyView.filteredEntries.count - 1 - visible.lastIndex, historyView.filteredEntries.count - 1 - visible.firstIndex)
            if indexRange.0 > indexRange.1 {
                assert(false)
                return
            }
            
            var messageIdsToTranslate: [MessageId] = []
            var messageIdsToFactCheck: [MessageId] = []
            if let translateToLanguage {
                let extendedRange: Int = 2
                var wideIndexRange = (historyView.filteredEntries.count - 1 - visible.lastIndex - extendedRange, historyView.filteredEntries.count - 1 - visible.firstIndex + extendedRange)
                wideIndexRange = (max(0, min(historyView.filteredEntries.count - 1, wideIndexRange.0)), max(0, min(historyView.filteredEntries.count - 1, wideIndexRange.1)))
                if wideIndexRange.0 > wideIndexRange.1 {
                    assert(false)
                    return
                }
                
                if wideIndexRange.0 <= wideIndexRange.1 {
                    for i in (wideIndexRange.0 ... wideIndexRange.1) {
                        switch historyView.filteredEntries[i] {
                        case let .MessageEntry(message, _, _, _, _, _):
                            guard message.adAttribute == nil && message.id.namespace == Namespaces.Message.Cloud else {
                                continue
                            }
                            guard message.author?.id != self.context.account.peerId else {
                                continue
                            }
                            if let translation = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, translation.toLang == translateToLanguage {
                                continue
                            }
                            if !message.text.isEmpty {
                                messageIdsToTranslate.append(message.id)
                            } else if let _ = message.media.first(where: { $0 is TelegramMediaPoll }) {
                                messageIdsToTranslate.append(message.id)
                            } else if let audioTranscription = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute, !audioTranscription.text.isEmpty && !audioTranscription.isPending {
                                messageIdsToTranslate.append(message.id)
                            }
                        case let .MessageGroupEntry(_, messages, _):
                            for (message, _, _, _, _) in messages {
                                guard message.adAttribute == nil && message.id.namespace == Namespaces.Message.Cloud else {
                                    continue
                                }
                                guard message.author?.id != self.context.account.peerId else {
                                    continue
                                }
                                if let translation = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, translation.toLang == translateToLanguage {
                                    continue
                                }
                                if !message.text.isEmpty {
                                    messageIdsToTranslate.append(message.id)
                                }
                            }
                        default:
                            break
                        }
                    }
                }
            }
            
            
            let readIndexRange = (0, historyView.filteredEntries.count - 1 - visible.firstIndex)
            
            let toEarlierRange = (0, historyView.filteredEntries.count - 1 - visible.lastIndex - 1)
            let toLaterRange = (historyView.filteredEntries.count - 1 - (visible.firstIndex - 1), historyView.filteredEntries.count - 1)
            
            var messageIdsWithViewCount: [MessageId] = []
            var messageIdsWithLiveLocation: [MessageId] = []
            var messageIdsWithUnsupportedMedia: [MessageAndThreadId] = []
            var messageIdsWithRefreshMedia: [MessageId] = []
            var messageIdsWithRefreshStories: [MessageId] = []
            var messageIdsWithUnseenPersonalMention: [MessageId] = []
            var messageIdsWithUnseenReactions: [MessageId] = []
            var messageIdsWithInactiveExtendedMedia = Set<MessageId>()
            var downloadableResourceIds: [(messageId: MessageId, resourceId: String)] = []
            var allVisibleAnchorMessageIds: [(MessageId, Int)] = []
            var visibleAdOpaqueIds: [Data] = []
            var peerIdsWithRefreshStories: [PeerId] = []
            var visibleBusinessBotMessageId: EngineMessage.Id?
            
            if indexRange.0 <= indexRange.1 {
                for i in (indexRange.0 ... indexRange.1) {
                    let nodeIndex = historyView.filteredEntries.count - 1 - i
                    
                    switch historyView.filteredEntries[i] {
                    case let .MessageEntry(message, _, _, _, _, _):
                        if let author = message.author as? TelegramUser {
                            peerIdsWithRefreshStories.append(author.id)
                        }
                        
                        var hasUnconsumedMention = false
                        var hasUnconsumedContent = false
                        if message.tags.contains(.unseenPersonalMessage) {
                            for attribute in message.attributes {
                                if let attribute = attribute as? ConsumablePersonalMentionMessageAttribute, !attribute.pending {
                                    hasUnconsumedMention = true
                                }
                            }
                        }
                        var contentRequiredValidation = false
                        var mediaRequiredValidation = false
                        var hasUnseenReactions = false
                        var storiesRequiredValidation = false
                        var factCheckRequired = false
                        for attribute in message.attributes {
                            if attribute is ViewCountMessageAttribute {
                                if message.id.namespace == Namespaces.Message.Cloud {
                                    messageIdsWithViewCount.append(message.id)
                                }
                            } else if attribute is ReplyThreadMessageAttribute {
                                if message.id.namespace == Namespaces.Message.Cloud {
                                    messageIdsWithViewCount.append(message.id)
                                }
                            } else if let attribute = attribute as? ConsumableContentMessageAttribute, !attribute.consumed {
                                hasUnconsumedContent = true
                            } else if let _ = attribute as? ContentRequiresValidationMessageAttribute {
                                contentRequiredValidation = true
                            } else if let attribute = attribute as? ReactionsMessageAttribute, attribute.hasUnseen {
                                hasUnseenReactions = true
                            } else if let attribute = attribute as? AdMessageAttribute {
                                if message.stableId != ChatHistoryListNodeImpl.fixedAdMessageStableId {
                                    visibleAdOpaqueIds.append(attribute.opaqueId)
                                }
                            } else if let _ = attribute as? ReplyStoryAttribute {
                                storiesRequiredValidation = true
                            } else if let attribute = attribute as? FactCheckMessageAttribute, case .Pending = attribute.content {
                                factCheckRequired = true
                            }
                        }
                        
                        for media in message.media {
                            if let _ = media as? TelegramMediaUnsupported {
                                contentRequiredValidation = true
                            } else if message.flags.contains(.Incoming), let media = media as? TelegramMediaMap, let liveBroadcastingTimeout = media.liveBroadcastingTimeout {
                                let timestamp = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                                if liveBroadcastingTimeout == liveLocationIndefinitePeriod || message.timestamp + liveBroadcastingTimeout > timestamp {
                                    messageIdsWithLiveLocation.append(message.id)
                                }
                            } else if let telegramFile = media as? TelegramMediaFile {
                                if telegramFile.isAnimatedSticker, (message.id.peerId.namespace == Namespaces.Peer.SecretChat || !telegramFile.previewRepresentations.isEmpty), let size = telegramFile.size, size > 0 && size <= 128 * 1024 {
                                    if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
                                        if telegramFile.fileId.namespace == Namespaces.Media.CloudFile {
                                            var isValidated = false
                                            attributes: for attribute in telegramFile.attributes {
                                                if case .hintIsValidated = attribute {
                                                    isValidated = true
                                                    break attributes
                                                }
                                            }
                                            
                                            if !isValidated {
                                                mediaRequiredValidation = true
                                            }
                                        }
                                    }
                                }
                                downloadableResourceIds.append((message.id, telegramFile.resource.id.stringRepresentation))
                            } else if let image = media as? TelegramMediaImage {
                                if let representation = image.representations.last {
                                    downloadableResourceIds.append((message.id, representation.resource.id.stringRepresentation))
                                }
                            } else if let invoice = media as? TelegramMediaInvoice, let extendedMedia = invoice.extendedMedia, case .preview = extendedMedia {
                                messageIdsWithInactiveExtendedMedia.insert(message.id)
                                if invoice.version != TelegramMediaInvoice.lastVersion {
                                    contentRequiredValidation = true
                                }
                            } else if let paidContent = media as? TelegramMediaPaidContent, let extendedMedia = paidContent.extendedMedia.first, case .preview = extendedMedia {
                                messageIdsWithInactiveExtendedMedia.insert(message.id)
                            } else if let _ = media as? TelegramMediaStory {
                                storiesRequiredValidation = true
                            } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, let _ = content.story {
                                storiesRequiredValidation = true
                            }
                        }
                        if contentRequiredValidation {
                            messageIdsWithUnsupportedMedia.append(MessageAndThreadId(messageId: message.id, threadId: message.threadId))
                        }
                        if mediaRequiredValidation {
                            messageIdsWithRefreshMedia.append(message.id)
                        }
                        if storiesRequiredValidation {
                            messageIdsWithRefreshStories.append(message.id)
                        }
                        if hasUnconsumedMention && !hasUnconsumedContent {
                            messageIdsWithUnseenPersonalMention.append(message.id)
                        }
                        if hasUnseenReactions {
                            messageIdsWithUnseenReactions.append(message.id)
                        }
                        if factCheckRequired {
                            messageIdsToFactCheck.append(message.id)
                        }
                        
                        if case let .replyThread(replyThreadMessage) = self.chatLocation, replyThreadMessage.effectiveTopId == message.id {
                            isTopReplyThreadMessageShownValue = true
                        }
                        if let topVisibleMessageRangeValue = topVisibleMessageRange {
                            topVisibleMessageRange = ChatTopVisibleMessageRange(lowerBound: topVisibleMessageRangeValue.lowerBound, upperBound: message.index, isLast: i == historyView.filteredEntries.count - 1, isLoading: isLoading)
                        } else {
                            topVisibleMessageRange = ChatTopVisibleMessageRange(lowerBound: message.index, upperBound: message.index, isLast: i == historyView.filteredEntries.count - 1, isLoading: isLoading)
                        }
                        if message.id.namespace == Namespaces.Message.Cloud, self.remainingDynamicAdMessageInterval != nil {
                            allVisibleAnchorMessageIds.append((message.id, nodeIndex))
                        }
                    case let .MessageGroupEntry(_, messages, _):
                        if let author = messages.first?.0.author as? TelegramUser {
                            peerIdsWithRefreshStories.append(author.id)
                        }
                        
                        for (message, _, _, _, _) in messages {
                            var hasUnconsumedMention = false
                            var hasUnconsumedContent = false
                            var hasUnseenReactions = false
                            var factCheckRequired = false
                            if message.tags.contains(.unseenPersonalMessage) {
                                for attribute in message.attributes {
                                    if let attribute = attribute as? ConsumablePersonalMentionMessageAttribute, !attribute.pending {
                                        hasUnconsumedMention = true
                                    }
                                }
                            }
                            for media in message.media {
                                if let telegramFile = media as? TelegramMediaFile {
                                    downloadableResourceIds.append((message.id, telegramFile.resource.id.stringRepresentation))
                                } else if let image = media as? TelegramMediaImage {
                                    if let representation = image.representations.last {
                                        downloadableResourceIds.append((message.id, representation.resource.id.stringRepresentation))
                                    }
                                }
                            }
                            for attribute in message.attributes {
                                if attribute is ViewCountMessageAttribute {
                                    if message.id.namespace == Namespaces.Message.Cloud {
                                        messageIdsWithViewCount.append(message.id)
                                    }
                                } else if attribute is ReplyThreadMessageAttribute {
                                    if message.id.namespace == Namespaces.Message.Cloud {
                                        messageIdsWithViewCount.append(message.id)
                                    }
                                } else if let attribute = attribute as? ConsumableContentMessageAttribute, !attribute.consumed {
                                    hasUnconsumedContent = true
                                } else if let attribute = attribute as? ReactionsMessageAttribute, attribute.hasUnseen {
                                    hasUnseenReactions = true
                                } else if let attribute = attribute as? FactCheckMessageAttribute, case .Pending = attribute.content {
                                    factCheckRequired = true
                                }
                            }
                            if hasUnconsumedMention && !hasUnconsumedContent {
                                messageIdsWithUnseenPersonalMention.append(message.id)
                            }
                            if hasUnseenReactions {
                                messageIdsWithUnseenReactions.append(message.id)
                            }
                            if factCheckRequired {
                                messageIdsToFactCheck.append(message.id)
                            }
                            if case let .replyThread(replyThreadMessage) = self.chatLocation, replyThreadMessage.effectiveTopId == message.id {
                                isTopReplyThreadMessageShownValue = true
                            }
                            if let topVisibleMessageRangeValue = topVisibleMessageRange {
                                topVisibleMessageRange = ChatTopVisibleMessageRange(lowerBound: topVisibleMessageRangeValue.lowerBound, upperBound: message.index, isLast: i == historyView.filteredEntries.count - 1, isLoading: isLoading)
                            } else {
                                topVisibleMessageRange = ChatTopVisibleMessageRange(lowerBound: message.index, upperBound: message.index, isLast: i == historyView.filteredEntries.count - 1, isLoading: isLoading)
                            }
                        }
                        if let message = messages.first {
                            if message.0.id.namespace == Namespaces.Message.Cloud, self.remainingDynamicAdMessageInterval != nil {
                                allVisibleAnchorMessageIds.append((message.0.id, nodeIndex))
                            }
                        }
                    default:
                        break
                    }
                }
            }
            
            var messageIdsWithPossibleReactions: [MessageId] = []
            for entry in historyView.filteredEntries {
                switch entry {
                case let .MessageEntry(message, _, _, _, _, _):
                    if let _ = message.inlineBotAttribute {
                        if let visibleBusinessBotMessageIdValue = visibleBusinessBotMessageId {
                            if visibleBusinessBotMessageIdValue < message.id {
                                visibleBusinessBotMessageId = message.id
                            }
                        } else {
                            visibleBusinessBotMessageId = message.id
                        }
                    }
                    switch message.id.peerId.namespace {
                    case Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:
                        messageIdsWithPossibleReactions.append(message.id)
                    default:
                        break
                    }
                case let .MessageGroupEntry(_, messages, _):
                    for (message, _, _, _, _) in messages {
                        if let _ = message.inlineBotAttribute {
                            if let visibleBusinessBotMessageIdValue = visibleBusinessBotMessageId {
                                if visibleBusinessBotMessageIdValue < message.id {
                                    visibleBusinessBotMessageId = message.id
                                }
                            } else {
                                visibleBusinessBotMessageId = message.id
                            }
                        }
                        switch message.id.peerId.namespace {
                        case Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:
                            messageIdsWithPossibleReactions.append(message.id)
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
            
            func addMediaToPrefetch(_ message: Message, _ media: Media, _ messages: inout [(Message, Media)]) -> Bool {
                if media is TelegramMediaImage || media is TelegramMediaFile {
                    messages.append((message, media))
                }
                if messages.count >= 3 {
                    return false
                } else {
                    return true
                }
            }
            
            var toEarlierMediaMessages: [(Message, Media)] = []
            if toEarlierRange.0 <= toEarlierRange.1 {
                outer: for i in (toEarlierRange.0 ... toEarlierRange.1).reversed() {
                    switch historyView.filteredEntries[i] {
                    case let .MessageEntry(message, _, _, _, _, _):
                        for media in message.media {
                            if !addMediaToPrefetch(message, media, &toEarlierMediaMessages) {
                                break outer
                            }
                        }
                    case let .MessageGroupEntry(_, messages, _):
                        for (message, _, _, _, _) in messages {
                            var stop = false
                            for media in message.media {
                                if !addMediaToPrefetch(message, media, &toEarlierMediaMessages) {
                                    stop = true
                                }
                            }
                            if stop {
                                break outer
                            }
                        }
                    default:
                        break
                    }
                }
            }
            
            var toLaterMediaMessages: [(Message, Media)] = []
            if toLaterRange.0 <= toLaterRange.1 {
                outer: for i in (toLaterRange.0 ... toLaterRange.1) {
                    switch historyView.filteredEntries[i] {
                    case let .MessageEntry(message, _, _, _, _, _):
                        for media in message.media {
                            if !addMediaToPrefetch(message, media, &toLaterMediaMessages) {
                                break outer
                            }
                        }
                    case let .MessageGroupEntry(_, messages, _):
                        for (message, _, _, _, _) in messages {
                            for media in message.media {
                                if !addMediaToPrefetch(message, media, &toLaterMediaMessages) {
                                    break outer
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }
            
            if !messageIdsWithViewCount.isEmpty {
                self.messageProcessingManager.add(messageIdsWithViewCount.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !messageIdsWithLiveLocation.isEmpty {
                self.seenLiveLocationProcessingManager.add(messageIdsWithLiveLocation.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !messageIdsWithUnsupportedMedia.isEmpty {
                self.unsupportedMessageProcessingManager.add(messageIdsWithUnsupportedMedia)
            }
            if !messageIdsWithRefreshMedia.isEmpty {
                self.refreshMediaProcessingManager.add(messageIdsWithRefreshMedia.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !messageIdsWithRefreshStories.isEmpty {
                self.refreshStoriesProcessingManager.add(messageIdsWithRefreshStories.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !messageIdsWithUnseenPersonalMention.isEmpty {
                self.messageMentionProcessingManager.add(messageIdsWithUnseenPersonalMention.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !messageIdsWithUnseenReactions.isEmpty {
                self.unseenReactionsProcessingManager.add(messageIdsWithUnseenReactions.map { MessageAndThreadId(messageId: $0, threadId: nil) })
                
                if self.canReadHistoryValue && !self.context.sharedContext.immediateExperimentalUISettings.skipReadHistory {
                    let _ = self.displayUnseenReactionAnimations(messageIds: messageIdsWithUnseenReactions)
                }
            }
            if !messageIdsWithPossibleReactions.isEmpty {
                self.messageWithReactionsProcessingManager.add(messageIdsWithPossibleReactions.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !downloadableResourceIds.isEmpty {
                let _ = markRecentDownloadItemsAsSeen(postbox: self.context.account.postbox, items: downloadableResourceIds).startStandalone()
            }
            if !messageIdsWithInactiveExtendedMedia.isEmpty {
                self.extendedMediaProcessingManager.update(Set(messageIdsWithInactiveExtendedMedia.map { MessageAndThreadId(messageId: $0, threadId: nil) }))
            }
            if !messageIdsToTranslate.isEmpty {
                self.translationProcessingManager.add(messageIdsToTranslate.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !messageIdsToFactCheck.isEmpty {
                self.factCheckProcessingManager.add(messageIdsToFactCheck.map { MessageAndThreadId(messageId: $0, threadId: nil) })
            }
            if !visibleAdOpaqueIds.isEmpty {
                for opaqueId in visibleAdOpaqueIds {
                    self.markAdAsSeen(opaqueId: opaqueId)
                }
            }
            if !peerIdsWithRefreshStories.isEmpty {
                self.context.account.viewTracker.refreshStoryStatsForPeerIds(peerIds: peerIdsWithRefreshStories)
            }
            
            self.currentEarlierPrefetchMessages = toEarlierMediaMessages
            self.currentLaterPrefetchMessages = toLaterMediaMessages
            if self.currentPrefetchDirectionIsToLater {
                self.prefetchManager.updateMessages(toLaterMediaMessages, directionIsToLater: self.currentPrefetchDirectionIsToLater)
            } else {
                self.prefetchManager.updateMessages(toEarlierMediaMessages, directionIsToLater: self.currentPrefetchDirectionIsToLater)
            }
            
            if readIndexRange.0 <= readIndexRange.1 {
                let (maxIncomingIndex, maxOverallIndex) = maxMessageIndexForEntries(historyView, indexRange: readIndexRange)
                
                let messageIndex: MessageIndex?
                switch self.chatLocation {
                case .peer:
                    messageIndex = maxIncomingIndex
                case .replyThread, .customChatContents:
                    messageIndex = maxOverallIndex
                }
                
                if let messageIndex = messageIndex {
                    let _ = messageIndex
                    //self.updateMaxVisibleReadIncomingMessageIndex(messageIndex)
                }
                
                if let maxOverallIndex = maxOverallIndex, maxOverallIndex != self.maxVisibleMessageIndexReported {
                    self.maxVisibleMessageIndexReported = maxOverallIndex
                    self.maxVisibleMessageIndexUpdated?(maxOverallIndex)
                }
            }
            
            if let visible = displayedRange.visibleRange {
                let indexRange = (historyView.filteredEntries.count - 1 - visible.lastIndex, historyView.filteredEntries.count - 1 - visible.firstIndex)
                if indexRange.0 <= indexRange.1 {
                    for (messageId, nodeIndex) in allVisibleAnchorMessageIds {
                        guard let itemNode = self.itemNodeAtIndex(nodeIndex) else {
                            continue
                        }
                        //TODO:loc optimize eviction
                        if self.seenMessageIds.insert(messageId).inserted, let remainingDynamicAdMessageIntervalValue = self.remainingDynamicAdMessageInterval, let remainingDynamicAdMessageDistanceValue = self.remainingDynamicAdMessageDistance {
                            let itemHeight = itemNode.bounds.height
                            
                            let remainingDynamicAdMessageInterval = remainingDynamicAdMessageIntervalValue - 1
                            let remainingDynamicAdMessageDistance = remainingDynamicAdMessageDistanceValue - itemHeight
                            if remainingDynamicAdMessageInterval <= 0 && remainingDynamicAdMessageDistance <= 0.0 {
                                self.remainingDynamicAdMessageInterval = self.pendingDynamicAdMessageInterval
                                self.remainingDynamicAdMessageDistance = self.bounds.height
                                self.maybeInsertPendingAdMessage(historyView: historyView, toLaterRange: toLaterRange, toEarlierRange: toEarlierRange)
                            } else {
                                self.remainingDynamicAdMessageInterval = remainingDynamicAdMessageInterval
                                self.remainingDynamicAdMessageDistance = remainingDynamicAdMessageDistance
                            }
                        }
                    }
                }
            }
            
            if let visibleBusinessBotMessageId, !self.hasDisplayedBusinessBotMessageTooltip {
                var foundItemNode: ChatMessageItemView?
                self.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item, item.message.id == visibleBusinessBotMessageId {
                        foundItemNode = itemNode
                    }
                }
                
                if let foundItemNode {
                    self.hasDisplayedBusinessBotMessageTooltip = true
                    
                    if let controllerNode = self.controllerInteraction.chatControllerNode() as? ChatControllerNode, let chatController = controllerNode.interfaceInteraction?.chatController() as? ChatControllerImpl {
                        chatController.displayBusinessBotMessageTooltip(itemNode: foundItemNode)
                    }
                }
            }
        }
        
        if !self.isSettingTopReplyThreadMessageShown {
            self.isSettingTopReplyThreadMessageShown = true
            self.isTopReplyThreadMessageShown.set(isTopReplyThreadMessageShownValue)
            self.isSettingTopReplyThreadMessageShown = false
        } else {
            #if DEBUG
            print("Ignore repeated isTopReplyThreadMessageShown update")
            #endif
        }
        self.updateTopVisibleMessageRange(topVisibleMessageRange)
        let _ = self.visibleMessageRange.swap(topVisibleMessageRange.flatMap { range in
            return VisibleMessageRange(lowerBound: range.lowerBound, upperBound: range.upperBound)
        })
        
        if let loaded = displayedRange.visibleRange, let firstEntry = historyView.filteredEntries.first, let lastEntry = historyView.filteredEntries.last {
            var mathesFirst = false
            if loaded.firstIndex <= 5 {
                var firstHasGroups = false
                for index in (max(0, historyView.filteredEntries.count - 5) ..< historyView.filteredEntries.count).reversed() {
                    switch historyView.filteredEntries[index] {
                    case .MessageEntry:
                        break
                    case .MessageGroupEntry:
                        firstHasGroups = true
                    default:
                        break
                    }
                }
                if firstHasGroups {
                    mathesFirst = loaded.firstIndex <= 1
                } else {
                    mathesFirst = loaded.firstIndex <= 5
                }
            }
            
            var mathesLast = false
            if loaded.lastIndex >= historyView.filteredEntries.count - 5 {
                var lastHasGroups = false
                for index in 0 ..< min(5, historyView.filteredEntries.count) {
                    switch historyView.filteredEntries[index] {
                    case .MessageEntry:
                        break
                    case .MessageGroupEntry:
                        lastHasGroups = true
                    default:
                        break
                    }
                }
                if lastHasGroups {
                    mathesLast = loaded.lastIndex >= historyView.filteredEntries.count - 1
                } else {
                    mathesLast = loaded.lastIndex >= historyView.filteredEntries.count - 5
                }
            }
            
            if mathesFirst && historyView.originalView.laterId != nil {
                let locationInput: ChatHistoryLocation = .Navigation(index: .message(lastEntry.index), anchorIndex: .message(lastEntry.index), count: historyMessageCount, highlight: false)
                if self.chatHistoryLocationValue?.content != locationInput {
                    self.chatHistoryLocationValue = ChatHistoryLocationInput(content: locationInput, id: self.takeNextHistoryLocationId())
                }
            } else if mathesFirst, historyView.originalView.laterId == nil, !historyView.originalView.holeLater, let chatHistoryLocationValue = self.chatHistoryLocationValue, !chatHistoryLocationValue.isAtUpperBound, historyView.originalView.anchorIndex != .upperBound {
                if self.chatHistoryLocationValue == historyView.locationInput {
                    self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Navigation(index: .upperBound, anchorIndex: .upperBound, count: historyMessageCount, highlight: false), id: self.takeNextHistoryLocationId())
                }
            } else if mathesLast {
                let locationInput: ChatHistoryLocation = .Navigation(index: .message(firstEntry.index), anchorIndex: .message(firstEntry.index), count: historyMessageCount, highlight: false)
                if historyView.originalView.earlierId != nil {
                    if self.chatHistoryLocationValue?.content != locationInput {
                        self.chatHistoryLocationValue = ChatHistoryLocationInput(content: locationInput, id: self.takeNextHistoryLocationId())
                    }
                } else if case let .customChatContents(customChatContents) = self.subject, case .hashTagSearch = customChatContents.kind {
                    if self.chatHistoryLocationValue?.content != locationInput {
                        self.chatHistoryLocationValue = ChatHistoryLocationInput(content: locationInput, id: self.takeNextHistoryLocationId())
                        customChatContents.loadMore()
                    }
                }
            }
        }
        
        var containsPlayableWithSoundItemNode = false
        self.forEachVisibleItemNode { itemNode in
            if let chatItemView = itemNode as? ChatMessageItemView, chatItemView.playMediaWithSound() != nil {
                containsPlayableWithSoundItemNode = true
            }
        }
        self.hasVisiblePlayableItemNodesPromise.set(containsPlayableWithSoundItemNode)
        
        if containsPlayableWithSoundItemNode && !self.isInteractivelyScrollingValue {
            self.isInteractivelyScrollingPromise.set(true)
            self.isInteractivelyScrollingPromise.set(false)
        }
    }
    
    public func scrollScreenToTop() {
        if let subject = self.subject, case .scheduledMessages = subject {
            if let historyView = self.historyView {
                if let entry = historyView.filteredEntries.first {
                    var currentMessage: Message?
                    if case let .MessageEntry(message, _, _, _, _, _) = entry {
                        currentMessage = message
                    } else if case let .MessageGroupEntry(_, messages, _) = entry {
                        currentMessage = messages.first?.0
                    }
                    if let message = currentMessage, let _ = self.anchorMessageInCurrentHistoryView() {
                        self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Scroll(subject: MessageHistoryScrollToSubject(index: .message(message.index), quote: nil), anchorIndex: .message(message.index), sourceIndex: .upperBound, scrollPosition: .bottom(0.0), animated: true, highlight: false, setupReply: false), id: self.takeNextHistoryLocationId())
                    }
                }
            }
        } else {
            var currentMessage: Message?
            if let historyView = self.historyView {
                if let visibleRange = self.displayedItemRange.loadedRange {
                    var index = historyView.filteredEntries.count - 1
                    loop: for entry in historyView.filteredEntries {
                        let isVisible = index >= visibleRange.firstIndex && index <= visibleRange.lastIndex
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            if !isVisible || currentMessage == nil {
                                currentMessage = message
                            }
                        } else if case let .MessageGroupEntry(_, messages, _) = entry {
                            if !isVisible || currentMessage == nil {
                                currentMessage = messages.first?.0
                            }
                        }
                        if isVisible {
                            break loop
                        }
                        index -= 1
                    }
                }
            }
            
            if let currentMessage = currentMessage {
                self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Scroll(subject: MessageHistoryScrollToSubject(index: .message(currentMessage.index), quote: nil), anchorIndex: .message(currentMessage.index), sourceIndex: .upperBound, scrollPosition: .top(0.0), animated: true, highlight: true, setupReply: false), id: self.takeNextHistoryLocationId())
            }
        }
    }
    
    public func scrollToStartOfHistory() {
        self.beganDragging?()
        self.pendingMessageNavigationAlignment = nil
        self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Scroll(subject: MessageHistoryScrollToSubject(index: .lowerBound, quote: nil), anchorIndex: .lowerBound, sourceIndex: .upperBound, scrollPosition: .bottom(0.0), animated: true, highlight: false, setupReply: false), id: self.takeNextHistoryLocationId())
    }
    
    public func scrollToEndOfHistory() {
        self.beganDragging?()
        self.pendingMessageNavigationAlignment = nil
        switch self.visibleContentOffset() {
            case let .known(value) where value <= CGFloat.ulpOfOne:
                break
            default:
                let locationInput = ChatHistoryLocationInput(content: .Scroll(subject: MessageHistoryScrollToSubject(index: .upperBound, quote: nil), anchorIndex: .upperBound, sourceIndex: .lowerBound, scrollPosition: .top(0.0), animated: true, highlight: false, setupReply: false), id: self.takeNextHistoryLocationId())
                self.chatHistoryLocationValue = locationInput
        }
    }
    
    public func scrollToMessage(from fromIndex: MessageIndex, to toIndex: MessageIndex, animated: Bool, highlight: Bool = true, quote: (string: String, offset: Int?)? = nil, todoTaskId: Int32? = nil, scrollPosition: ListViewScrollPosition = .center(.bottom), setupReply: Bool = false) {
        if case .center = scrollPosition, quote == nil, todoTaskId == nil, !setupReply {
            let directionHint: ListViewScrollToItemDirectionHint = toIndex >= fromIndex ? .Down : .Up
            self.pendingMessageNavigationAlignment = PendingMessageNavigationAlignment(messageId: toIndex.id, directionHint: directionHint, remainingPasses: 2)
        } else {
            self.pendingMessageNavigationAlignment = nil
        }
        self.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Scroll(subject: MessageHistoryScrollToSubject(index: .message(toIndex), quote: quote.flatMap { quote in MessageHistoryScrollToSubject.Quote(string: quote.string, offset: quote.offset) }, todoTaskId: todoTaskId, setupReply: setupReply), anchorIndex: .message(toIndex), sourceIndex: .message(fromIndex), scrollPosition: scrollPosition, animated: animated, highlight: highlight, setupReply: setupReply), id: self.takeNextHistoryLocationId())
    }

    private func messageNavigationAlignmentTarget() -> (index: Int, itemNode: ChatMessageItemView)? {
        guard let pendingMessageNavigationAlignment = self.pendingMessageNavigationAlignment else {
            return nil
        }
        var target: (index: Int, itemNode: ChatMessageItemView)?
        self.forEachItemNode { itemNode in
            guard target == nil,
                  let itemNode = itemNode as? ChatMessageItemView,
                  let index = itemNode.index,
                  itemNode.item?.content.firstMessage.id == pendingMessageNavigationAlignment.messageId else {
                return
            }
            target = (index, itemNode)
        }
        return target
    }

    private func maybeApplyPendingMessageNavigationAlignment() {
        guard !self.isApplyingPendingMessageNavigationAlignment,
              var pendingMessageNavigationAlignment = self.pendingMessageNavigationAlignment else {
            return
        }
        guard pendingMessageNavigationAlignment.remainingPasses > 0 else {
            self.pendingMessageNavigationAlignment = nil
            return
        }
        guard let target = self.messageNavigationAlignmentTarget() else {
            return
        }
        
        let visibleCenterY = self.insets.top + floor((self.visibleSize.height - self.insets.bottom - self.insets.top) * 0.5)
        let anchorY = target.itemNode.navigationTopAnchorForScrolling()
        let currentAnchorY = target.itemNode.apparentFrame.minY + anchorY
        guard abs(currentAnchorY - visibleCenterY) > 1.0 else {
            self.pendingMessageNavigationAlignment = nil
            return
        }
        
        pendingMessageNavigationAlignment.remainingPasses -= 1
        self.pendingMessageNavigationAlignment = pendingMessageNavigationAlignment.remainingPasses > 0 ? pendingMessageNavigationAlignment : nil
        
        let additionalOffset = visibleCenterY - self.insets.top - target.itemNode.scrollPositioningInsets.top - anchorY
        let scrollToItem = ListViewScrollToItem(
            index: target.index,
            position: .top(additionalOffset),
            animated: false,
            curve: .Default(duration: nil),
            directionHint: pendingMessageNavigationAlignment.directionHint
        )
        
        self.isApplyingPendingMessageNavigationAlignment = true
        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: scrollToItem, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { [weak self] _ in
            guard let self else {
                return
            }
            self.isApplyingPendingMessageNavigationAlignment = false
            if let target = self.messageNavigationAlignmentTarget() {
                let updatedAnchorY = target.itemNode.apparentFrame.minY + target.itemNode.navigationTopAnchorForScrolling()
                if abs(updatedAnchorY - visibleCenterY) <= 1.0 {
                    self.pendingMessageNavigationAlignment = nil
                }
            }
        })
    }
    
    public func anchorMessageInCurrentHistoryView() -> Message? {
        if let historyView = self.historyView {
            if let visibleRange = self.displayedItemRange.visibleRange {
                var index = 0
                for entry in historyView.filteredEntries.reversed() {
                    if index >= visibleRange.firstIndex && index <= visibleRange.lastIndex {
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            return message
                        }
                    }
                    index += 1
                }
            }
            
            for case let .MessageEntry(message, _, _, _, _, _) in historyView.filteredEntries {
                return message
            }
        }
        return nil
    }
    
    public func isMessageVisibleOnScreen(_ id: MessageId) -> Bool {
        var result = false
        self.forEachItemNode({ itemNode in
            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item, item.content.contains(where: { $0.0.id == id }) {
                if self.itemNodeVisibleInsideInsets(itemNode) {
                    result = true
                }
            }
        })
        return result
    }
    
    public func forEachVisibleMessageItemNode(_ f: (ChatMessageItemView) -> Void) {
        self.forEachVisibleItemNode { itemNode in
            if let itemNode = itemNode as? ChatMessageItemView {
                f(itemNode)
            }
        }
    }
    
    public func latestMessageInCurrentHistoryView() -> Message? {
        if let historyView = self.historyView {
            if historyView.originalView.laterId == nil, let firstEntry = historyView.filteredEntries.last {
                if case let .MessageEntry(message, _, _, _, _, _) = firstEntry {
                    return message
                }
            }
        }
        return nil
    }
    
    public func firstMessageForEditInCurrentHistoryView() -> Message? {
        if let historyView = self.historyView {
            if historyView.originalView.laterId == nil {
                for entry in historyView.filteredEntries.reversed()  {
                    if case let .MessageEntry(message, _, _, _, _, _) = entry {
                        if canEditMessage(context: context, limitsConfiguration: context.currentLimitsConfiguration.with { EngineConfiguration.Limits($0) }, message: message) {
                            return message
                        }
                    }
                }
            }
        }
        return nil
    }
    
    public func messageInCurrentHistoryView(after messageId: MessageId) -> Message? {
        if let historyView = self.historyView {
            if let index = historyView.filteredEntries.firstIndex(where: { $0.firstIndex.id == messageId }), index < historyView.filteredEntries.count - 1 {
                let nextEntry = historyView.filteredEntries[index + 1]
                if case let .MessageEntry(message, _, _, _, _, _) = nextEntry {
                    return message
                } else if case let .MessageGroupEntry(_, messages, _) = nextEntry, let firstMessage = messages.first {
                    return firstMessage.0
                }
            }
        }
        return nil
    }
    
    public func messageInCurrentHistoryView(before messageId: MessageId) -> Message? {
        if let historyView = self.historyView {
            if let index = historyView.filteredEntries.firstIndex(where: { $0.firstIndex.id == messageId }), index > 0 {
                let nextEntry = historyView.filteredEntries[index - 1]
                if case let .MessageEntry(message, _, _, _, _, _) = nextEntry {
                    return message
                } else if case let .MessageGroupEntry(_, messages, _) = nextEntry, let firstMessage = messages.first {
                    return firstMessage.0
                }
            }
        }
        return nil
    }
    
    public func messageInCurrentHistoryView(_ id: MessageId) -> Message? {
        if let historyView = self.historyView {
            for entry in historyView.filteredEntries {
                if case let .MessageEntry(message, _, _, _, _, _) = entry {
                    if message.id == id {
                        return message
                    }
                } else if case let .MessageGroupEntry(_, messages, _) = entry {
                    for (message, _, _, _, _) in messages {
                        if message.id == id {
                            return message
                        }
                    }
                }
            }
        }
        return nil
    }
    
    public func messageGroupInCurrentHistoryView(_ id: MessageId) -> [Message]? {
        if let historyView = self.historyView {
            for entry in historyView.filteredEntries {
                if case let .MessageEntry(message, _, _, _, _, _) = entry {
                    if message.id == id {
                        return [message]
                    }
                } else if case let .MessageGroupEntry(_, messages, _) = entry {
                    for (message, _, _, _, _) in messages {
                        if message.id == id {
                            return messages.map { $0.0 }
                        }
                    }
                }
            }
        }
        return nil
    }
    
    public func forEachMessageInCurrentHistoryView(_ f: (Message) -> Bool) {
        if let historyView = self.historyView {
            for entry in historyView.filteredEntries {
                if case let .MessageEntry(message, _, _, _, _, _) = entry {
                    if !f(message) {
                        return
                    }
                } else if case let .MessageGroupEntry(_, messages, _) = entry {
                    for (message, _, _, _, _) in messages {
                        if !f(message) {
                            return
                        }
                    }
                }
            }
        }
    }
    
    private func updateMaxVisibleReadIncomingMessageIndex(_ index: MessageIndex) {
        self.maxVisibleIncomingMessageIndex.set(index)
    }
    
    private func enqueueHistoryViewTransition(_ transition: ChatHistoryListViewTransition) {
        self.enqueuedHistoryViewTransitions.append(transition)
        self.prefetchManager.updateOptions(InChatPrefetchOptions(networkType: transition.networkType, peerType: transition.peerType))
                
        if !self.didSetInitialData {
            self.didSetInitialData = true
            self._initialData.set(.single(ChatHistoryCombinedInitialData(initialData: transition.initialData, buttonKeyboardMessage: transition.keyboardButtonsMessage, cachedData: transition.cachedData, cachedDataMessages: transition.cachedDataMessages, readStateData: transition.readStateData)))
        }
                
        if self.isNodeLoaded {
            self.dequeueHistoryViewTransitions()
        } else {
            self._cachedPeerDataAndMessages.set(.single((transition.cachedData, transition.cachedDataMessages)))
            
            let loadState: ChatHistoryNodeLoadState
            if transition.historyView.filteredEntries.isEmpty {
                if let firstEntry = transition.historyView.originalView.entries.first {
                    var isPeerJoined = false
                    for media in firstEntry.message.media {
                        if let action = media as? TelegramMediaAction, action.action == .peerJoined {
                            isPeerJoined = true
                            break
                        }
                    }
                    loadState = .empty(isPeerJoined ? .joined : .generic)
                } else {
                    loadState = .empty(.generic)
                }
            } else {
                if transition.historyView.filteredEntries.count == 1, let entry = transition.historyView.filteredEntries.first, case .ChatInfoEntry = entry {
                    loadState = .empty(.botInfo)
                } else {
                    loadState = .messages
                }
            }
            if self.loadState != loadState {
                self.loadState = loadState
                self.loadStateUpdated?(loadState, transition.options.contains(.AnimateInsertion))
                for f in self.additionalLoadStateUpdated {
                    f(loadState, transition.options.contains(.AnimateInsertion))
                }
            }
            
            let isEmpty = transition.historyView.originalView.entries.isEmpty || loadState == .empty(.botInfo)
            
            var hasReachedLimits = false
            if case let .customChatContents(customChatContents) = self.subject, let messageLimit = customChatContents.messageLimit {
                hasReachedLimits = transition.historyView.originalView.entries.count >= messageLimit
            }
            
            let historyState: ChatHistoryNodeHistoryState = .loaded(isEmpty: isEmpty, hasReachedLimits: hasReachedLimits)
            if self.currentHistoryState != historyState {
                self.currentHistoryState = historyState
                self.historyState.set(historyState)
            }
        }
    }
    
    private func dequeueHistoryViewTransitions() {
        if self.enqueuedHistoryViewTransitions.isEmpty || self.hasActiveTransition {
            return
        }
        self.hasActiveTransition = true
        let transition = self.enqueuedHistoryViewTransitions.removeFirst()
        
        var expiredMessageStableIds = Set<UInt32>()
        if let previousHistoryView = self.historyView, transition.options.contains(.AnimateInsertion) {
            var existingStableIds = Set<UInt32>()
            for entry in transition.historyView.filteredEntries {
                switch entry {
                case let .MessageEntry(message, _, _, _, _, _):
                    existingStableIds.insert(message.stableId)
                case let .MessageGroupEntry(_, messages, _):
                    for message in messages {
                        existingStableIds.insert(message.0.stableId)
                    }
                default:
                    break
                }
            }
            let currentTimestamp = Int32(CFAbsoluteTimeGetCurrent())
            var maybeRemovedInteractivelyMessageIds: [(UInt32, EngineMessage.Id)] = []
            for entry in previousHistoryView.filteredEntries {
                switch entry {
                case let .MessageEntry(message, _, _, _, _, _):
                    if !existingStableIds.contains(message.stableId) {
                        if let autoremoveAttribute = message.autoremoveAttribute, let countdownBeginTime = autoremoveAttribute.countdownBeginTime {
                            let exipiresAt = countdownBeginTime + autoremoveAttribute.timeout
                            if exipiresAt >= currentTimestamp - 1 {
                                expiredMessageStableIds.insert(message.stableId)
                            }
                        } else {
                            maybeRemovedInteractivelyMessageIds.append((message.stableId, message.id))
                        }
                    }
                case let .MessageGroupEntry(_, messages, _):
                    var isRemoved = true
                    inner: for message in messages {
                        if existingStableIds.contains(message.0.stableId) {
                            isRemoved = false
                            break inner
                        }
                    }
                    if isRemoved, let message = messages.first?.0 {
                        if let autoremoveAttribute = message.autoremoveAttribute, let countdownBeginTime = autoremoveAttribute.countdownBeginTime {
                            let exipiresAt = countdownBeginTime + autoremoveAttribute.timeout
                            if exipiresAt >= currentTimestamp - 1 {
                                expiredMessageStableIds.insert(message.stableId)
                            }
                        } else {
                            maybeRemovedInteractivelyMessageIds.append((message.stableId, message.id))
                        }
                    }
                default:
                    break
                }
            }
            
            var testIds: [MessageId] = []
            if !maybeRemovedInteractivelyMessageIds.isEmpty {
                for (_, id) in maybeRemovedInteractivelyMessageIds {
                    testIds.append(id)
                }
            }
            for id in self.context.engine.messages.synchronouslyIsMessageDeletedInteractively(ids: testIds) {
                if id.namespace == Namespaces.Message.ScheduledCloud {
                    continue
                }
                inner: for (stableId, listId) in maybeRemovedInteractivelyMessageIds {
                    if listId == id {
                        expiredMessageStableIds.insert(stableId)
                        break inner
                    }
                }
            }
            for id in self.ignoreMessageIds {
                inner: for (stableId, listId) in maybeRemovedInteractivelyMessageIds {
                    if listId == id {
                        expiredMessageStableIds.insert(stableId)
                        break inner
                    }
                }
            }
        }
        self.currentDeleteAnimationCorrelationIds.formUnion(expiredMessageStableIds)
        
        var appliedDeleteAnimationCorrelationIds = Set<UInt32>()
        if !self.currentDeleteAnimationCorrelationIds.isEmpty && self.allowDustEffect {
            var foundItemNodes: [ChatMessageItemView] = []
            self.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                    for (message, _) in item.content {
                        if let itemNode = itemNode as? ChatMessageBubbleItemNode {
                            if itemNode.isServiceLikeMessage() {
                                continue
                            }
                        }
                        
                        if self.currentDeleteAnimationCorrelationIds.contains(message.stableId) {
                            appliedDeleteAnimationCorrelationIds.insert(message.stableId)
                            self.currentDeleteAnimationCorrelationIds.remove(message.stableId)
                            foundItemNodes.append(itemNode)
                        }
                    }
                }
            }
            if !foundItemNodes.isEmpty {
                if self.dustEffectLayer == nil {
                    let dustEffectLayer = DustEffectLayer()
                    dustEffectLayer.position = self.bounds.center
                    dustEffectLayer.bounds = CGRect(origin: CGPoint(), size: self.bounds.size)
                    self.dustEffectLayer = dustEffectLayer
                    dustEffectLayer.zPosition = 10.0
                    if self.rotated {
                        dustEffectLayer.transform = CATransform3DMakeRotation(CGFloat(Double.pi), 0.0, 0.0, 1.0)
                    }
                    self.layer.addSublayer(dustEffectLayer)
                    dustEffectLayer.becameEmpty = { [weak self] in
                        guard let self else {
                            return
                        }
                        self.dustEffectLayer?.removeFromSuperlayer()
                        self.dustEffectLayer = nil
                    }
                }
                if let dustEffectLayer = self.dustEffectLayer {
                    for itemNode in foundItemNodes {
                        guard let (image, subFrame) = itemNode.makeContentSnapshot() else {
                            continue
                        }
                        let itemFrame = itemNode.layer.convert(subFrame, to: dustEffectLayer)
                        dustEffectLayer.addItem(frame: itemFrame, image: image)
                        itemNode.isHidden = true
                    }
                }
            }
        }
        
        self.currentAppliedDeleteAnimationCorrelationIds = appliedDeleteAnimationCorrelationIds
        
        let animated = transition.options.contains(.AnimateInsertion)
        
        var previousCloneView: UIView?
        if transition.animateFromPreviousFilter, !"".isEmpty {
            previousCloneView = self.view.snapshotView(afterScreenUpdates: false)
        }

        let completion: (Bool, ListViewDisplayedItemRange) -> Void = { [weak self] wasTransformed, visibleRange in
            if let strongSelf = self {
                strongSelf.currentAppliedDeleteAnimationCorrelationIds.removeAll()
                
                var newIncomingReactions: [MessageId: (value: MessageReaction.Reaction, isLarge: Bool)] = [:]
                
                if case .peer = strongSelf.chatLocation, let previousHistoryView = strongSelf.historyView {
                    var updatedIncomingReactions: [MessageId: (value: MessageReaction.Reaction, isLarge: Bool)] = [:]
                    for entry in transition.historyView.filteredEntries {
                        switch entry {
                        case let .MessageEntry(message, _, _, _, _, _):
                            if message.flags.contains(.Incoming) {
                                continue
                            }
                            if let reactions = message.reactionsAttribute {
                                for recentPeer in reactions.recentPeers {
                                    if recentPeer.isUnseen {
                                        updatedIncomingReactions[message.id] = (recentPeer.value, recentPeer.isLarge)
                                    }
                                }
                            }
                        case let .MessageGroupEntry(_, messages, _):
                            for message in messages {
                                if message.0.flags.contains(.Incoming) {
                                    continue
                                }
                                if let reactions = message.0.reactionsAttribute {
                                    for recentPeer in reactions.recentPeers {
                                        if recentPeer.isUnseen {
                                            updatedIncomingReactions[message.0.id] = (recentPeer.value, recentPeer.isLarge)
                                        }
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }
                    for entry in previousHistoryView.filteredEntries {
                        switch entry {
                        case let .MessageEntry(message, _, _, _, _, _):
                            if let updatedReaction = updatedIncomingReactions[message.id] {
                                var previousReaction: MessageReaction.Reaction?
                                if let reactions = message.reactionsAttribute {
                                    for recentPeer in reactions.recentPeers {
                                        if recentPeer.isUnseen {
                                            previousReaction = recentPeer.value
                                        }
                                    }
                                }
                                if previousReaction != updatedReaction.value {
                                    newIncomingReactions[message.id] = updatedReaction
                                }
                            }
                        case let .MessageGroupEntry(_, messages, _):
                            for message in messages {
                                if let updatedReaction = updatedIncomingReactions[message.0.id] {
                                    var previousReaction: MessageReaction.Reaction?
                                    if let reactions = message.0.reactionsAttribute {
                                        for recentPeer in reactions.recentPeers {
                                            if recentPeer.isUnseen {
                                                previousReaction = recentPeer.value
                                            }
                                        }
                                    }
                                    if previousReaction != updatedReaction.value {
                                        newIncomingReactions[message.0.id] = updatedReaction
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }
                }
                
                var unreadMessageRangeUpdated = false
                
                if case let .peer(peerId) = strongSelf.chatLocation, let previousReadStatesValue = strongSelf.historyView?.originalView.transientReadStates, case let .peer(previousReadStates) = previousReadStatesValue, case let .peer(updatedReadStates) = transition.historyView.originalView.transientReadStates {
                    if let previousPeerReadState = previousReadStates[peerId], let updatedPeerReadState = updatedReadStates[peerId] {
                        if previousPeerReadState != updatedPeerReadState {
                            for (namespace, state) in previousPeerReadState.states {
                                inner: for (updatedNamespace, updatedState) in updatedPeerReadState.states {
                                    if namespace == updatedNamespace {
                                        switch state {
                                        case let .idBased(previousIncomingId, _, _, _, _):
                                            if case let .idBased(updatedIncomingId, _, _, _, _) = updatedState, previousIncomingId <= updatedIncomingId {
                                                let rangeKey = UnreadMessageRangeKey(peerId: peerId, namespace: namespace)
                                                
                                                if let currentRange = strongSelf.controllerInteraction.unreadMessageRange[rangeKey] {
                                                    if currentRange.upperBound < (updatedIncomingId + 1) {
                                                        let updatedRange = currentRange.lowerBound ..< (updatedIncomingId + 1)
                                                        if strongSelf.controllerInteraction.unreadMessageRange[rangeKey] != updatedRange {
                                                            strongSelf.controllerInteraction.unreadMessageRange[rangeKey] = updatedRange
                                                            unreadMessageRangeUpdated = true
                                                        }
                                                    }
                                                } else {
                                                    let updatedRange = (previousIncomingId + 1) ..< (updatedIncomingId + 1)
                                                    if strongSelf.controllerInteraction.unreadMessageRange[rangeKey] != updatedRange {
                                                        strongSelf.controllerInteraction.unreadMessageRange[rangeKey] = updatedRange
                                                        unreadMessageRangeUpdated = true
                                                    }
                                                }
                                            }
                                        case .indexBased:
                                            break
                                        }
                                        
                                        break inner
                                    }
                                }
                            }
                            //print("Read from \(previousPeerReadState) up to \(updatedPeerReadState)")
                        }
                    }
                } else if case let .peer(peerId) = strongSelf.chatLocation, case let .peer(updatedReadStates) = transition.historyView.originalView.transientReadStates {
                    if let updatedPeerReadState = updatedReadStates[peerId] {
                        for (namespace, updatedState) in updatedPeerReadState.states {
                            switch updatedState {
                            case let .idBased(updatedIncomingId, _, _, _, _):
                                let rangeKey = UnreadMessageRangeKey(peerId: peerId, namespace: namespace)
                                
                                if let currentRange = strongSelf.controllerInteraction.unreadMessageRange[rangeKey] {
                                    if currentRange.upperBound < (updatedIncomingId + 1) {
                                        let updatedRange = currentRange.lowerBound ..< (updatedIncomingId + 1)
                                        if strongSelf.controllerInteraction.unreadMessageRange[rangeKey] != updatedRange {
                                            strongSelf.controllerInteraction.unreadMessageRange[rangeKey] = updatedRange
                                            unreadMessageRangeUpdated = true
                                        }
                                    }
                                } else {
                                    let updatedRange = (updatedIncomingId + 1) ..< (Int32.max - 1)
                                    if strongSelf.controllerInteraction.unreadMessageRange[rangeKey] != updatedRange {
                                        strongSelf.controllerInteraction.unreadMessageRange[rangeKey] = updatedRange
                                        unreadMessageRangeUpdated = true
                                    }
                                }
                            case .indexBased:
                                break
                            }
                        }
                    }
                }
                
                strongSelf.historyView = transition.historyView
                
                let loadState: ChatHistoryNodeLoadState
                var alwaysHasMessages = false
                if case .custom = strongSelf.source {
                    if case .customChatContents = strongSelf.chatLocation {
                    } else {
                        alwaysHasMessages = true
                    }
                }
                if alwaysHasMessages {
                    loadState = .messages
                } else if let historyView = strongSelf.historyView {
                    if historyView.filteredEntries.isEmpty {
                        if let firstEntry = historyView.originalView.entries.first {
                            var emptyType = ChatHistoryNodeLoadState.EmptyType.generic
                            for media in firstEntry.message.media {
                                if let action = media as? TelegramMediaAction {
                                    if action.action == .peerJoined {
                                        emptyType = .joined
                                        break
                                    } else if action.action == .historyCleared {
                                        emptyType = .clearedHistory
                                        break
                                    } else if case .topicCreated = action.action, firstEntry.message.author?.id == strongSelf.context.account.peerId {
                                        emptyType = .topic
                                        break
                                    }
                                }
                            }
                            loadState = .empty(emptyType)
                        } else {
                            var emptyType = ChatHistoryNodeLoadState.EmptyType.generic
                            if case let .replyThread(replyThreadMessage) = strongSelf.chatLocation {
                                loop: for entry in historyView.originalView.additionalData {
                                    switch entry {
                                        case let .message(id, messages) where id == replyThreadMessage.effectiveTopId:
                                            if let message = messages.first {
                                                for media in message.media {
                                                    if let action = media as? TelegramMediaAction {
                                                        if case .topicCreated = action.action {
                                                            emptyType = .topic
                                                            break
                                                        }
                                                    }
                                                }
                                                break loop
                                            }
                                        default:
                                            break
                                    }
                                }
                            }
                            loadState = .empty(emptyType)
                        }
                    } else {
                        if historyView.originalView.isLoadingEarlier && strongSelf.chatLocation.peerId?.namespace != Namespaces.Peer.CloudUser {
                            loadState = .loading(true)
                        } else {
                            if historyView.filteredEntries.count == 1, let entry = historyView.filteredEntries.first, case .ChatInfoEntry = entry {
                                loadState = .empty(.botInfo)
                            } else {
                                loadState = .messages
                            }
                        }
                    }
                } else {
                    loadState = .loading(false)
                }
                
                var animateIn = false
                if strongSelf.loadState != loadState {
                    if case .loading = strongSelf.loadState {
                        if case .messages = loadState {
                            animateIn = true
                        }
                    }
                    strongSelf.loadState = loadState
                    let isAnimated = animated || transition.animateIn || animateIn
                    strongSelf.loadStateUpdated?(loadState, isAnimated)
                    for f in strongSelf.additionalLoadStateUpdated {
                        f(loadState, isAnimated)
                    }
                }
                
                var hasAtLeast3Messages = false
                var hasPlentyOfMessages = false
                var hasLotsOfMessages = false
                if let historyView = strongSelf.historyView {
                    if historyView.originalView.holeEarlier || historyView.originalView.holeLater {
                        hasAtLeast3Messages = true
                        hasPlentyOfMessages = true
                        hasLotsOfMessages = true
                    } else if !historyView.originalView.holeEarlier && !historyView.originalView.holeLater {
                        if historyView.filteredEntries.count >= 3 {
                            hasAtLeast3Messages = true
                        }
                        if historyView.filteredEntries.count >= 10 {
                            hasPlentyOfMessages = true
                        }
                        if historyView.filteredEntries.count >= 40 {
                            hasLotsOfMessages = true
                        }
                    }
                }
                
                if strongSelf.hasAtLeast3Messages != hasAtLeast3Messages {
                    strongSelf.hasAtLeast3Messages = hasAtLeast3Messages
                    strongSelf.hasAtLeast3MessagesUpdated?(hasAtLeast3Messages)
                }
                if strongSelf.hasPlentyOfMessages != hasPlentyOfMessages {
                    strongSelf.hasPlentyOfMessages = hasPlentyOfMessages
                    strongSelf.hasPlentyOfMessagesUpdated?(hasPlentyOfMessages)
                }
                if strongSelf.hasLotsOfMessages != hasLotsOfMessages {
                    strongSelf.hasLotsOfMessages = hasLotsOfMessages
                    strongSelf.hasLotsOfMessagesUpdated?(hasLotsOfMessages)
                }
                
                if let _ = visibleRange.loadedRange {
                    if let visible = visibleRange.visibleRange {
                        let visibleFirstIndex = visible.firstIndex
                        if visibleFirstIndex <= visible.lastIndex {
                            let (incomingIndex, overallIndex) = maxMessageIndexForEntries(transition.historyView, indexRange: (transition.historyView.filteredEntries.count - 1 - visible.lastIndex, transition.historyView.filteredEntries.count - 1 - visibleFirstIndex))
                            
                            let messageIndex: MessageIndex?
                            switch strongSelf.chatLocation {
                            case .peer:
                                messageIndex = incomingIndex
                            case .replyThread, .customChatContents:
                                messageIndex = overallIndex
                            }
                            
                            if let messageIndex = messageIndex {
                                let _ = messageIndex
                            }
                        }
                    }
                } else if case .empty(.joined) = loadState, let entry = transition.historyView.originalView.entries.first {
                    strongSelf.updateMaxVisibleReadIncomingMessageIndex(entry.message.index)
                } else if case .empty(.topic) = loadState, let entry = transition.historyView.originalView.entries.first {
                    strongSelf.updateMaxVisibleReadIncomingMessageIndex(entry.message.index)
                }
                
                if !strongSelf.didSetInitialData {
                    strongSelf.didSetInitialData = true
                    strongSelf._initialData.set(.single(ChatHistoryCombinedInitialData(initialData: transition.initialData, buttonKeyboardMessage: transition.keyboardButtonsMessage, cachedData: transition.cachedData, cachedDataMessages: transition.cachedDataMessages, readStateData: transition.readStateData)))
                }
                strongSelf._cachedPeerDataAndMessages.set(.single((transition.cachedData, transition.cachedDataMessages)))
                let isEmpty = transition.historyView.originalView.entries.isEmpty || loadState == .empty(.botInfo)
                var hasReachedLimits = false
                if case let .customChatContents(customChatContents) = strongSelf.subject, let messageLimit = customChatContents.messageLimit {
                    hasReachedLimits = transition.historyView.originalView.entries.count >= messageLimit
                }
                let historyState: ChatHistoryNodeHistoryState = .loaded(isEmpty: isEmpty, hasReachedLimits: hasReachedLimits)
                if strongSelf.currentHistoryState != historyState {
                    strongSelf.currentHistoryState = historyState
                    strongSelf.historyState.set(historyState)
                }
                
                var buttonKeyboardMessageUpdated = false
                if let currentButtonKeyboardMessage = strongSelf.currentButtonKeyboardMessage, let buttonKeyboardMessage = transition.keyboardButtonsMessage {
                    if currentButtonKeyboardMessage.id != buttonKeyboardMessage.id || currentButtonKeyboardMessage.stableVersion != buttonKeyboardMessage.stableVersion {
                        buttonKeyboardMessageUpdated = true
                    }
                } else if (strongSelf.currentButtonKeyboardMessage != nil) != (transition.keyboardButtonsMessage != nil) {
                    buttonKeyboardMessageUpdated = true
                }
                if buttonKeyboardMessageUpdated {
                    strongSelf.currentButtonKeyboardMessage = transition.keyboardButtonsMessage
                    strongSelf._buttonKeyboardMessage.set(.single(transition.keyboardButtonsMessage))
                }
                
                if (transition.animateIn || animateIn) && !"".isEmpty {
                    let heightNorm = strongSelf.bounds.height - strongSelf.insets.top
                    strongSelf.forEachVisibleItemNode { itemNode in
                        let delayFactor = itemNode.frame.minY / heightNorm
                        let delay = Double(delayFactor * 0.1)

                        if let itemNode = itemNode as? ChatMessageItemView {
                            itemNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: delay)
                            itemNode.layer.animateScale(from: 0.94, to: 1.0, duration: 0.4, delay: delay, timingFunction: kCAMediaTimingFunctionSpring)
                        } else if let itemNode = itemNode as? ChatUnreadItemNode {
                            itemNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: delay)
                        } else if let itemNode = itemNode as? ChatReplyCountItemNode {
                            itemNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: delay)
                        }
                    }
                    strongSelf.forEachItemHeaderNode { itemNode in
                        let delayFactor = itemNode.frame.minY / heightNorm
                        let delay = Double(delayFactor * 0.2)

                        itemNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: delay)
                        itemNode.layer.animateScale(from: 0.94, to: 1.0, duration: 0.4, delay: delay, timingFunction: kCAMediaTimingFunctionSpring)
                    }
                }
                
                strongSelf.maybeApplyPendingMessageNavigationAlignment()
                
                if let scrolledToIndex = transition.scrolledToIndex {
                    if let strongSelf = self {
                        let isInitial: Bool
                        if case .Initial = transition.reason {
                            isInitial = true
                        } else {
                            isInitial = false
                        }
                        strongSelf.scrolledToIndex?(scrolledToIndex, isInitial)
                    }
                } else if transition.scrolledToSomeIndex {
                    self?.scrolledToSomeIndex?()
                }

                if let currentSendAnimationCorrelationIds = strongSelf.currentSendAnimationCorrelationIds {
                    var foundItemNodes: [Int64: ChatMessageItemView] = [:]
                    strongSelf.forEachItemNode { itemNode in
                        if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                            for (message, _) in item.content {
                                for attribute in message.attributes {
                                    if let attribute = attribute as? OutgoingMessageInfoAttribute, let correlationId = attribute.correlationId {
                                        if currentSendAnimationCorrelationIds.contains(correlationId) {
                                            foundItemNodes[correlationId] = itemNode
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !foundItemNodes.isEmpty {
                        strongSelf.currentSendAnimationCorrelationIds = nil
                        strongSelf.animationCorrelationMessagesFound?(foundItemNodes)
                    }
                }
                
                if !newIncomingReactions.isEmpty {
                    let messageIds = Array(newIncomingReactions.keys)
                    
                    let visibleNewIncomingReactionMessageIds = strongSelf.displayUnseenReactionAnimations(messageIds: messageIds)
                    if !visibleNewIncomingReactionMessageIds.isEmpty {
                        strongSelf.unseenReactionsProcessingManager.add(visibleNewIncomingReactionMessageIds.map { MessageAndThreadId(messageId: $0, threadId: nil) })
                    }
                }
                
                if unreadMessageRangeUpdated {
                    strongSelf.forEachVisibleMessageItemNode { itemNode in
                        itemNode.unreadMessageRangeUpdated()
                    }
                }
                
                strongSelf.hasActiveTransition = false
                
                if let previousCloneView {
                    previousCloneView.transform = strongSelf.view.transform
                    previousCloneView.center = strongSelf.view.center
                    previousCloneView.bounds = strongSelf.view.bounds
                    strongSelf.view.superview?.insertSubview(previousCloneView, belowSubview: strongSelf.view)
                    strongSelf.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                    previousCloneView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak previousCloneView] _ in
                        previousCloneView?.removeFromSuperview()
                    })
                }
                
                strongSelf.dequeueHistoryViewTransitions()
                
                strongSelf._isReady.set(true)
                
                if !strongSelf.didSetReady {
                    strongSelf.didSetReady = true
                    #if DEBUG
                    let deltaTime = (CFAbsoluteTimeGetCurrent() - strongSelf.initTimestamp) * 1000.0
                    print("Chat init to dequeue time: \(deltaTime) ms")
                    #endif
                }
            }
        }
        
        if let (layoutActionOnViewTransition, layoutCorrelationId) = self.layoutActionOnViewTransition {
            var foundCorrelationMessage = false
            if let layoutCorrelationId = layoutCorrelationId {
                itemSearch: for item in transition.insertItems {
                    if let messageItem = item.item as? ChatMessageItem {
                        for (message, _) in messageItem.content {
                            for attribute in message.attributes {
                                if let attribute = attribute as? OutgoingMessageInfoAttribute {
                                    if attribute.correlationId == layoutCorrelationId {
                                        foundCorrelationMessage = true
                                        break itemSearch
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                foundCorrelationMessage = true
            }

            if foundCorrelationMessage {
                self.layoutActionOnViewTransition = nil
                let (mappedTransition, updateSizeAndInsets) = layoutActionOnViewTransition(transition)
                self.transaction(deleteIndices: mappedTransition.deleteItems, insertIndicesAndItems: transition.insertItems, updateIndicesAndItems: transition.updateItems, options: mappedTransition.options, scrollToItem: mappedTransition.scrollToItem, updateSizeAndInsets: updateSizeAndInsets, stationaryItemRange: mappedTransition.stationaryItemRange, updateOpaqueState: ChatHistoryTransactionOpaqueState(historyView: transition.historyView), completion: { result in
                    completion(true, result)
                })
            } else {
                self.transaction(deleteIndices: transition.deleteItems, insertIndicesAndItems: transition.insertItems, updateIndicesAndItems: transition.updateItems, options: transition.options, scrollToItem: transition.scrollToItem, stationaryItemRange: transition.stationaryItemRange, updateOpaqueState: ChatHistoryTransactionOpaqueState(historyView: transition.historyView), completion: { result in
                    completion(false, result)
                })
            }
        } else {
            self.transaction(deleteIndices: transition.deleteItems, insertIndicesAndItems: transition.insertItems, updateIndicesAndItems: transition.updateItems, options: transition.options, scrollToItem: transition.scrollToItem, stationaryItemRange: transition.stationaryItemRange, updateOpaqueState: ChatHistoryTransactionOpaqueState(historyView: transition.historyView), completion: { result in
                completion(false, result)
            })
        }
        
        if transition.flashIndicators {
            //self.flashHeaderItems()
        }
    }
    
    private func displayUnseenReactionAnimations(messageIds: [MessageId], forceMapping: [MessageId: [ReactionsMessageAttribute.RecentPeer]] = [:]) -> [MessageId] {
        let timestamp = CACurrentMediaTime()
        var messageIds = messageIds
        for i in (0 ..< messageIds.count).reversed() {
            if let previousTimestamp = self.displayUnseenReactionAnimationsTimestamps[messageIds[i]], previousTimestamp + 1.0 > timestamp {
                messageIds.remove(at: i)
            } else {
                self.displayUnseenReactionAnimationsTimestamps[messageIds[i]] = timestamp
            }
        }
        
        if messageIds.isEmpty {
            return []
        }
        
        guard let chatDisplayNode = self.controllerInteraction.chatControllerNode() as? ChatControllerNode else {
            return []
        }
        var visibleNewIncomingReactionMessageIds: [MessageId] = []
        self.forEachVisibleItemNode { itemNode in
            guard let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item, let reactionsAttribute = item.content.firstMessage.reactionsAttribute, messageIds.contains(item.content.firstMessage.id) else {
                return
            }
            
            var selectedReaction: (MessageReaction.Reaction, EnginePeer?, Bool)?
            let recentPeers = forceMapping[item.content.firstMessage.id] ?? reactionsAttribute.recentPeers
            for recentPeer in recentPeers {
                if recentPeer.isUnseen {
                    selectedReaction = (recentPeer.value, item.content.firstMessage.peers[recentPeer.peerId].flatMap(EnginePeer.init), recentPeer.isLarge)
                    break
                }
            }
            
            guard let (updatedReaction, updateReactionPeer, updatedReactionIsLarge) = selectedReaction else {
                return
            }
            
            visibleNewIncomingReactionMessageIds.append(item.content.firstMessage.id)
            
            var reactionItem: ReactionItem?
            
            switch updatedReaction {
            case .builtin, .stars:
                if let availableReactions = item.associatedData.availableReactions {
                    for reaction in availableReactions.reactions {
                        guard let centerAnimation = reaction.centerAnimation else {
                            continue
                        }
                        guard let aroundAnimation = reaction.aroundAnimation else {
                            continue
                        }
                        if reaction.value == updatedReaction {
                            reactionItem = ReactionItem(
                                reaction: ReactionItem.Reaction(rawValue: reaction.value),
                                appearAnimation: reaction.appearAnimation,
                                stillAnimation: reaction.selectAnimation,
                                listAnimation: centerAnimation,
                                largeListAnimation: reaction.activateAnimation,
                                applicationAnimation: aroundAnimation,
                                largeApplicationAnimation: reaction.effectAnimation,
                                isCustom: false
                            )
                            break
                        }
                    }
                }
            case let .custom(fileId):
                if let itemFile = item.message.associatedMedia[MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile {
                    let itemFile = TelegramMediaFile.Accessor(itemFile)
                    reactionItem = ReactionItem(
                        reaction: ReactionItem.Reaction(rawValue: updatedReaction),
                        appearAnimation: itemFile,
                        stillAnimation: itemFile,
                        listAnimation: itemFile,
                        largeListAnimation: itemFile,
                        applicationAnimation: nil,
                        largeApplicationAnimation: nil,
                        isCustom: true
                    )
                }
            }
            
            if let reactionItem = reactionItem, let targetView = itemNode.targetReactionView(value: updatedReaction) {
                let standaloneReactionAnimation = StandaloneReactionAnimation(genericReactionEffect: self.genericReactionEffect)
                
                chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                
                var avatarPeers: [EnginePeer] = []
                if item.message.id.peerId.namespace != Namespaces.Peer.CloudUser, let updateReactionPeer = updateReactionPeer {
                    avatarPeers = [updateReactionPeer]
                }
                
                chatDisplayNode.addSubnode(standaloneReactionAnimation)
                standaloneReactionAnimation.frame = chatDisplayNode.bounds
                standaloneReactionAnimation.animateReactionSelection(
                    context: self.context,
                    theme: item.presentationData.theme.theme,
                    animationCache: self.controllerInteraction.presentationContext.animationCache,
                    reaction: reactionItem,
                    avatarPeers: avatarPeers,
                    playHaptic: true,
                    isLarge: updatedReactionIsLarge,
                    targetView: targetView,
                    addStandaloneReactionAnimation: { [weak self] standaloneReactionAnimation in
                        guard let strongSelf = self, let chatDisplayNode = strongSelf.controllerInteraction.chatControllerNode() as? ChatControllerNode else {
                            return
                        }
                        chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                        standaloneReactionAnimation.frame = chatDisplayNode.bounds
                        chatDisplayNode.addSubnode(standaloneReactionAnimation)
                    },
                    completion: { [weak standaloneReactionAnimation] in
                        standaloneReactionAnimation?.removeFromSupernode()
                    }
                )
            }
        }
        return visibleNewIncomingReactionMessageIds
    }
    
    public func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets) {
        self.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets, additionalScrollDistance: 0.0, scrollToTop: false, completion: {})
    }
        
    public func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets, additionalScrollDistance: CGFloat, scrollToTop: Bool, completion: @escaping () -> Void) {
        /*if updateSizeAndInsets.insets.top == 83.0 {
            if !transition.isAnimated {
                assert(true)
            }
        }*/
        var scrollToItem: ListViewScrollToItem?
        var postScrollToItem: ListViewScrollToItem?
        if scrollToTop, case .known = self.visibleContentOffset() {
            scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Spring(duration: updateSizeAndInsets.duration), directionHint: .Up)
        } else if self.enableUnreadAlignment {
            if updateSizeAndInsets.insets.bottom != self.insets.bottom {
                self.forEachVisibleItemNode { itemNode in
                    if let itemNode = itemNode as? ChatUnreadItemNode, let index = itemNode.index {
                        if abs(itemNode.frame.maxY - (self.visibleSize.height - self.insets.bottom + 6.0)) < 1.0 {
                            postScrollToItem = ListViewScrollToItem(index: index, position: .bottom(0.0), animated: updateSizeAndInsets.duration != 0.0, curve: updateSizeAndInsets.curve, directionHint: .Up)
                        }
                    }
                }
            }
        }
        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: scrollToItem, additionalScrollDistance: scrollToTop ? 0.0 : additionalScrollDistance, updateSizeAndInsets: updateSizeAndInsets, stationaryItemRange: nil, updateOpaqueState: nil, completion: { [weak self] _ in
            guard let self else {
                return
            }
            if let postScrollToItem = postScrollToItem {
                self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: postScrollToItem, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in
                    completion()
                })
            } else {
                completion()
            }
        })
        
        if !self.dequeuedInitialTransitionOnLayout {
            self.dequeuedInitialTransitionOnLayout = true
            self.dequeueHistoryViewTransitions()
        }
    }
    
    public func disconnect() {
        self.historyDisposable.set(nil)
    }
    
    private func updateReadHistoryActions() {
        let canRead = self.canReadHistoryValue && self.isScrollAtBottomPosition
        
        if canRead != (self.interactiveReadActionDisposable != nil) {
            if let interactiveReadActionDisposable = self.interactiveReadActionDisposable {
                if !canRead {
                    interactiveReadActionDisposable.dispose()
                    self.interactiveReadActionDisposable = nil
                }
            } else if self.interactiveReadActionDisposable == nil {
                if !self.context.sharedContext.immediateExperimentalUISettings.skipReadHistory && !self.context.account.isSupportUser {
                    if case let .peer(peerId) = self.chatLocation {
                        self.interactiveReadActionDisposable = self.context.engine.messages.installInteractiveReadMessagesAction(peerId: peerId, threadId: nil)
                    } else if case let .replyThread(replyThread) = self.chatLocation, (replyThread.isForumPost || replyThread.isMonoforumPost) {
                        self.interactiveReadActionDisposable = self.context.engine.messages.installInteractiveReadMessagesAction(peerId: replyThread.peerId, threadId: replyThread.threadId)
                    }
                }
            }
        }
        
        if canRead != (self.interactiveReadReactionsDisposable != nil) {
            if let interactiveReadReactionsDisposable = self.interactiveReadReactionsDisposable {
                if !canRead {
                    interactiveReadReactionsDisposable.dispose()
                    self.interactiveReadReactionsDisposable = nil
                }
            } else if self.interactiveReadReactionsDisposable == nil {
                if case let .peer(peerId) = self.chatLocation {
                    if !self.context.sharedContext.immediateExperimentalUISettings.skipReadHistory {
                        let visibleMessageRange = self.visibleMessageRange
                        self.interactiveReadReactionsDisposable = context.engine.messages.installInteractiveReadReactionsAction(peerId: peerId, getVisibleRange: {
                            return visibleMessageRange.with { $0 }
                        }, didReadReactionsInMessages: { [weak self] idsAndReactions in
                            Queue.mainQueue().after(0.2, {
                                guard let strongSelf = self else {
                                    return
                                }
                                let _ = strongSelf.displayUnseenReactionAnimations(messageIds: Array(idsAndReactions.keys), forceMapping: idsAndReactions)
                            })
                        })
                    }
                }
            }
        }
    }
    
    func lastVisbleMesssage() -> Message? {
        var currentMessage: Message?
        if let historyView = self.historyView {
            if let visibleRange = self.displayedItemRange.visibleRange {
                var index = 0
                loop: for entry in historyView.filteredEntries.reversed() {
                    if index >= visibleRange.firstIndex && index <= visibleRange.lastIndex {
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            currentMessage = message
                            break loop
                        } else if case let .MessageGroupEntry(_, messages, _) = entry {
                            currentMessage = messages.first?.0
                            break loop
                        }
                    }
                    index += 1
                }
            }
        }
        return currentMessage
    }
    
    func immediateScrollState() -> ChatInterfaceHistoryScrollState? {
        var currentMessage: Message?
        if let historyView = self.historyView {
            if let visibleRange = self.displayedItemRange.visibleRange {
                var index = 0
                loop: for entry in historyView.filteredEntries.reversed() {
                    if index >= visibleRange.firstIndex && index <= visibleRange.lastIndex {
                        if case let .MessageEntry(message, _, _, _, _, _) = entry {
                            if message.adAttribute != nil {
                                continue
                            }
                            if index != 0 || historyView.originalView.laterId != nil {
                                currentMessage = message
                            }
                            break loop
                        } else if case let .MessageGroupEntry(_, messages, _) = entry {
                            if index != 0 || historyView.originalView.laterId != nil {
                                currentMessage = messages.first?.0
                            }
                            break loop
                        } else if case .ChatInfoEntry = entry {
                            break loop
                        }
                    }
                    index += 1
                }
            }
        }
        
        if let message = currentMessage {
            var relativeOffset: CGFloat = 0.0
            self.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item, item.message.id == message.id {
                    if let offsetValue = self.itemNodeRelativeOffset(itemNode) {
                        relativeOffset = offsetValue
                    }
                }
            }
            return ChatInterfaceHistoryScrollState(messageIndex: message.index, relativeOffset: Double(relativeOffset))
        }
        return nil
    }
    
    func scrollToNextMessage() {
        if let historyView = self.historyView {
            var scrolled = false
            if let scrollState = self.immediateScrollState() {
                var index = historyView.filteredEntries.count - 1
                loop: for entry in historyView.filteredEntries.reversed() {
                    if entry.index == scrollState.messageIndex {
                        break loop
                    }
                    index -= 1
                }
                
                if index != 0 {
                    var nextItem = false
                    self.forEachItemNode { itemNode in
                        if let itemNode = itemNode as? ChatMessageItemView, itemNode.item?.content.index == scrollState.messageIndex {
                            if itemNode.frame.maxY >= self.bounds.size.height - self.insets.bottom - 4.0 {
                                nextItem = true
                            }
                        }
                    }
                    
                    if !nextItem {
                        scrolled = true
                        self.scrollToMessage(from: scrollState.messageIndex, to: scrollState.messageIndex, animated: true, highlight: false)
                    } else {
                        loop: for i in (index + 1) ..< historyView.filteredEntries.count {
                            let entry = historyView.filteredEntries[i]
                            switch entry {
                                case .MessageEntry, .MessageGroupEntry:
                                    scrolled = true
                                    self.scrollToMessage(from: scrollState.messageIndex, to: entry.index, animated: true, highlight: false)
                                    break loop
                                default:
                                    break
                            }
                        }
                    }
                }
            }
            
            if !scrolled {
                self.scrollToEndOfHistory()
            }
        }
    }
    
    func requestMessageUpdate(_ id: MessageId, andScrollToItem scroll: Bool = false) {
        if let historyView = self.historyView {
            var messageItem: ChatMessageItem?
            self.forEachItemNode({ itemNode in
                if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                    for (message, _) in item.content {
                        if message.id == id {
                            messageItem = item
                            break
                        }
                    }
                }
            })
            
            if let messageItem = messageItem {
                let associatedData = messageItem.associatedData
                let disableFloatingDateHeaders = messageItem.disableDate
                
                loop: for i in 0 ..< historyView.filteredEntries.count {
                    switch historyView.filteredEntries[i] {
                    case let .MessageEntry(message, presentationData, read, location, selection, attributes):
                        if message.id == id {
                            let index = historyView.filteredEntries.count - 1 - i
                            let item: ListViewItem
                            switch self.mode {
                            case .bubbles:
                                item = ChatMessageItemImpl(presentationData: presentationData, context: self.context, chatLocation: self.chatLocation, associatedData: associatedData, controllerInteraction: self.controllerInteraction, content: .message(message: message, read: read, selection: selection, attributes: attributes, location: location), disableDate: disableFloatingDateHeaders)
                            case let .list(_, _, _, displayHeaders, hintLinks, isGlobalSearch):
                                let displayHeader: Bool
                                switch displayHeaders {
                                case .none:
                                    displayHeader = false
                                case .all:
                                    displayHeader = true
                                case .allButLast:
                                    displayHeader = listMessageDateHeaderId(timestamp: message.timestamp) != historyView.lastHeaderId
                                }
                                item = ListMessageItem(presentationData: presentationData, context: self.context, chatLocation: self.chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: self.controllerInteraction), message: message, translateToLanguage: associatedData.translateToLanguage, selection: selection, displayHeader: displayHeader, hintIsLink: hintLinks, isGlobalSearchResult: isGlobalSearch)
                            }
                            let updateItem = ListViewUpdateItem(index: index, previousIndex: index, item: item, directionHint: nil)
                            
                            var scrollToItem: ListViewScrollToItem?
                            if scroll {
                                scrollToItem = ListViewScrollToItem(index: index, position: .center(.top), animated: true, curve: .Spring(duration: 0.4), directionHint: .Down, displayLink: true)
                            }
                            
                            self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [updateItem], options: [.AnimateInsertion], scrollToItem: scrollToItem, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                            break loop
                        }
                    case let .MessageGroupEntry(_, messages, presentationData):
                        if messages.contains(where: { $0.0.id == id }) {
                            let index = historyView.filteredEntries.count - 1 - i
                            let item: ListViewItem
                            switch self.mode {
                            case .bubbles:
                            item = ChatMessageItemImpl(presentationData: presentationData, context: self.context, chatLocation: self.chatLocation, associatedData: associatedData, controllerInteraction: self.controllerInteraction, content: .group(messages: messages), disableDate: disableFloatingDateHeaders)
                            case .list:
                                assertionFailure()
                                item = ListMessageItem(presentationData: presentationData, context: context, chatLocation: chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: controllerInteraction), message: messages[0].0, selection: .none, displayHeader: false)
                            }
                            let updateItem = ListViewUpdateItem(index: index, previousIndex: index, item: item, directionHint: nil)
                            
                            var scrollToItem: ListViewScrollToItem?
                            if scroll {
                                scrollToItem = ListViewScrollToItem(index: index, position: .center(.top), animated: true, curve: .Spring(duration: 0.4), directionHint: .Down, displayLink: true)
                            }
                            
                            self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [updateItem], options: [.AnimateInsertion], scrollToItem: scrollToItem, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                            break loop
                        }
                    default:
                        break
                    }
                }
            }
        }
    }

    func requestMessageUpdate(stableId: UInt32) {
        if let historyView = self.historyView {
            var messageItem: ChatMessageItem?
            self.forEachItemNode({ itemNode in
                if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                    for (message, _) in item.content {
                        if message.stableId == stableId {
                            messageItem = item
                            break
                        }
                    }
                }
            })

            if let messageItem = messageItem {
                let associatedData = messageItem.associatedData
                let disableFloatingDateHeaders = messageItem.disableDate

                loop: for i in 0 ..< historyView.filteredEntries.count {
                    switch historyView.filteredEntries[i] {
                        case let .MessageEntry(message, presentationData, read, location, selection, attributes):
                            if message.stableId == stableId {
                                let index = historyView.filteredEntries.count - 1 - i
                                let item: ListViewItem
                                switch self.mode {
                                    case .bubbles:
                                        item = ChatMessageItemImpl(presentationData: presentationData, context: self.context, chatLocation: self.chatLocation, associatedData: associatedData, controllerInteraction: self.controllerInteraction, content: .message(message: message, read: read, selection: selection, attributes: attributes, location: location), disableDate: disableFloatingDateHeaders)
                                    case let .list(_, _, _, displayHeaders, hintLinks, isGlobalSearch):
                                        let displayHeader: Bool
                                        switch displayHeaders {
                                        case .none:
                                            displayHeader = false
                                        case .all:
                                            displayHeader = true
                                        case .allButLast:
                                            displayHeader = listMessageDateHeaderId(timestamp: message.timestamp) != historyView.lastHeaderId
                                        }
                                        item = ListMessageItem(presentationData: presentationData, context: self.context, chatLocation: self.chatLocation, interaction: ListMessageItemInteraction(controllerInteraction: self.controllerInteraction), message: message, translateToLanguage: associatedData.translateToLanguage, selection: selection, displayHeader: displayHeader, hintIsLink: hintLinks, isGlobalSearchResult: isGlobalSearch)
                                }
                                let updateItem = ListViewUpdateItem(index: index, previousIndex: index, item: item, directionHint: nil)
                                self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [updateItem], options: [.AnimateInsertion], scrollToItem: nil, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                                break loop
                            }
                        default:
                            break
                    }
                }
            }
        }
    }

    private func messagesAtPoint(_ point: CGPoint) -> [Message]? {
        var resultMessages: [Message]?
        self.forEachVisibleItemNode { itemNode in
            if resultMessages == nil, let itemNode = itemNode as? ListViewItemNode, itemNode.frame.contains(point) {
                if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                    switch item.content {
                        case let .message(message, _, _ , _, _):
                            resultMessages = [message]
                        case let .group(messages):
                            resultMessages = messages.map { $0.0 }
                    }
                }
            }
        }
        return resultMessages
    }
    
    func isMessageVisible(id: MessageId) -> Bool {
        var found = false
        self.forEachVisibleItemNode { itemNode in
            if !found, let itemNode = itemNode as? ListViewItemNode {
                if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                    switch item.content {
                    case let .message(message, _, _ , _, _):
                        if message.id == id {
                            found = true
                        }
                    case let .group(messages):
                        for message in messages {
                            if message.0.id == id {
                                found = true
                            }
                        }
                    }
                }
            }
        }
        return found
    }
    
    private var selectionPanState: (selecting: Bool, initialMessageId: MessageId, toggledMessageIds: [[MessageId]])?
    private var selectionScrollActivationTimer: SwiftSignalKit.Timer?
    private var selectionScrollDisplayLink: ConstantDisplayLinkAnimator?
    private var selectionScrollDelta: CGFloat?
    private var selectionLastLocation: CGPoint?
    
    @objc private func selectionPanGesture(_ recognizer: UIGestureRecognizer) -> Void {
        let location = recognizer.location(in: self.view)
        switch recognizer.state {
            case .began:
                if let messages = self.messagesAtPoint(location), let message = messages.first {
                    let selecting = !(self.controllerInteraction.selectionState?.selectedIds.contains(message.id) ?? false)
                    self.selectionPanState = (selecting, message.id, [])
                    self.controllerInteraction.toggleMessagesSelection(messages.map { $0.id }, selecting)
                }
            case .changed:
                self.handlePanSelection(location: location)
                self.selectionLastLocation = location
            case .ended, .failed, .cancelled:
                self.selectionPanState = nil
                self.selectionScrollDisplayLink = nil
                self.selectionScrollActivationTimer?.invalidate()
                self.selectionScrollActivationTimer = nil
                self.selectionScrollDelta = nil
                self.selectionLastLocation = nil
                self.selectionScrollSkipUpdate = false
            case .possible:
                break
            @unknown default:
                fatalError()
        }
    }
    
    private func handlePanSelection(location: CGPoint) {
        var location = location
        if location.y < self.insets.top {
            location.y = self.insets.top + 5.0
        } else if location.y > self.frame.height - self.insets.bottom {
            location.y = self.frame.height - self.insets.bottom - 5.0
        }
        
        if let state = self.selectionPanState {
            if let messages = self.messagesAtPoint(location), let message = messages.first {
                if message.id == state.initialMessageId {
                    if !state.toggledMessageIds.isEmpty {
                        self.controllerInteraction.toggleMessagesSelection(state.toggledMessageIds.flatMap { $0 }, !state.selecting)
                        self.selectionPanState = (state.selecting, state.initialMessageId, [])
                    }
                } else if state.toggledMessageIds.last?.first != message.id {
                    var updatedToggledMessageIds: [[MessageId]] = []
                    var previouslyToggled = false
                    for i in (0 ..< state.toggledMessageIds.count) {
                        if let messageId = state.toggledMessageIds[i].first {
                            if messageId == message.id {
                                previouslyToggled = true
                                updatedToggledMessageIds = Array(state.toggledMessageIds.prefix(i + 1))
                                
                                let messageIdsToToggle = Array(state.toggledMessageIds.suffix(state.toggledMessageIds.count - i - 1)).flatMap { $0 }
                                self.controllerInteraction.toggleMessagesSelection(messageIdsToToggle, !state.selecting)
                                break
                            }
                        }
                    }
                    
                    if !previouslyToggled {
                        updatedToggledMessageIds = state.toggledMessageIds
                        let isSelected = (self.controllerInteraction.selectionState?.selectedIds.contains(message.id) ?? false)
                        if state.selecting != isSelected {
                            let messageIds = messages.filter { message -> Bool in
                                for media in message.media {
                                    if media is TelegramMediaAction {
                                        return false
                                    }
                                }
                                return true
                            }.map { $0.id }
                            updatedToggledMessageIds.append(messageIds)
                            self.controllerInteraction.toggleMessagesSelection(messageIds, state.selecting)
                        }
                    }
                    
                    self.selectionPanState = (state.selecting, state.initialMessageId, updatedToggledMessageIds)
                }
            }
        
            let scrollingAreaHeight: CGFloat = 50.0
            if location.y < scrollingAreaHeight + self.insets.top || location.y > self.frame.height - scrollingAreaHeight - self.insets.bottom {
                if location.y < self.frame.height / 2.0 {
                    self.selectionScrollDelta = (scrollingAreaHeight - (location.y - self.insets.top)) / scrollingAreaHeight
                } else {
                    self.selectionScrollDelta = -(scrollingAreaHeight - min(scrollingAreaHeight, max(0.0, (self.frame.height - self.insets.bottom - location.y)))) / scrollingAreaHeight
                }
                if let displayLink = self.selectionScrollDisplayLink {
                    displayLink.isPaused = false
                } else {
                    if let _ = self.selectionScrollActivationTimer {
                    } else {
                        let timer = SwiftSignalKit.Timer(timeout: 0.45, repeat: false, completion: { [weak self] in
                            self?.setupSelectionScrolling()
                        }, queue: .mainQueue())
                        timer.start()
                        self.selectionScrollActivationTimer = timer
                    }
                }
            } else {
                self.selectionScrollDisplayLink?.isPaused = true
                self.selectionScrollActivationTimer?.invalidate()
                self.selectionScrollActivationTimer = nil
            }
        }
    }
    
    private var selectionScrollSkipUpdate = false
    private func setupSelectionScrolling() {
        self.selectionScrollDisplayLink = ConstantDisplayLinkAnimator(update: { [weak self] in
            self?.selectionScrollActivationTimer = nil
            if let strongSelf = self, let delta = strongSelf.selectionScrollDelta {
                let distance: CGFloat = 15.0 * min(1.0, 0.15 + abs(delta * delta))
                let direction: ListViewScrollDirection = delta > 0.0 ? .up : .down
                let _ = strongSelf.scrollWithDirection(direction, distance: distance)
                
                if let location = strongSelf.selectionLastLocation {
                    if !strongSelf.selectionScrollSkipUpdate {
                        strongSelf.handlePanSelection(location: location)
                    }
                    strongSelf.selectionScrollSkipUpdate = !strongSelf.selectionScrollSkipUpdate
                }
            }
        })
        self.selectionScrollDisplayLink?.isPaused = false
    }

    
    func voicePlaylistItemChanged(_ previousItem: SharedMediaPlaylistItem?, _ currentItem: SharedMediaPlaylistItem?) -> Void {
        if let currentItemId = currentItem?.id as? PeerMessagesMediaPlaylistItemId {
            if let source = currentItem?.playbackData?.source, case let .telegramFile(_, _, isViewOnce) = source, isViewOnce {
                self.currentlyPlayingMessageIdPromise.set(.single(nil))
            } else {
                let isVideo = currentItem?.playbackData?.type == .instantVideo
                self.currentlyPlayingMessageIdPromise.set(.single((currentItemId.messageIndex, isVideo)))
            }
        } else {
            self.currentlyPlayingMessageIdPromise.set(.single(nil))
        }
    }
    
    func scrollToMessage(index: MessageIndex) {
        self.pendingMessageNavigationAlignment = nil
        self.appliedScrollToMessageId = nil
        self.scrollToMessageIdPromise.set(.single(index))
    }

    private var currentSendAnimationCorrelationIds: Set<Int64>?
    func setCurrentSendAnimationCorrelationIds(_ value: Set<Int64>?) {
        self.currentSendAnimationCorrelationIds = value
    }
    
    private var currentDeleteAnimationCorrelationIds = Set<UInt32>()
    func setCurrentDeleteAnimationCorrelationIds(_ value: Set<UInt32>) {
        self.currentDeleteAnimationCorrelationIds = value
    }
    private var currentAppliedDeleteAnimationCorrelationIds = Set<UInt32>()

    var animationCorrelationMessagesFound: (([Int64: ChatMessageItemView]) -> Void)?

    final class SnapshotState {
        fileprivate let snapshotTopInset: CGFloat
        fileprivate let snapshotBottomInset: CGFloat
        fileprivate let snapshotView: UIView
        fileprivate let overscrollView: UIView?

        fileprivate init(
            snapshotTopInset: CGFloat,
            snapshotBottomInset: CGFloat,
            snapshotView: UIView,
            overscrollView: UIView?
        ) {
            self.snapshotTopInset = snapshotTopInset
            self.snapshotBottomInset = snapshotBottomInset
            self.snapshotView = snapshotView
            self.overscrollView = overscrollView
        }
    }

    func prepareSnapshotState() -> SnapshotState {
        var snapshotTopInset: CGFloat = 0.0
        var snapshotBottomInset: CGFloat = 0.0
        self.forEachItemNode { itemNode in
            let topOverflow = itemNode.frame.maxY - self.bounds.height
            snapshotTopInset = max(snapshotTopInset, topOverflow)

            if itemNode.frame.minY < 0.0 {
                snapshotBottomInset = max(snapshotBottomInset, -itemNode.frame.minY)
            }
        }

        let snapshotView = self.view//.snapshotView(afterScreenUpdates: false)!
        self.globalIgnoreScrollingEvents = true

        //snapshotView.frame = self.view.bounds
        /*if let sublayers = self.layer.sublayers {
            for sublayer in sublayers {
                sublayer.isHidden = true
            }
        }*/
        //self.view.addSubview(snapshotView)

        let overscrollView = self.overscrollView
        if let overscrollView = overscrollView {
            self.overscrollView = nil

            overscrollView.frame = overscrollView.convert(overscrollView.bounds, to: self.view)
            snapshotView.addSubview(overscrollView)

            if self.rotated {
                overscrollView.layer.sublayerTransform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
            }
        }

        return SnapshotState(
            snapshotTopInset: snapshotTopInset,
            snapshotBottomInset: snapshotBottomInset,
            snapshotView: snapshotView,
            overscrollView: overscrollView
        )
    }

    func animateFromSnapshot(_ snapshotState: SnapshotState, completion: @escaping () -> Void) {
        var snapshotTopInset: CGFloat = 0.0
        var snapshotBottomInset: CGFloat = 0.0
        self.forEachItemNode { itemNode in
            let topOverflow = itemNode.frame.maxY - self.bounds.height
            snapshotTopInset = max(snapshotTopInset, topOverflow)

            if itemNode.frame.minY < 0.0 {
                snapshotBottomInset = max(snapshotBottomInset, -itemNode.frame.minY)
            }
        }

        let snapshotParentView = UIView()
        snapshotParentView.addSubview(snapshotState.snapshotView)
        if self.rotated {
            snapshotParentView.layer.sublayerTransform = CATransform3DMakeRotation(CGFloat(Double.pi), 0.0, 0.0, 1.0)
        }
        snapshotParentView.frame = self.view.frame

        snapshotState.snapshotView.frame = snapshotParentView.bounds
        
        snapshotState.snapshotView.clipsToBounds = true
        if self.rotated {
            snapshotState.snapshotView.layer.sublayerTransform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        }
        
        self.view.superview?.insertSubview(snapshotParentView, belowSubview: self.view)

        snapshotParentView.layer.animatePosition(from: CGPoint(x: 0.0, y: 0.0), to: CGPoint(x: 0.0, y: -self.view.bounds.height - snapshotState.snapshotBottomInset - snapshotTopInset), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, additive: true, completion: { [weak snapshotParentView] _ in
            snapshotParentView?.removeFromSuperview()
            completion()
        })

        self.view.layer.animatePosition(from: CGPoint(x: 0.0, y: self.view.bounds.height + snapshotTopInset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
    }
    
    override public func customItemDeleteAnimationDuration(itemNode: ListViewItemNode) -> Double? {
        if !self.currentAppliedDeleteAnimationCorrelationIds.isEmpty {
            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                for (message, _) in item.content {
                    if self.currentAppliedDeleteAnimationCorrelationIds.contains(message.stableId) {
                        return 0.8
                    }
                }
            }
        }
        return nil
    }
}
