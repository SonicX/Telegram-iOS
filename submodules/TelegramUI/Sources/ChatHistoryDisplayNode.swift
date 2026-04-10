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
        self.evictItemSubtreeForOffScreenMemory()
    }
    
    /// Drop hosted nodes while the cell is off-screen so `ListViewItemNode` / video decode (`FFMpegMediaFrameSource`) can deallocate. UITableView reuse alone keeps a strong ref until the next `prepareForReuse`.
    fileprivate func evictItemSubtreeForOffScreenMemory() {
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
        self.accessibilityElements = nil
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
    
    /// VoiceOver uses the cell as one focus per row; activation should still hit the hosted message node.
    override func accessibilityActivate() -> Bool {
        if let view = self.itemNode?.view, view.accessibilityActivate() {
            return true
        }
        return super.accessibilityActivate()
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
    /// Coalesces row height corrections onto the next main-queue turn (same-tick bursts merge into one `reloadRows`).
    private var tableHeightRefreshWorkItem: DispatchWorkItem?
    /// Rows whose `approximateHeight` changed and need a UITableView pass (prefer `reloadRows` over global `beginUpdates`/`endUpdates`).
    private var pendingHeightReloadRowIndices: Set<Int> = []
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
    
    /// Window + superview checks, and **list node** non-zero bounds. Do not require `tableView.bounds`
    /// here — `frame` is assigned inside `layout`/`updateLayout` only when this is true; using
    /// `tableView.bounds` created a deadlock (zero table frame → never reload → empty chat).
    private var canLayOutHistoryTableContent: Bool {
        guard self.view.window != nil, self.tableView.window != nil else {
            return false
        }
        guard self.view.superview != nil, self.tableView.superview != nil else {
            return false
        }
        return self.bounds.width >= 1.0 && self.bounds.height >= 1.0
    }
    
    /// `reloadData()` resets `UITableView` scroll state; `ListView` already updated `scroller` for history transitions (e.g. loading older messages). Resync immediately to avoid a visible jump/gap.
    private func reloadHistoryTableDataPreservingLegacyScroll() {
        guard self.canLayOutHistoryTableContent else {
            if !self.tableRows.isEmpty {
                self.deferredHistoryTableReload = true
            }
            return
        }
        self.tableView.reloadData()
        self.tableView.layoutIfNeeded()
        self.syncTableFromLegacy()
        Queue.mainQueue().async { [weak self] in
            self?.syncTableFromLegacy()
        }
    }
    
    private func flushOrDeferHistoryTableReload() {
        if self.canLayOutHistoryTableContent {
            self.deferredHistoryTableReload = false
            self.reloadHistoryTableDataPreservingLegacyScroll()
        } else {
            self.deferredHistoryTableReload = true
        }
    }
    
    private func flushDeferredHistoryTableReloadIfNeeded() {
        guard self.deferredHistoryTableReload, self.canLayOutHistoryTableContent else {
            return
        }
        self.deferredHistoryTableReload = false
        self.reloadHistoryTableDataPreservingLegacyScroll()
    }
    
    fileprivate func historyTableDidAttachToWindow() {
        self.flushDeferredHistoryTableReloadIfNeeded()
        self.suppressLegacyListViewRendering()
        Queue.mainQueue().async { [weak self] in
            guard let self else {
                return
            }
            self.flushDeferredHistoryTableReloadIfNeeded()
            self.suppressLegacyListViewRendering()
        }
    }
    
    public override func layout() {
        super.layout()
        if let latestHistoryView, self.tableRows.isEmpty {
            self.rebuildTableRows(from: latestHistoryView)
        }
        guard self.canLayOutHistoryTableContent else {
            if !self.tableRows.isEmpty {
                self.deferredHistoryTableReload = true
            }
            return
        }
        self.tableView.transform = self.needsUITableViewVerticalFlipTransform ? CGAffineTransform(scaleX: 1.0, y: -1.0) : .identity
        self.tableView.frame = self.bounds
        if abs(self.tableView.contentOffset.y - self.scroller.contentOffset.y) > 0.5 || abs(self.tableView.contentOffset.x - self.scroller.contentOffset.x) > 0.5 {
            self.syncTableFromLegacy()
        }
        self.suppressLegacyListViewRendering()
        self.flushDeferredHistoryTableReloadIfNeeded()
    }
    
    public override func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets) {
        super.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        guard self.canLayOutHistoryTableContent else {
            if !self.tableRows.isEmpty {
                self.deferredHistoryTableReload = true
            }
            return
        }
        self.tableView.frame = CGRect(origin: .zero, size: updateSizeAndInsets.size)
        self.tableView.contentInset = updateSizeAndInsets.insets
        self.tableView.scrollIndicatorInsets = updateSizeAndInsets.insets
        self.syncTableFromLegacy()
        self.suppressLegacyListViewRendering()
        self.flushDeferredHistoryTableReloadIfNeeded()
    }
    
    public override func updateLayout(transition: ContainedViewLayoutTransition, updateSizeAndInsets: ListViewUpdateSizeAndInsets, additionalScrollDistance: CGFloat, scrollToTop: Bool, completion: @escaping () -> Void) {
        super.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets, additionalScrollDistance: additionalScrollDistance, scrollToTop: scrollToTop, completion: completion)
        guard self.canLayOutHistoryTableContent else {
            if !self.tableRows.isEmpty {
                self.deferredHistoryTableReload = true
            }
            return
        }
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
    
    /// Same scrollable-range convention as `ListView.scrollWithDirection` (see `Display/ListView.swift`).
    private func listViewLikeMaxContentOffsetY(for scrollView: UIScrollView) -> CGFloat {
        max(scrollView.contentInset.top, scrollView.contentSize.height - scrollView.frame.height)
    }
    
    /// Normalized position in \([0, 1]\) along the vertical scroll range, or `nil` if there is no range.
    private func listViewLikeScrollProgress(for scrollView: UIScrollView) -> CGFloat? {
        let minY = scrollView.contentInset.top
        let maxY = self.listViewLikeMaxContentOffsetY(for: scrollView)
        guard maxY > minY + CGFloat.ulpOfOne else {
            return nil
        }
        let y = scrollView.contentOffset.y
        return max(0.0, min(1.0, (y - minY) / (maxY - minY)))
    }
    
    private func syncTableFromLegacy() {
        guard !self.isSyncingToLegacy else {
            return
        }
        guard self.canLayOutHistoryTableContent else {
            return
        }
        let scroller = self.scroller
        let tableView = self.tableView
        
        let proposed: CGPoint
        let heightDrift = abs(scroller.contentSize.height - tableView.contentSize.height)
        if !self.needsUITableViewVerticalFlipTransform, heightDrift > 8.0, let progress = self.listViewLikeScrollProgress(for: scroller) {
            let minY = tableView.contentInset.top
            let maxY = self.listViewLikeMaxContentOffsetY(for: tableView)
            let y = minY + progress * (maxY - minY)
            proposed = CGPoint(x: scroller.contentOffset.x, y: y)
        } else {
            proposed = scroller.contentOffset
        }
        
        let current = tableView.contentOffset
        if abs(current.y - proposed.y) < 0.5 && abs(current.x - proposed.x) < 0.5 {
            self.suppressLegacyListViewRendering()
            return
        }
        self.isSyncingFromLegacy = true
        tableView.setContentOffset(proposed, animated: false)
        self.isSyncingFromLegacy = false
        self.suppressLegacyListViewRendering()
    }
    
    /// Full node layout + synchronous media decode. Use only for **small** updates (single row); never for whole-history rebuilds.
    private func measuredHeight(for item: ListViewItem, stableId: UInt64, previousItem: ListViewItem?, nextItem: ListViewItem?) -> CGFloat {
        if let cached = self.heightCache[stableId], cached > 0.0 {
            return cached
        }
        let width = max(1.0, self.tableView.bounds.width > 0.0 ? self.tableView.bounds.width : self.bounds.width)
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: chatHistoryTableLayoutUnboundedHeight)
        var measured = max(1.0, item.approximateHeight)
        item.nodeConfiguredForParams(async: { f in f() }, params: params, synchronousLoads: true, previousItem: previousItem, nextItem: nextItem, completion: { itemNode, _ in
            measured = itemNode.contentSize.height + itemNode.insets.top + itemNode.insets.bottom
        })
        measured = max(ceilToScreenPixels(measured), UIScreenPixel)
        self.heightCache[stableId] = measured
        return measured
    }
    
    /// Cheap row height for `rebuildTableRows`: avoids `nodeConfiguredForParams` / bitmap decode for every message (OOM + MediaBox pressure on history prepend).
    private func tableRowHeightForBulkRebuild(item: ListViewItem, stableId: UInt64) -> CGFloat {
        if let cached = self.heightCache[stableId], cached > 0.0 {
            return cached
        }
        let height = max(ceilToScreenPixels(max(1.0, item.approximateHeight)), UIScreenPixel)
        self.heightCache[stableId] = height
        return height
    }
    
    private func actualNodeHeight(_ itemNode: ListViewItemNode) -> CGFloat {
        let measured = itemNode.contentSize.height + itemNode.insets.top + itemNode.insets.bottom
        return max(ceilToScreenPixels(measured), UIScreenPixel)
    }
    
    private func updateRowHeightIfNeeded(stableId: UInt64, measuredHeight: CGFloat) {
        guard let index = self.tableRows.firstIndex(where: { $0.stableId == stableId }) else {
            return
        }
        let current = self.tableRows[index].approximateHeight
        guard abs(current - measuredHeight) > 0.5 else {
            return
        }
        self.tableRows[index].approximateHeight = measuredHeight
        self.heightCache[stableId] = measuredHeight
        self.pendingHeightReloadRowIndices.insert(index)
        self.enqueueCoalescedTableHeightRefresh()
    }
    
    private func cancelPendingTableHeightRefresh() {
        self.tableHeightRefreshWorkItem?.cancel()
        self.tableHeightRefreshWorkItem = nil
        self.pendingHeightReloadRowIndices.removeAll()
    }
    
    private func applyPendingTableHeightReloadIfPossible() {
        guard self.canLayOutHistoryTableContent else {
            return
        }
        guard !self.pendingHeightReloadRowIndices.isEmpty else {
            return
        }
        // Height-only corrections: `beginUpdates`/`endUpdates` forces the table to re-query
        // `heightForRowAt` without `reloadRows` tearing down cells. That avoids visible “gaps”
        // and inflated rows while async content (media, previews) settles — same data, new height.
        let rowCount = self.tableRows.count
        let validIndices = self.pendingHeightReloadRowIndices.filter { $0 >= 0 && $0 < rowCount }
        self.pendingHeightReloadRowIndices.removeAll()
        guard !validIndices.isEmpty else {
            return
        }
        UIView.performWithoutAnimation {
            self.tableView.beginUpdates()
            self.tableView.endUpdates()
        }
    }
    
    private func flushDeferredHeightRefreshAfterScrollIfNeeded() {
        guard !self.pendingHeightReloadRowIndices.isEmpty else {
            return
        }
        self.applyPendingTableHeightReloadIfPossible()
    }
    
    private func enqueueCoalescedTableHeightRefresh() {
        self.tableHeightRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.tableHeightRefreshWorkItem = nil
            self.applyPendingTableHeightReloadIfPossible()
        }
        self.tableHeightRefreshWorkItem = item
        DispatchQueue.main.async(execute: item)
    }
    
    /// `requestMessageUpdate` updates the hidden `ListView` only; the visible `UITableView` must reload or row heights stay stale (e.g. “Read more” / expanded text).
    override func performHistoryTablePresentationReloadForMessageId(_ id: MessageId) {
        guard let historyView = self.latestHistoryView else {
            return
        }
        guard !self.tableRows.isEmpty else {
            return
        }
        let entries = self.isTableRowOrderReversedFromHistoryEntries ? Array(historyView.filteredEntries.reversed()) : historyView.filteredEntries
        var rowIndex: Int?
        var stableId: UInt64?
        for (i, entry) in entries.enumerated() {
            switch entry {
            case let .MessageEntry(message, _, _, _, _, _):
                if message.id == id {
                    rowIndex = i
                    stableId = entry.stableId
                }
            case let .MessageGroupEntry(_, messages, _):
                if messages.contains(where: { $0.0.id == id }) {
                    rowIndex = i
                    stableId = entry.stableId
                }
            default:
                break
            }
            if rowIndex != nil {
                break
            }
        }
        guard let resolvedRow = rowIndex, let resolvedStable = stableId, resolvedRow < self.tableRows.count, self.tableRows[resolvedRow].stableId == resolvedStable else {
            return
        }
        self.heightCache.removeValue(forKey: resolvedStable)
        let row = self.tableRows[resolvedRow]
        let previousItem = resolvedRow > 0 ? self.tableRows[resolvedRow - 1].item : nil
        let nextItem = resolvedRow + 1 < self.tableRows.count ? self.tableRows[resolvedRow + 1].item : nil
        let newHeight = self.measuredHeight(for: row.item, stableId: resolvedStable, previousItem: previousItem, nextItem: nextItem)
        self.tableRows[resolvedRow].approximateHeight = newHeight
        UIView.performWithoutAnimation {
            self.tableView.reloadRows(at: [IndexPath(row: resolvedRow, section: 0)], with: .none)
        }
    }
    
    private func rebuildTableRows(from historyView: ChatHistoryView) {
        self.cancelPendingTableHeightRefresh()
        let canReorder = historyView.filteredEntries.count > 1 && self.baseCanReorder
        let entries = self.isTableRowOrderReversedFromHistoryEntries ? Array(historyView.filteredEntries.reversed()) : historyView.filteredEntries
        let newStableIds = Set(entries.map(\.stableId))
        self.heightCache = self.heightCache.filter { newStableIds.contains($0.key) }
        var rows: [ChatHistoryTableRow] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let item = mappedChatHistoryEntryItem(context: self.context, chatLocation: self.chatLocation, associatedData: historyView.associatedData, controllerInteraction: self.controllerInteraction, mode: self.mode, lastHeaderId: historyView.lastHeaderId, isSavedMusic: self.currentIsSavedMusic, canReorder: canReorder, entry: entry)
            let height = self.tableRowHeightForBulkRebuild(item: item, stableId: entry.stableId)
            rows.append(ChatHistoryTableRow(stableId: entry.stableId, item: item, approximateHeight: height))
        }
        self.nodeCache = self.nodeCache.filter { newStableIds.contains($0.key) }
        self.tableRows = rows
        self.flushOrDeferHistoryTableReload()
    }
    
    /// One VoiceOver focus per `UITableViewCell`: merge grouped message accessibility onto the cell.
    private func copyAccessibility(from itemNode: ListViewItemNode, to cell: ChatHistoryHostedCell) {
        cell.accessibilityElements = nil
        cell.accessibilityCustomActions = itemNode.view.accessibilityCustomActions
        
        if itemNode.isAccessibilityElement {
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = itemNode.view.accessibilityLabel
            cell.accessibilityValue = itemNode.view.accessibilityValue
            cell.accessibilityTraits = itemNode.view.accessibilityTraits
            cell.accessibilityHint = itemNode.view.accessibilityHint
            cell.accessibilityIdentifier = itemNode.view.accessibilityIdentifier
            return
        }
        
        if let nodeChildren = itemNode.accessibilityElements, !nodeChildren.isEmpty {
            var labels: [String] = []
            var values: [String] = []
            var hints: [String] = []
            var traits = itemNode.accessibilityTraits
            for child in nodeChildren {
                if let el = child as? UIAccessibilityElement {
                    if let label = el.accessibilityLabel, !label.isEmpty {
                        labels.append(label)
                    } else if let value = el.accessibilityValue, !value.isEmpty {
                        labels.append(value)
                    }
                    if let value = el.accessibilityValue, !value.isEmpty {
                        values.append(value)
                    }
                    if let hint = el.accessibilityHint, !hint.isEmpty {
                        hints.append(hint)
                    }
                    traits.formUnion(el.accessibilityTraits)
                } else if let view = child as? UIView {
                    if let label = view.accessibilityLabel, !label.isEmpty {
                        labels.append(label)
                    } else if let value = view.accessibilityValue, !value.isEmpty {
                        labels.append(value)
                    }
                    if let value = view.accessibilityValue, !value.isEmpty {
                        values.append(value)
                    }
                    if let hint = view.accessibilityHint, !hint.isEmpty {
                        hints.append(hint)
                    }
                    traits.formUnion(view.accessibilityTraits)
                }
            }
            let composedLabel = labels.joined(separator: ", ")
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = composedLabel.isEmpty ? itemNode.view.accessibilityLabel : composedLabel
            let joinedValues = values.joined(separator: " ")
            cell.accessibilityValue = joinedValues.isEmpty ? itemNode.view.accessibilityValue : joinedValues
            cell.accessibilityTraits = traits
            cell.accessibilityHint = hints.first ?? itemNode.accessibilityHint ?? itemNode.view.accessibilityHint
            cell.accessibilityIdentifier = itemNode.accessibilityIdentifier ?? itemNode.view.accessibilityIdentifier
            return
        }
        
        cell.isAccessibilityElement = itemNode.view.isAccessibilityElement
        cell.accessibilityLabel = itemNode.view.accessibilityLabel
        cell.accessibilityValue = itemNode.view.accessibilityValue
        cell.accessibilityTraits = itemNode.view.accessibilityTraits
        cell.accessibilityHint = itemNode.view.accessibilityHint
        cell.accessibilityIdentifier = itemNode.view.accessibilityIdentifier
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
        let actualHeight = self.actualNodeHeight(itemNode)
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
                let actualHeight = self.actualNodeHeight(cachedNode)
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
                guard let cell, cell.currentStableId == stableId else {
                    return
                }
                self.nodeCache[stableId] = itemNode
                let actualHeight = self.actualNodeHeight(itemNode)
                itemNode.frame = CGRect(origin: .zero, size: CGSize(width: max(1.0, tableView.bounds.width), height: actualHeight))
                cell.setItemNode(itemNode)
                self.copyAccessibility(from: itemNode, to: cell)
                self.updateRowHeightIfNeeded(stableId: stableId, measuredHeight: actualHeight)
            })
        }
    }
    
    /// Expose **one** accessibility item per visible `UITableViewCell` so VoiceOver horizontal swipes step row-by-row.
    public override func customAccessibilityElements() -> [Any]? {
        let trackDirectionalFocus = self.accessibilityDirectionalAnnouncement != nil
        var directionalCandidates: [(localIndex: Int, tableRow: Int, element: Any)] = []
        var activeSourceViewIds = Set<ObjectIdentifier>()
        var accessibilityElements: [Any] = []
        
        let visibleBoundsRect = CGRect(
            x: 0.0,
            y: self.rotated ? self.insets.bottom : self.insets.top,
            width: self.visibleSize.width,
            height: max(0.0, self.visibleSize.height - self.insets.top - self.insets.bottom)
        )
        var visibleScreenRect = UIAccessibility.convertToScreenCoordinates(visibleBoundsRect, in: self.view)
        var currentClippingNode: ASDisplayNode? = self
        while let clippingNode = currentClippingNode {
            if let clippingContainer = clippingNode as? AccessibilityClippingContainer, let clippingFrame = clippingContainer.accessibilityClippingFrameInScreenCoordinates() {
                visibleScreenRect = visibleScreenRect.intersection(clippingFrame)
                if visibleScreenRect.isNull || visibleScreenRect.width <= 1.0 || visibleScreenRect.height <= 1.0 {
                    self.updateAccessibilityDirectionalElements([])
                    return nil
                }
            }
            currentClippingNode = clippingNode.supernode
        }
        
        let visibleTableSlice = CGRect(
            x: 0.0,
            y: self.tableView.contentOffset.y,
            width: self.tableView.bounds.width,
            height: self.tableView.bounds.height
        )
        
        var rowEntries: [(cell: ChatHistoryHostedCell, indexPath: IndexPath, rowRect: CGRect, listIndex: Int)] = []
        for case let hosted as ChatHistoryHostedCell in self.tableView.visibleCells {
            guard let itemNode = hosted.itemNode, let indexPath = self.tableView.indexPath(for: hosted) else {
                continue
            }
            let rowRect = self.tableView.rectForRow(at: indexPath)
            let intersection = rowRect.intersection(visibleTableSlice)
            guard !intersection.isNull, intersection.height > 1.0, intersection.width > 1.0 else {
                continue
            }
            let visibleFraction = rowRect.intersection(visibleTableSlice)
            guard !visibleFraction.isNull, visibleFraction.height > rowRect.height * 0.25 || visibleFraction.height > 24.0 else {
                continue
            }
            let listIndex = itemNode.index ?? indexPath.row
            rowEntries.append((hosted, indexPath, rowRect, listIndex))
        }
        
        rowEntries.sort(by: { lhs, rhs in
            if lhs.listIndex != rhs.listIndex {
                return lhs.listIndex < rhs.listIndex
            }
            return lhs.indexPath.row < rhs.indexPath.row
        })
        
        for entry in rowEntries {
            let cell = entry.cell
            let label = cell.accessibilityLabel ?? ""
            let value = cell.accessibilityValue ?? ""
            guard !label.isEmpty || !value.isEmpty else {
                continue
            }
            let frame = UIAccessibility.convertToScreenCoordinates(cell.bounds, in: cell).intersection(visibleScreenRect)
            guard !frame.isNull, frame.width > 1.0, frame.height > 1.0 else {
                continue
            }
            activeSourceViewIds.insert(ObjectIdentifier(cell))
            if trackDirectionalFocus {
                let element = self.reuseOrCreateDirectionalElement(sourceView: cell, childOrder: 0)
                element.accessibilityFrame = frame
                element.accessibilityLabel = cell.accessibilityLabel
                element.accessibilityValue = cell.accessibilityValue
                element.accessibilityTraits = cell.accessibilityTraits
                element.accessibilityHint = cell.accessibilityHint
                element.accessibilityIdentifier = cell.accessibilityIdentifier
                element.accessibilityCustomActions = cell.accessibilityCustomActions
                directionalCandidates.append((localIndex: entry.listIndex, tableRow: entry.indexPath.row, element: element))
            } else {
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityFrame = frame
                element.accessibilityLabel = cell.accessibilityLabel
                element.accessibilityValue = cell.accessibilityValue
                element.accessibilityTraits = cell.accessibilityTraits
                element.accessibilityHint = cell.accessibilityHint
                element.accessibilityIdentifier = cell.accessibilityIdentifier
                element.accessibilityCustomActions = cell.accessibilityCustomActions
                accessibilityElements.append(element)
            }
        }
        
        if trackDirectionalFocus {
            accessibilityElements = directionalCandidates.sorted(by: { lhs, rhs in
                if lhs.localIndex != rhs.localIndex {
                    return lhs.localIndex < rhs.localIndex
                }
                return lhs.tableRow < rhs.tableRow
            }).map(\.element)
            self.cleanupDirectionalElementPool(activeSourceViewIds: activeSourceViewIds)
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
        
        return accessibilityElements.isEmpty ? nil : accessibilityElements
    }
    
    public override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        super.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate)
        if scrollView === self.tableView, !decelerate {
            self.flushDeferredHeightRefreshAfterScrollIfNeeded()
        }
    }
    
    public override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        super.scrollViewDidEndDecelerating(scrollView)
        if scrollView === self.tableView {
            self.flushDeferredHeightRefreshAfterScrollIfNeeded()
        }
    }
}

extension ChatHistoryListNodeImpl: UITableViewDataSource, UITableViewDelegate {
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === self.tableView {
            self.flushDeferredHeightRefreshAfterScrollIfNeeded()
        }
    }
    
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
    
    public func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard tableView === self.tableView, indexPath.row >= 0, indexPath.row < self.tableRows.count else {
            return
        }
        let stableId = self.tableRows[indexPath.row].stableId
        guard let hosted = cell as? ChatHistoryHostedCell, hosted.currentStableId == stableId else {
            return
        }
        // Detach nodes from the cell so UIKit does not keep heavy layers attached while off-screen.
        // Keep `nodeCache[stableId]` so when the user scrolls back, `cellForRow` can reattach synchronously
        // from cache. Removing the cache entry here forced async `nodeConfiguredForParams` on every
        // revisit and produced visible empty rows (“holes”) until another scroll/layout pass.
        hosted.evictItemSubtreeForOffScreenMemory()
    }
}
