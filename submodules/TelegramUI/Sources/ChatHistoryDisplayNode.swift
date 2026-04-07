import Foundation
import QuartzCore
import UIKit
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import Display
import AccountContext
import TelegramCore
import TelegramPresentationData
import ChatControllerInteraction
import ChatHistoryEntry
import ChatMessageItemView
import ChatMessageItemImpl

/// Forwards window attachment so deferred `reloadData` runs only after UIKit has a real hierarchy (avoids layout-outside-window warnings).
private final class ChatHistoryTableView: UITableView {
    weak var historyHost: ChatHistoryListNodeImpl?
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil {
            self.historyHost?.historyTableDidAttachToWindow()
        }
    }
}

private final class ChatHistoryHostedCell: UITableViewCell {
    private let containerNode = ASDisplayNode()
    var itemNode: ListViewItemNode?
    var currentStableId: UInt64?
    var isReversed = false {
        didSet {
            self.contentView.transform = self.isReversed ? CGAffineTransform(scaleX: 1.0, y: -1.0) : .identity
        }
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none
        self.clipsToBounds = true
        self.contentView.clipsToBounds = true
        self.containerNode.clipsToBounds = true
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
        if let subnodes = self.containerNode.subnodes {
            for sub in Array(subnodes) {
                sub.removeFromSupernode()
            }
        }
        self.itemNode = nil
        self.currentStableId = nil
        self.accessibilityCustomActions = nil
        self.isAccessibilityElement = false
        self.accessibilityLabel = nil
        self.accessibilityValue = nil
        self.accessibilityTraits = .none
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

private struct ChatHistoryTableRow {
    let stableId: UInt64
    let item: ListViewItem
    var approximateHeight: CGFloat
}

/// Must match `measuredHeight` / `syncConfigureCachedHistoryCell`: constraining `availableHeight` to the
/// current row height makes channel posts layout as if space were truncated (bubble vs reactions split apart).
private let chatHistoryTableLayoutUnboundedHeight: CGFloat = 10000.0

public final class ChatHistoryListNodeImpl: LegacyChatHistoryListNodeImpl {
    typealias SnapshotState = LegacyChatHistoryListNodeImpl.SnapshotState
    
    private let tableView = ChatHistoryTableView(frame: .zero, style: .plain)
    private var tableRows: [ChatHistoryTableRow] = []
    private var nodeCache: [UInt64: ListViewItemNode] = [:]
    private var heightCache: [UInt64: CGFloat] = [:]
    private var isSyncingFromLegacy = false
    private var isSyncingToLegacy = false
    private var latestHistoryView: ChatHistoryView?
    private var tableOffsetObservation: NSKeyValueObservation?
    /// Debounced row reloads so bursts of height corrections collapse into one pass (avoids empty `performBatchUpdates` fighting scroll).
    private var tableHeightRefreshWorkItem: DispatchWorkItem?
    private var pendingHeightReloadIndexPaths: Set<IndexPath> = []
    /// Defer `UITableView.reloadData()` until the table is in a window with non-zero bounds (avoids UIKit “layout without being in the view hierarchy”).
    private var deferredHistoryTableReload = false
    
    /// Row order matches `ListView` item indices (item 0 ↔ last filtered entry, see `count - 1 - i` mapping in `LegacyChatHistoryListNodeImpl`).
    private var isTableRowOrderReversedFromHistoryEntries: Bool {
        if self.rotated {
            return true
        }
        if case let .list(_, reversed, _, _, _, _) = self.mode, reversed {
            return true
        }
        return false
    }
    
    /// `UITableView` vertical flip: only when the node is **not** already π-rotated. Bubbles chat uses `self.transform = π` on the list node; adding `scaleY(-1)` on the table inverts pan vs the sibling `scroller` and feels “wrong-way” scroll.
    private var needsUITableViewVerticalFlipTransform: Bool {
        if self.rotated {
            return false
        }
        if case let .list(_, reversed, _, _, _, _) = self.mode, reversed {
            return true
        }
        return false
    }
    
    public override init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>), chatLocation: ChatLocation, chatLocationContextHolder: Atomic<ChatLocationContextHolder?>, adMessagesContext: AdMessagesHistoryContext?, tag: HistoryViewInputTag?, source: ChatHistoryListSource, subject: ChatControllerSubject?, controllerInteraction: ChatControllerInteraction, selectedMessages: Signal<Set<MessageId>?, NoError>, mode: ChatHistoryListMode = .bubbles, rotated: Bool = false, isChatPreview: Bool, messageTransitionNode: @escaping () -> ChatMessageTransitionNodeImpl?) {
        super.init(
            context: context,
            updatedPresentationData: updatedPresentationData,
            chatLocation: chatLocation,
            chatLocationContextHolder: chatLocationContextHolder,
            adMessagesContext: adMessagesContext,
            tag: tag,
            source: source,
            subject: subject,
            controllerInteraction: controllerInteraction,
            selectedMessages: selectedMessages,
            mode: mode,
            rotated: rotated,
            isChatPreview: isChatPreview,
            messageTransitionNode: messageTransitionNode
        )
        
        self.tableView.historyHost = self
        self.tableView.backgroundColor = .clear
        self.tableView.separatorStyle = .none
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.showsVerticalScrollIndicator = true
        self.tableView.register(ChatHistoryHostedCell.self, forCellReuseIdentifier: "history")
        if self.needsUITableViewVerticalFlipTransform {
            self.tableView.transform = CGAffineTransform(scaleX: 1.0, y: -1.0)
        }
        self.view.addSubview(self.tableView)
        self.view.bringSubviewToFront(self.tableView)
        
        self.scroller.alpha = 0.0
        self.scroller.isHidden = true
        self.scroller.isUserInteractionEnabled = false
        self.scroller.accessibilityElementsHidden = true
        
        self.historyListViewTransitionUpdated = { [weak self] transition in
            self?.latestHistoryView = transition.historyView
            self?.rebuildTableRows(from: transition.historyView)
            self?.scheduleSyncTableFromLegacy()
            self?.suppressLegacyListViewRendering()
        }
        
        self.automaticallyAppliesExternalScrollHostSuppression = true
        
        self.tableOffsetObservation = self.tableView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            guard let self, !self.isSyncingFromLegacy else {
                return
            }
            self.view.bringSubviewToFront(self.tableView)
            let tableOffset = self.tableView.contentOffset
            let scrollerOffset = self.scroller.contentOffset
            if abs(tableOffset.y - scrollerOffset.y) < 0.5 && abs(tableOffset.x - scrollerOffset.x) < 0.5 {
                return
            }
            self.isSyncingToLegacy = true
            self.scroller.setContentOffset(tableOffset, animated: false)
            self.isSyncingToLegacy = false
        }
        
        Queue.mainQueue().async { [weak self] in
            self?.suppressLegacyListViewRendering()
        }
    }
    
    /// `ListView` still builds and lays out item subtrees for scroll/logic; those layers are siblings of `UITableView` on `self.view` and would keep drawing (and can be brought in front). Hide managed presentation so only the table-backed copy is visible.
    private func suppressLegacyListViewRendering() {
        self.suppressManagedPresentationForExternalScrollHost()
        self.view.bringSubviewToFront(self.tableView)
    }
    
    private var canLayOutHistoryTableContent: Bool {
        guard self.view.window != nil, self.tableView.window != nil else {
            return false
        }
        guard self.view.superview != nil, self.tableView.superview != nil else {
            return false
        }
        return self.tableView.bounds.width >= 1.0 && self.tableView.bounds.height >= 1.0
    }
    
    private func flushOrDeferHistoryTableReload() {
        if self.canLayOutHistoryTableContent {
            self.deferredHistoryTableReload = false
            self.tableView.reloadData()
        } else {
            self.deferredHistoryTableReload = true
        }
    }
    
    private func flushDeferredHistoryTableReloadIfNeeded() {
        guard self.deferredHistoryTableReload, self.canLayOutHistoryTableContent else {
            return
        }
        self.deferredHistoryTableReload = false
        self.tableView.reloadData()
    }
    
    fileprivate func historyTableDidAttachToWindow() {
        self.flushDeferredHistoryTableReloadIfNeeded()
        self.suppressLegacyListViewRendering()
    }
    
    public override func layout() {
        super.layout()
        self.tableView.transform = self.needsUITableViewVerticalFlipTransform ? CGAffineTransform(scaleX: 1.0, y: -1.0) : .identity
        self.tableView.frame = self.bounds
        if let latestHistoryView, self.tableRows.isEmpty {
            self.rebuildTableRows(from: latestHistoryView)
        }
        if abs(self.tableView.contentOffset.y - self.scroller.contentOffset.y) > 0.5 || abs(self.tableView.contentOffset.x - self.scroller.contentOffset.x) > 0.5 {
            self.syncTableFromLegacy()
        }
        self.suppressLegacyListViewRendering()
        self.flushDeferredHistoryTableReloadIfNeeded()
    }
    
    public override func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets) {
        super.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        self.tableView.frame = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.tableView.contentInset = updateSizeAndInsets.insets
        self.tableView.scrollIndicatorInsets = updateSizeAndInsets.insets
        self.syncTableFromLegacy()
        self.suppressLegacyListViewRendering()
        self.flushDeferredHistoryTableReloadIfNeeded()
    }
    
    public override func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets, additionalScrollDistance: CGFloat, scrollToTop: Bool, completion: @escaping () -> Void) {
        super.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets, additionalScrollDistance: additionalScrollDistance, scrollToTop: scrollToTop, completion: completion)
        self.tableView.frame = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.tableView.contentInset = updateSizeAndInsets.insets
        self.tableView.scrollIndicatorInsets = updateSizeAndInsets.insets
        self.syncTableFromLegacy()
        self.suppressLegacyListViewRendering()
        self.flushDeferredHistoryTableReloadIfNeeded()
    }
    
    public override func scrollToEndOfHistory() {
        super.scrollToEndOfHistory()
        self.scheduleSyncTableFromLegacy()
    }
    
    public override func scrollToStartOfHistory() {
        super.scrollToStartOfHistory()
        self.scheduleSyncTableFromLegacy()
    }
    
    public override func scrollToMessage(from fromIndex: MessageIndex, to toIndex: MessageIndex, animated: Bool, highlight: Bool = true, quote: (string: String, offset: Int?)? = nil, todoTaskId: Int32? = nil, scrollPosition: ListViewScrollPosition = .center(.bottom), setupReply: Bool = false) {
        super.scrollToMessage(from: fromIndex, to: toIndex, animated: animated, highlight: highlight, quote: quote, todoTaskId: todoTaskId, scrollPosition: scrollPosition, setupReply: setupReply)
        self.scheduleSyncTableFromLegacy()
    }
    
    public override func scrollToMessage(index: MessageIndex) {
        super.scrollToMessage(index: index)
        self.scheduleSyncTableFromLegacy()
    }
    
    public override func scrollToNextMessage() {
        super.scrollToNextMessage()
        self.scheduleSyncTableFromLegacy()
    }
    
    private func scheduleSyncTableFromLegacy() {
        Queue.mainQueue().async { [weak self] in
            self?.syncTableFromLegacy()
        }
    }
    
    private func syncTableFromLegacy() {
        guard !self.isSyncingToLegacy else {
            return
        }
        let target = self.scroller.contentOffset
        let current = self.tableView.contentOffset
        if abs(current.y - target.y) < 0.5 && abs(current.x - target.x) < 0.5 {
            self.suppressLegacyListViewRendering()
            return
        }
        self.isSyncingFromLegacy = true
        self.tableView.setContentOffset(target, animated: false)
        self.isSyncingFromLegacy = false
        self.suppressLegacyListViewRendering()
    }
    
    private func measuredHeight(for item: ListViewItem, stableId: UInt64, previousItem: ListViewItem?, nextItem: ListViewItem?) -> CGFloat {
        if let cached = self.heightCache[stableId], cached > 0.0 {
            return cached
        }
        let width = max(1.0, self.tableView.bounds.width > 0.0 ? self.tableView.bounds.width : self.bounds.width)
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: chatHistoryTableLayoutUnboundedHeight)
        var measured = max(88.0, item.approximateHeight)
        item.nodeConfiguredForParams(async: { f in f() }, params: params, synchronousLoads: true, previousItem: previousItem, nextItem: nextItem, completion: { itemNode, _ in
            measured = max(measured, itemNode.contentSize.height + itemNode.insets.top + itemNode.insets.bottom)
        })
        self.heightCache[stableId] = measured
        return measured
    }
    
    private func actualNodeHeight(_ itemNode: ListViewItemNode, fallback: CGFloat) -> CGFloat {
        let measured = itemNode.contentSize.height + itemNode.insets.top + itemNode.insets.bottom
        return max(fallback, measured)
    }
    
    private func updateRowHeightIfNeeded(stableId: UInt64, measuredHeight: CGFloat) {
        guard let index = self.tableRows.firstIndex(where: { $0.stableId == stableId }) else {
            return
        }
        let current = self.tableRows[index].approximateHeight
        // Tight threshold: channel rows include reactions + discussion bar; missing even a few pt breaks alignment.
        guard abs(current - measuredHeight) > 1.0 else {
            return
        }
        self.tableRows[index].approximateHeight = measuredHeight
        self.heightCache[stableId] = measuredHeight
        self.pendingHeightReloadIndexPaths.insert(IndexPath(row: index, section: 0))
        self.enqueueCoalescedTableHeightRefresh()
    }
    
    private func cancelPendingTableHeightRefresh() {
        self.tableHeightRefreshWorkItem?.cancel()
        self.tableHeightRefreshWorkItem = nil
        self.pendingHeightReloadIndexPaths.removeAll()
    }
    
    private func enqueueCoalescedTableHeightRefresh() {
        self.tableHeightRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.tableHeightRefreshWorkItem = nil
            guard self.canLayOutHistoryTableContent else {
                return
            }
            let paths = Array(self.pendingHeightReloadIndexPaths).filter { path in
                path.section == 0 && path.row >= 0 && path.row < self.tableRows.count
            }
            self.pendingHeightReloadIndexPaths.removeAll()
            guard !paths.isEmpty else {
                return
            }
            UIView.performWithoutAnimation {
                self.tableView.reloadRows(at: paths, with: .none)
            }
        }
        self.tableHeightRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }
    
    private func rebuildTableRows(from historyView: ChatHistoryView) {
        self.cancelPendingTableHeightRefresh()
        self.heightCache.removeAll()
        let canReorder = historyView.filteredEntries.count > 1 && self.baseCanReorder
        let entries = self.isTableRowOrderReversedFromHistoryEntries ? Array(historyView.filteredEntries.reversed()) : historyView.filteredEntries
        var rows: [ChatHistoryTableRow] = []
        rows.reserveCapacity(entries.count)
        for i in 0 ..< entries.count {
            let entry = entries[i]
            let item = mappedChatHistoryEntryItem(context: self.context, chatLocation: self.chatLocation, associatedData: historyView.associatedData, controllerInteraction: self.controllerInteraction, mode: self.mode, lastHeaderId: historyView.lastHeaderId, isSavedMusic: self.currentIsSavedMusic, canReorder: canReorder, entry: entry)
            let previousItem = rows.last?.item
            let nextEntry = i + 1 < entries.count ? entries[i + 1] : nil
            let nextItem = nextEntry.flatMap { mappedChatHistoryEntryItem(context: self.context, chatLocation: self.chatLocation, associatedData: historyView.associatedData, controllerInteraction: self.controllerInteraction, mode: self.mode, lastHeaderId: historyView.lastHeaderId, isSavedMusic: self.currentIsSavedMusic, canReorder: canReorder, entry: $0) }
            let height = self.measuredHeight(for: item, stableId: entry.stableId, previousItem: previousItem, nextItem: nextItem)
            rows.append(ChatHistoryTableRow(stableId: entry.stableId, item: item, approximateHeight: height))
        }
        let newStableIds = Set(rows.map(\.stableId))
        self.nodeCache = self.nodeCache.filter { newStableIds.contains($0.key) }
        self.tableRows = rows
        self.flushOrDeferHistoryTableReload()
    }
    
    private func copyAccessibility(from itemNode: ListViewItemNode, to cell: ChatHistoryHostedCell) {
        cell.accessibilityCustomActions = itemNode.view.accessibilityCustomActions
        cell.isAccessibilityElement = itemNode.view.isAccessibilityElement
        cell.accessibilityLabel = itemNode.view.accessibilityLabel
        cell.accessibilityValue = itemNode.view.accessibilityValue
        cell.accessibilityTraits = itemNode.view.accessibilityTraits
    }
    
    /// Same idea as `ChatListTableNode`: avoid async `updateNode` for nodes whose `layoutForParams` fully refreshes content, so UITableView reuse cannot attach stale completions to the wrong row.
    private func supportsSyncHistoryCachedLayout(_ itemNode: ListViewItemNode) -> Bool {
        return itemNode is ChatMessageItemView || itemNode is ChatUnreadItemNode || itemNode is ChatReplyCountItemNode
    }
    
    private func syncConfigureCachedHistoryCell(
        cell: ChatHistoryHostedCell,
        row: ChatHistoryTableRow,
        itemNode: ListViewItemNode,
        tableView: UITableView,
        previousItem: ListViewItem?,
        nextItem: ListViewItem?
    ) -> Bool {
        guard self.supportsSyncHistoryCachedLayout(itemNode) else {
            return false
        }
        let width = max(1.0, tableView.bounds.width)
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: chatHistoryTableLayoutUnboundedHeight)
        itemNode.layoutForParams(params, item: row.item, previousItem: previousItem, nextItem: nextItem)
        let actualHeight = self.actualNodeHeight(itemNode, fallback: row.approximateHeight)
        itemNode.frame = CGRect(origin: .zero, size: CGSize(width: width, height: actualHeight))
        cell.setItemNode(itemNode)
        self.copyAccessibility(from: itemNode, to: cell)
        self.updateRowHeightIfNeeded(stableId: row.stableId, measuredHeight: actualHeight)
        return true
    }
    
    private func configureHistoryHostedCell(_ cell: ChatHistoryHostedCell, at indexPath: IndexPath, tableView: UITableView) {
        let row = self.tableRows[indexPath.row]
        let stableId = row.stableId
        cell.currentStableId = stableId
        
        let width = max(1.0, tableView.bounds.width)
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: chatHistoryTableLayoutUnboundedHeight)
        let previousItem = indexPath.row > 0 ? self.tableRows[indexPath.row - 1].item : nil
        let nextItem = indexPath.row + 1 < self.tableRows.count ? self.tableRows[indexPath.row + 1].item : nil
        
        if let cachedNode = self.nodeCache[stableId] {
            if self.syncConfigureCachedHistoryCell(cell: cell, row: row, itemNode: cachedNode, tableView: tableView, previousItem: previousItem, nextItem: nextItem) {
                return
            }
            row.item.updateNode(async: { $0() }, node: { cachedNode }, params: params, previousItem: previousItem, nextItem: nextItem, animation: .None, completion: { [weak self, weak cell] _, apply in
                apply(ListViewItemApply(isOnScreen: true))
                guard let self, let cell, cell.currentStableId == stableId else {
                    return
                }
                let actualHeight = self.actualNodeHeight(cachedNode, fallback: row.approximateHeight)
                cachedNode.frame = CGRect(origin: .zero, size: CGSize(width: max(1.0, tableView.bounds.width), height: actualHeight))
                cell.setItemNode(cachedNode)
                self.copyAccessibility(from: cachedNode, to: cell)
                self.updateRowHeightIfNeeded(stableId: stableId, measuredHeight: actualHeight)
            })
        } else {
            row.item.nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: true, previousItem: previousItem, nextItem: nextItem, completion: { [weak self, weak cell] itemNode, getApply in
                guard let self else {
                    return
                }
                let (_, apply) = getApply()
                apply(ListViewItemApply(isOnScreen: true))
                self.nodeCache[stableId] = itemNode
                guard let cell, cell.currentStableId == stableId else {
                    return
                }
                let actualHeight = self.actualNodeHeight(itemNode, fallback: row.approximateHeight)
                itemNode.frame = CGRect(origin: .zero, size: CGSize(width: max(1.0, tableView.bounds.width), height: actualHeight))
                cell.setItemNode(itemNode)
                self.copyAccessibility(from: itemNode, to: cell)
                self.updateRowHeightIfNeeded(stableId: stableId, measuredHeight: actualHeight)
            })
        }
    }
}

extension ChatHistoryListNodeImpl: UITableViewDataSource, UITableViewDelegate, UIScrollViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.tableRows.count
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return self.tableRows[indexPath.row].approximateHeight
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "history", for: indexPath) as! ChatHistoryHostedCell
        cell.isReversed = self.needsUITableViewVerticalFlipTransform
        self.configureHistoryHostedCell(cell, at: indexPath, tableView: tableView)
        return cell
    }
}
