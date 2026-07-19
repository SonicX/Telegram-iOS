import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AsyncDisplayKit
import Display
import TelegramNotices
import ContextUI
import AccountContext
import ChatMessageItemView
import ChatMessageItemCommon
import ReactionSelectionNode
import EntityKeyboard
import TextNodeWithEntities
import PremiumUI
import TooltipUI
import TopMessageReactions
import TelegramNotices

extension ChatControllerImpl {
    func openMessageContextMenu(message: Message, selectAll: Bool, node: ASDisplayNode, frame: CGRect, anyRecognizer: UIGestureRecognizer?, location: CGPoint?) -> Void {
        if self.presentationInterfaceState.interfaceState.selectionState != nil {
            return
        }
        let presentationData = self.presentationData
        
        self.dismissAllTooltips()
        
        let recognizer: TapLongTapOrDoubleTapGestureRecognizer? = anyRecognizer as? TapLongTapOrDoubleTapGestureRecognizer
        let gesture: ContextGesture? = anyRecognizer as? ContextGesture
        if let messages = self.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(message.id) {
            (self.view.window as? WindowHost)?.cancelInteractiveKeyboardGestures()
            self.chatDisplayNode.cancelInteractiveKeyboardGestures()
            var updatedMessages = messages
            for i in 0 ..< updatedMessages.count {
                if updatedMessages[i].id == message.id {
                    let message = updatedMessages.remove(at: i)
                    updatedMessages.insert(message, at: 0)
                    break
                }
            }
            
            guard let topMessage = messages.first else {
                return
            }
            
            let _ = combineLatest(queue: .mainQueue(),
                self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId)),
                contextMenuForChatPresentationInterfaceState(chatPresentationInterfaceState: self.presentationInterfaceState, context: self.context, messages: updatedMessages, controllerInteraction: self.controllerInteraction, selectAll: selectAll, interfaceInteraction: self.interfaceInteraction, messageNode: node as? ChatMessageItemView),
                peerMessageAllowedReactions(context: self.context, message: topMessage),
                peerMessageSelectedReactions(context: self.context, message: topMessage),
                topMessageReactions(context: self.context, message: topMessage, subPeerId: self.chatLocation.threadId.flatMap(EnginePeer.Id.init)),
                ApplicationSpecificNotice.getChatTextSelectionTips(accountManager: self.context.sharedContext.accountManager)
            ).startStandalone(next: { [weak self] peer, actions, allowedReactionsAndStars, selectedReactions, topReactions, chatTextSelectionTips in
                guard let self else {
                    return
                }
                
                var (allowedReactions, _) = allowedReactionsAndStars
                
                var actions = actions
                switch actions.content {
                case let .list(itemList):
                    if itemList.isEmpty {
                        return
                    }
                case .custom, .twoLists:
                    break
                }
                
                if allowedReactions != nil, case let .customChatContents(customChatContents) = self.presentationInterfaceState.subject {
                    if case let .hashTagSearch(publicPosts) = customChatContents.kind, publicPosts {
                        allowedReactions = nil
                    }
                }

                var tip: ContextController.Tip?
                
                if tip == nil {
                    let isAd = message.adAttribute != nil
                        
                    var isAction = false
                    for media in message.media {
                        if media is TelegramMediaAction {
                            isAction = true
                            break
                        }
                    }
                    if self.presentationInterfaceState.copyProtectionEnabled && !isAction && !isAd {
                        if case .scheduledMessages = self.subject {
                        } else {
                            var isChannel = false
                            if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
                                isChannel = true
                            }
                            tip = .messageCopyProtection(isChannel: isChannel)
                        }
                    } else {
                        let numberOfComponents = message.text.components(separatedBy: CharacterSet.whitespacesAndNewlines).count
                        let displayTextSelectionTip = numberOfComponents >= 3 && !message.text.isEmpty && chatTextSelectionTips < 3 && !isAd
                        if displayTextSelectionTip {
                            let _ = ApplicationSpecificNotice.incrementChatTextSelectionTips(accountManager: self.context.sharedContext.accountManager).startStandalone()
                            tip = .textSelection
                        }
                    }
                }
                
                if messages.contains(where: { $0.pendingProcessingAttribute != nil }) {
                    tip = .videoProcessing
                }

                if actions.tip == nil {
                    actions.tip = tip
                }
                
                actions.context = self.context
                actions.animationCache = self.controllerInteraction?.presentationContext.animationCache
                                                         
                if canAddMessageReactions(message: topMessage), let allowedReactions = allowedReactions, !topReactions.isEmpty {
                    actions.reactionItems = topReactions.map { ReactionContextItem.reaction(item: $0, icon: .none) }
                    actions.selectedReactionItems = selectedReactions.reactions
                    if message.areReactionsTags(accountPeerId: self.context.account.peerId) {
                        if self.presentationInterfaceState.isPremium {
                            actions.reactionsTitle = presentationData.strings.Chat_ContextMenuTagsTitle
                        } else {
                            actions.reactionsTitle = presentationData.strings.Chat_MessageContextMenu_NonPremiumTagsTitle
                            actions.reactionsLocked = true
                            actions.selectedReactionItems = Set()
                        }
                        actions.allPresetReactionsAreAvailable = true
                    }
                    
                    if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
                        actions.alwaysAllowPremiumReactions = true
                    }
                    
                    if !actions.reactionItems.isEmpty {
                        let reactionItems: [EmojiComponentReactionItem] = actions.reactionItems.compactMap { item -> EmojiComponentReactionItem? in
                            switch item {
                            case let .reaction(reaction, _):
                                return EmojiComponentReactionItem(reaction: reaction.reaction.rawValue, file: reaction.stillAnimation)
                            default:
                                return nil
                            }
                        }
                        
                        var allReactionsAreAvailable = false
                        switch allowedReactions {
                        case .set:
                            allReactionsAreAvailable = false
                        case .all:
                            allReactionsAreAvailable = true
                        }
                        
                        if let channel = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, case .broadcast = channel.info {
                            allReactionsAreAvailable = false
                        }
                        
                        let premiumConfiguration = PremiumConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
                        if premiumConfiguration.isPremiumDisabled {
                            allReactionsAreAvailable = false
                        }
                        
                        if allReactionsAreAvailable {
                            actions.getEmojiContent = { [weak self] animationCache, animationRenderer in
                                guard let self else {
                                    preconditionFailure()
                                }
                                
                                return EmojiPagerContentComponent.emojiInputData(
                                    context: self.context,
                                    animationCache: animationCache,
                                    animationRenderer: animationRenderer,
                                    isStandalone: false,
                                    subject: message.areReactionsTags(accountPeerId: self.context.account.peerId) ? .messageTag : .reaction(onlyTop: false),
                                    hasTrending: false,
                                    topReactionItems: reactionItems,
                                    areUnicodeEmojiEnabled: false,
                                    areCustomEmojiEnabled: true,
                                    chatPeerId: self.chatLocation.peerId,
                                    selectedItems: selectedReactions.files
                                )
                            }
                        } else if reactionItems.count > 16 {
                            actions.getEmojiContent = { [weak self] animationCache, animationRenderer in
                                guard let self else {
                                    preconditionFailure()
                                }
                                
                                return EmojiPagerContentComponent.emojiInputData(
                                    context: self.context,
                                    animationCache: animationCache,
                                    animationRenderer: animationRenderer,
                                    isStandalone: false,
                                    subject: .reaction(onlyTop: true),
                                    hasTrending: false,
                                    topReactionItems: reactionItems,
                                    areUnicodeEmojiEnabled: false,
                                    areCustomEmojiEnabled: false,
                                    chatPeerId: self.chatLocation.peerId,
                                    selectedItems: selectedReactions.files
                                )
                            }
                        }
                    }
                }
                
                self.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
                
                let presentationContext = self.controllerInteraction?.presentationContext
                
                var disableTransitionAnimations = false
                var actionsSignal: Signal<ContextController.Items, NoError> = .single(actions)
                if let entitiesAttribute = message.textEntitiesAttribute {
                    var emojiFileIds: [Int64] = []
                    for entity in entitiesAttribute.entities {
                        if case let .CustomEmoji(_, fileId) = entity.type {
                            emojiFileIds.append(fileId)
                        }
                    }
                    
                    let premiumConfiguration = PremiumConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
                    
                    if !emojiFileIds.isEmpty && !premiumConfiguration.isPremiumDisabled {
                        tip = .animatedEmoji(text: nil, arguments: nil, file: nil, action: nil)
                        actions.tip = tip
                        disableTransitionAnimations = true
                        
                        let context = self.context
                        actionsSignal = .single(actions)
                        |> then(
                            context.engine.stickers.resolveInlineStickers(fileIds: emojiFileIds)
                            |> mapToSignal { files -> Signal<ContextController.Items, NoError> in
                                var packReferences: [StickerPackReference] = []
                                var existingIds = Set<Int64>()
                                for (_, file) in files {
                                    loop: for attribute in file.attributes {
                                        if case let .CustomEmoji(_, _, _, packReference) = attribute, let packReference = packReference {
                                            if case let .id(id, _) = packReference, !existingIds.contains(id) {
                                                packReferences.append(packReference)
                                                existingIds.insert(id)
                                            }
                                            break loop
                                        }
                                    }
                                }
                                
                                let action = { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    self.presentEmojiList(references: packReferences)
                                }
                                
                                if packReferences.count > 1 {
                                    actions.tip = .animatedEmoji(text: presentationData.strings.ChatContextMenu_EmojiSet(Int32(packReferences.count)), arguments: nil, file: nil, action: action)
                                    return .single(actions)
                                } else if let reference = packReferences.first {
                                    return context.engine.stickers.loadedStickerPack(reference: reference, forceActualized: false)
                                    |> filter { result in
                                        if case .result = result {
                                            return true
                                        } else {
                                            return false
                                        }
                                    }
                                    |> mapToSignal { result in
                                        if case let .result(info, items, _) = result, let presentationContext = presentationContext {
                                            actions.tip = .animatedEmoji(
                                                text: presentationData.strings.ChatContextMenu_EmojiSetSingle(info.title).string,
                                                arguments: TextNodeWithEntities.Arguments(
                                                    context: context,
                                                    cache: presentationContext.animationCache,
                                                    renderer: presentationContext.animationRenderer,
                                                    placeholderColor: .clear,
                                                    attemptSynchronous: true
                                                ),
                                                file: items.first?.file._parse(),
                                                action: action)
                                            return .single(actions)
                                        } else {
                                            return .complete()
                                        }
                                    }
                                } else {
                                    actions.tip = nil
                                    return .single(actions)
                                }
                            }
                        )
                    }
                }
                
                var keepDefaultContentTouches = false
                for media in message.media {
                    if media is TelegramMediaImage {
                        keepDefaultContentTouches = true
                    } else if let file = media as? TelegramMediaFile, file.isVideo {
                        keepDefaultContentTouches = true
                    }
                }
                
                let source: ContextContentSource
                if let location = location {
                    source = .location(ChatMessageContextLocationContentSource(controller: self, location: node.view.convert(node.bounds, to: nil).origin.offsetBy(dx: location.x, dy: location.y)))
                } else {
                    source = .extracted(ChatMessageContextExtractedContentSource(chatController: self, chatNode: self.chatDisplayNode, engine: self.context.engine, message: message, selectAll: selectAll, keepDefaultContentTouches: keepDefaultContentTouches))
                }
                
                self.canReadHistory.set(false)

                // VoiceOver: пока открыто контекстное меню сообщения, история
                // НЕ должна вмешиваться в фокус. Иначе при открытии меню лента
                // перестраивается, сфокусированное сообщение recycled →
                // containment-проверка срабатывает и forward-escape redirect
                // утаскивает курсор на поле ввода, перебивая фокус панели
                // реакций / пунктов меню. Приостанавливаем на время показа меню.
                self.chatDisplayNode.historyNode.accessibilityFocusHandlingSuspended = true
                // VoiceOver: меню сообщения показывается в глобальном оверлее и НЕ модально,
                // поэтому VO продолжает обходить историю чата под ним. `customAccessibilityElements`,
                // возвращая nil, не помогает — UIKit тогда сам перечисляет сырые сабвью бабблов, и VO
                // обходит это огромное дерево на КАЖДЫЙ свайп по пунктам меню → долгий отклик/лаги.
                // Полностью убираем поддерево истории из доступности на время показа меню
                // (`accessibilityElementsHidden` скрывает и детей). Снимаем в `dismissed`.
                self.chatDisplayNode.historyNode.view.accessibilityElementsHidden = true

                var hideReactionPanelTail = false
                for media in message.media {
                    if let action = media as? TelegramMediaAction {
                        switch action.action {
                        case .phoneCall:
                            break
                        case .conferenceCall:
                            break
                        default:
                            hideReactionPanelTail = true
                        }
                    }
                }
                
                let isSecret = self.presentationInterfaceState.copyProtectionEnabled || self.chatLocation.peerId?.namespace == Namespaces.Peer.SecretChat
                // VoiceOver: пункт «Реакции» из свайпа вниз — показываем ТОЛЬКО
                // панель выбора реакций, без пунктов контекстного меню: лишние
                // пункты сбивают при свайп-обходе. Флаг ставится нодой
                // сообщения непосредственно перед вызовом, читаем его до
                // потребления в animateIn.
                var effectiveActionsSignal = actionsSignal
                var voReactionsOnlyMode = false
                if ContextController.accessibilityFocusReactionsOnNextPresent, UIAccessibility.isVoiceOverRunning {
                    voReactionsOnlyMode = true
                    effectiveActionsSignal = actionsSignal
                    |> map { items -> ContextController.Items in
                        var items = items
                        items.content = .list([])
                        items.tip = nil
                        items.tipSignal = nil
                        return items
                    }
                }
                let controller = ContextController(presentationData: self.presentationData, source: source, items: effectiveActionsSignal, recognizer: recognizer, gesture: gesture, disableScreenshots: isSecret, hideReactionPanelTail: hideReactionPanelTail)
                // VoiceOver: возврат курсора на сообщение после закрытия меню.
                // В режиме «только реакции» ставим сразу — закрытие БЕЗ выбора
                // (зона «Закрыть меню», тап по фону) возвращает курсор на
                // сообщение. При ВЫБОРЕ реакции reactionSelected сбрасывает
                // возврат: явный фокус заставлял VO зачитывать всё сообщение
                // заново поверх подтверждения — остаётся только озвучка
                // «Реакция проставлена». (Выбрать программно пункт ротора
                // «Реакции» iOS не позволяет — ротор сбрасывается на начало.)
                var voReturnFocusToMessageId: MessageId?
                if voReactionsOnlyMode {
                    voReturnFocusToMessageId = message.id
                }
                // VoiceOver: текст подтверждения выбора реакции — постится в
                // dismissed, обрывая системное перечитывание сообщения.
                var voReactionAnnouncement: String?
                controller.dismissed = { [weak self] in
                    self?.canReadHistory.set(true)
                    // Страховка: в режиме «только реакции» стек пунктов меню
                    // (штатный потребитель one-shot флага) может не создаться —
                    // не даём флагу протечь в следующее открытие меню.
                    ContextController.accessibilityFocusReactionsOnNextPresent = false
                    // Возвращаем focus-обработку истории после закрытия меню.
                    self?.chatDisplayNode.historyNode.accessibilityFocusHandlingSuspended = false
                    self?.chatDisplayNode.historyNode.view.accessibilityElementsHidden = false
                    // VoiceOver: подтверждение выбора реакции — после закрытия
                    // панели iOS восстанавливает фокус на сообщение и начинает
                    // зачитывать его заново; анонс через 0.8 с ОБРЫВАЕТ это
                    // перечитывание. На iOS 17+ анонс дополнительно помечен
                    // высоким приоритетом — его не перебьёт другая речь.
                    if let announcement = voReactionAnnouncement {
                        voReactionAnnouncement = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            let argument: Any
                            if #available(iOS 17.0, *) {
                                argument = NSAttributedString(string: announcement, attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high])
                            } else {
                                argument = announcement
                            }
                            UIAccessibility.post(notification: .announcement, argument: argument)
                        }
                    }
                    if let self, let messageId = voReturnFocusToMessageId, UIAccessibility.isVoiceOverRunning {
                        voReturnFocusToMessageId = nil
                        var targetView: UIView?
                        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                            if targetView == nil, let itemNode = itemNode as? ChatMessageItemView, itemNode.item?.message.id == messageId {
                                targetView = itemNode.view
                            }
                        }
                        if let targetView {
                            // Даём дереву доступности восстановиться после
                            // accessibilityElementsHidden = false, затем ставим
                            // курсор обратно на сообщение.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak targetView] in
                                if let targetView {
                                    UIAccessibility.post(notification: .layoutChanged, argument: targetView)
                                }
                            }
                        }
                    }
                }
                controller.immediateItemsTransitionAnimation = disableTransitionAnimations
                self.currentContextController = controller
                
                controller.premiumReactionsSelected = { [weak self, weak controller] in
                    guard let self else {
                        return
                    }
                    
                    controller?.dismissWithoutContent()
                    guard !self.presentAccountFrozenInfoIfNeeded(delay: true) else {
                        return
                    }
                    self.presentTagPremiumPaywall()
                }
                
                controller.reactionSelected = { [weak self, weak controller] chosenUpdatedReaction, isLarge in
                    guard let self else {
                        return
                    }
                    
                    guard !self.presentAccountFrozenInfoIfNeeded(delay: true) else {
                        controller?.dismiss(completion: {})
                        return
                    }
                    
                    guard let message = messages.first else {
                        return
                    }

                    // VoiceOver: запоминаем текст подтверждения — прозвучит он
                    // в dismissed, ПОСЛЕ закрытия панели. Порядок важен: iOS
                    // при закрытии оверлея сама восстанавливает фокус на
                    // сообщение и начинает зачитывать его заново; анонс,
                    // запощенный здесь (до закрытия), этим чтением перебивался.
                    // Отложенный анонс наоборот ОБРЫВАЕТ начатое перечитывание.
                    if UIAccessibility.isVoiceOverRunning {
                        var isRemoval = false
                        if let reactionsAttribute = message.reactionsAttribute {
                            isRemoval = reactionsAttribute.reactions.contains(where: { $0.value == chosenUpdatedReaction.reaction && $0.isSelected })
                        }
                        let isRu = self.presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
                        if isRemoval {
                            voReactionAnnouncement = isRu ? "Реакция снята" : "Reaction removed"
                        } else {
                            voReactionAnnouncement = isRu ? "Реакция проставлена" : "Reaction set"
                        }
                        // Выбор состоялся — курсор на сообщение не возвращаем.
                        voReturnFocusToMessageId = nil
                    }

                    controller?.view.endEditing(true)
                    
                    if case .stars = chosenUpdatedReaction.reaction {
                        if isLarge {
                            if let controller {
                                controller.dismiss(completion: { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    self.openMessageSendStarsScreen(message: message)
                                })
                            }
                            return
                        }
                        
                        let isFirst = !"".isEmpty
                        
                        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                                if item.message.id == message.id {
                                    let chosenReaction: MessageReaction.Reaction = .stars
                                    itemNode.awaitingAppliedReaction = (chosenReaction, { [weak self, weak itemNode] in
                                        guard let self, let controller = controller else {
                                            return
                                        }
                                        if let itemNode = itemNode, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                            self.chatDisplayNode.messageTransitionNode.addMessageContextController(messageId: item.message.id, contextController: controller)
                                            
                                            var hideTargetButton: UIView?
                                            if isFirst {
                                                hideTargetButton = targetView.superview
                                            }
                                            
                                            controller.dismissWithReaction(value: chosenReaction, targetView: targetView, hideNode: true, animateTargetContainer: hideTargetButton, addStandaloneReactionAnimation: { [weak self] standaloneReactionAnimation in
                                                guard let self else {
                                                    return
                                                }
                                                self.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                                standaloneReactionAnimation.frame = self.chatDisplayNode.bounds
                                                self.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                            }, onHit: { [weak self, weak itemNode] in
                                                guard let self else {
                                                    return
                                                }
                                                if let itemNode = itemNode, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                                    if !"".isEmpty {
                                                        if self.context.sharedContext.energyUsageSettings.fullTranslucency {
                                                            self.chatDisplayNode.wrappingNode.triggerRipple(at: targetView.convert(targetView.bounds.center, to: self.chatDisplayNode.view))
                                                        }
                                                    }
                                                }
                                            }, completion: {})
                                        } else {
                                            controller.dismiss()
                                        }
                                    })
                                }
                            }
                        }
                        
                        guard let starsContext = self.context.starsContext else {
                            return
                        }
                        let _ = (combineLatest(
                            starsContext.state,
                            self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.ReactionSettings(id: message.id.peerId))
                        )
                        |> take(1)
                        |> deliverOnMainQueue).start(next: { [weak self] state, reactionSettings in
                            guard let strongSelf = self, let balance = state?.balance else {
                                return
                            }
                            
                            if case let .known(reactionSettings) = reactionSettings, let starsAllowed = reactionSettings.starsAllowed, !starsAllowed {
                                if let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer {
                                    strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: nil, text: strongSelf.presentationData.strings.Chat_ToastStarsReactionsDisabled(peer.debugDisplayTitle).string, actions: [
                                        TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_OK, action: {})
                                    ]), in: .window(.root))
                                }
                                return
                            }
                            
                            if balance < StarsAmount(value: 1, nanos: 0) {
                                controller?.dismiss(completion: {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    
                                    let _ = (strongSelf.context.engine.payments.starsTopUpOptions()
                                    |> take(1)
                                    |> deliverOnMainQueue).startStandalone(next: { [weak strongSelf] options in
                                        guard let strongSelf else {
                                            return
                                        }
                                        guard let starsContext = strongSelf.context.starsContext else {
                                            return
                                        }
                                        
                                        let purchaseScreen = strongSelf.context.sharedContext.makeStarsPurchaseScreen(context: strongSelf.context, starsContext: starsContext, options: options, purpose: .reactions(peerId: message.id.peerId, requiredStars: 1), targetPeerId: nil, customTheme: nil, completion: { result in
                                            let _ = result
                                        })
                                        strongSelf.push(purchaseScreen)
                                    })
                                })
                                
                                return
                            }
                            
                            let _ = (strongSelf.context.engine.messages.sendStarsReaction(id: message.id, count: 1, privacy: nil)
                            |> deliverOnMainQueue).startStandalone(next: { privacy in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.displayOrUpdateSendStarsUndo(messageId: message.id, count: 1, privacy: privacy)
                            })
                        })
                    } else {
                        let chosenReaction: MessageReaction.Reaction = chosenUpdatedReaction.reaction
                        
                        let currentReactions = mergedMessageReactions(attributes: message.attributes, isTags: message.areReactionsTags(accountPeerId: self.context.account.peerId))?.reactions ?? []
                        var updatedReactions: [MessageReaction.Reaction] = currentReactions.filter(\.isSelected).map(\.value)
                        var removedReaction: MessageReaction.Reaction?
                        var isFirst = false
                        
                        if let index = updatedReactions.firstIndex(where: { $0 == chosenReaction }) {
                            removedReaction = chosenReaction
                            updatedReactions.remove(at: index)
                        } else {
                            updatedReactions.append(chosenReaction)
                            isFirst = !currentReactions.contains(where: { $0.value == chosenReaction })
                        }
                        
                        if message.areReactionsTags(accountPeerId: self.context.account.peerId) {
                            if removedReaction == nil, !topReactions.contains(where: { $0.reaction.rawValue == chosenReaction }) {
                                if !self.presentationInterfaceState.isPremium {
                                    controller?.premiumReactionsSelected?()
                                    return
                                }
                            }
                        } else {
                            if removedReaction == nil, case .custom = chosenReaction {
                                if let peer = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = peer.info {
                                } else {
                                    if !self.presentationInterfaceState.isPremium {
                                        controller?.premiumReactionsSelected?()
                                        return
                                    }
                                }
                            }
                        }
                        
                        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                                if item.message.id == message.id {
                                    if removedReaction == nil && !updatedReactions.isEmpty {
                                        itemNode.awaitingAppliedReaction = (chosenReaction, { [weak self, weak itemNode] in
                                            guard let self, let controller = controller else {
                                                return
                                            }
                                            if let itemNode = itemNode, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                                self.chatDisplayNode.messageTransitionNode.addMessageContextController(messageId: item.message.id, contextController: controller)
                                                
                                                var hideTargetButton: UIView?
                                                if isFirst {
                                                    hideTargetButton = targetView.superview
                                                }
                                                
                                                controller.dismissWithReaction(value: chosenReaction, targetView: targetView, hideNode: true, animateTargetContainer: hideTargetButton, addStandaloneReactionAnimation: { [weak self] standaloneReactionAnimation in
                                                    guard let self else {
                                                        return
                                                    }
                                                    self.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                                    standaloneReactionAnimation.frame = self.chatDisplayNode.bounds
                                                    self.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                                }, onHit: nil, completion: { [weak self, weak itemNode, weak targetView] in
                                                    guard let self, let itemNode, let targetView else {
                                                        return
                                                    }
                                                    
                                                    if self.chatLocation.peerId == self.context.account.peerId {
                                                        let _ = (ApplicationSpecificNotice.getSavedMessageTagLabelSuggestion(accountManager: self.context.sharedContext.accountManager)
                                                                 |> take(1)
                                                                 |> deliverOnMainQueue).startStandalone(next: { [weak self, weak targetView, weak itemNode] value in
                                                            guard let self, let targetView, let itemNode else {
                                                                return
                                                            }
                                                            if value >= 3 {
                                                                return
                                                            }
                                                            
                                                            let _ = itemNode
                                                            
                                                            let rect = self.chatDisplayNode.view.convert(targetView.bounds, from: targetView).insetBy(dx: -8.0, dy: -8.0)
                                                            let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .plain(text: self.presentationData.strings.Chat_TooltipAddTagLabel), location: .point(rect, .bottom), displayDuration: .manual, shouldDismissOnTouch: { _, _ in
                                                                return .dismiss(consume: false)
                                                            })
                                                            self.present(tooltipScreen, in: .current)
                                                            
                                                            let _ = ApplicationSpecificNotice.incrementSavedMessageTagLabelSuggestion(accountManager: self.context.sharedContext.accountManager).startStandalone()
                                                        })
                                                    }
                                                })
                                            } else {
                                                controller.dismiss()
                                            }
                                        })
                                    } else {
                                        itemNode.awaitingAppliedReaction = (nil, {
                                            controller?.dismiss()
                                        })
                                    }
                                }
                            }
                        }
                        
                        let mappedUpdatedReactions = updatedReactions.map { reaction -> UpdateMessageReaction in
                            switch reaction {
                            case let .builtin(value):
                                return .builtin(value)
                            case let .custom(fileId):
                                var customFile: TelegramMediaFile?
                                if case let .custom(customFileId, file) = chosenUpdatedReaction, fileId == customFileId {
                                    customFile = file
                                }
                                return .custom(fileId: fileId, file: customFile)
                            case .stars:
                                return .stars
                            }
                        }
                        
                        // VoiceOver: озвучиваем результат («Реакция ❤️ проставлена/снята»).
                        voAnnounceReactionUpdate(reaction: chosenReaction, message: message, removed: removedReaction != nil, languageCode: self.presentationData.strings.baseLanguageCode)
                        let _ = updateMessageReactionsInteractively(account: self.context.account, messageIds: [message.id], reactions: mappedUpdatedReactions, isLarge: isLarge, storeAsRecentlyUsed: true).startStandalone()
                    }
                }

                self.forEachController({ controller in
                    if let controller = controller as? TooltipScreen {
                        controller.dismiss()
                    }
                    return true
                })
                self.window?.presentInGlobalOverlay(controller)
            })
        }
    }
}

final class ChatContextControllerContentSourceImpl: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    weak var sourceView: UIView?
    let sourceRect: CGRect?
    
    let navigationController: NavigationController? = nil

    let passthroughTouches: Bool
    
    init(controller: ViewController, sourceNode: ASDisplayNode?, sourceRect: CGRect? = nil, passthroughTouches: Bool) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.sourceRect = sourceRect
        self.passthroughTouches = passthroughTouches
    }
    
    init(controller: ViewController, sourceView: UIView?, sourceRect: CGRect? = nil, passthroughTouches: Bool) {
        self.controller = controller
        self.sourceView = sourceView
        self.sourceRect = sourceRect
        self.passthroughTouches = passthroughTouches
    }
    
    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceView = self.sourceView
        let sourceNode = self.sourceNode
        let sourceRect = self.sourceRect
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceView = sourceView {
                return (sourceView, sourceRect ?? sourceView.bounds)
            } else if let sourceNode = sourceNode {
                return (sourceNode.view, sourceRect ?? sourceNode.bounds)
            } else {
                return nil
            }
        })
    }
    
    func animatedIn() {
    }
}

final class ChatControllerContextReferenceContentSource: ContextReferenceContentSource {
    let controller: ViewController
    let sourceView: UIView
    let insets: UIEdgeInsets
    let contentInsets: UIEdgeInsets
    
    init(controller: ViewController, sourceView: UIView, insets: UIEdgeInsets, contentInsets: UIEdgeInsets = UIEdgeInsets()) {
        self.controller = controller
        self.sourceView = sourceView
        self.insets = insets
        self.contentInsets = contentInsets
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds.inset(by: self.insets), insets: self.contentInsets)
    }
}

/// VoiceOver: озвучивает установку/снятие реакции («Реакция ❤️ проставлена»).
/// Используется обоими путями выбора реакции: из панели контекстного меню
/// (reactionSelected выше) и из блока «Реакции и просмотры» в роторе сообщения
/// (updateMessageReaction в ChatController).
func voAnnounceReactionUpdate(reaction: MessageReaction.Reaction, message: Message, removed: Bool, languageCode: String) {
    guard UIAccessibility.isVoiceOverRunning else {
        return
    }
    let isRu = languageCode.lowercased().hasPrefix("ru")
    let title: String
    switch reaction {
    case let .builtin(emoji):
        title = emoji
    case let .custom(fileId):
        var alt: String?
        if let file = message.associatedMedia[MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile {
            attributeLoop: for attribute in file.attributes {
                if case let .CustomEmoji(_, _, altValue, _) = attribute, !altValue.isEmpty {
                    alt = altValue
                    break attributeLoop
                }
            }
        }
        title = alt ?? (isRu ? "эмодзи" : "emoji")
    case .stars:
        title = isRu ? "Звёзды" : "Stars"
    }
    let text: String
    if isRu {
        text = removed ? "Реакция \(title) снята" : "Реакция \(title) проставлена"
    } else {
        text = removed ? "Reaction \(title) removed" : "Reaction \(title) set"
    }
    // Задержка, чтобы объявление не перебилось системной озвучкой активации
    // действия / закрытия меню (иначе VO проглатывает announcement).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
