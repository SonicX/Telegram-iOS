import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import SearchBarNode

open class SearchDisplayControllerContentNode: ASDisplayNode {
    public final var dismissInput: (() -> Void)?
    public final var cancel: (() -> Void)?
    public final var setQuery: ((NSAttributedString?, [SearchBarToken], String) -> Void)?
    public final var setPlaceholder: ((String) -> Void)?
    
    open var animateBackgroundAppearance: Bool {
        return true
    }
    
    open var hasDim: Bool {
        return false
    }
    
    open var isSearching: Signal<Bool, NoError> {
        return .single(false)
    }
    
    // VoiceOver: прячем клавиатуру, когда курсор встаёт на результат поиска.
    // Иначе результаты упираются в клавиатуру и листать их свайпами нельзя.
    // Запрос при этом сохраняется (dismissInput → searchBar.deactivate(clear:
    // false)); тап по полю поиска снова поднимает клавиатуру.
    private var voFocusObserver: NSObjectProtocol?

    override public init() {
        super.init()
        self.voFocusObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main) { [weak self] notification in
            self?.voHandleFocusChange(notification)
        }
    }

    deinit {
        if let voFocusObserver = self.voFocusObserver {
            NotificationCenter.default.removeObserver(voFocusObserver)
        }
    }

    private func voHandleFocusChange(_ notification: Notification) {
        guard UIAccessibility.isVoiceOverRunning, self.isNodeLoaded, self.view.window != nil else {
            return
        }
        guard let focusedAny = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] else {
            return
        }
        // Определяем вьюшку сфокусированного объекта (вьюшка, нода или
        // прокси-элемент с контейнером-вьюшкой/нодой).
        var focusedView: UIView?
        if let view = focusedAny as? UIView {
            focusedView = view
        } else if let node = focusedAny as? ASDisplayNode, node.isNodeLoaded {
            focusedView = node.view
        } else if let element = focusedAny as? UIAccessibilityElement {
            if let containerView = element.accessibilityContainer as? UIView {
                focusedView = containerView
            } else if let containerNode = element.accessibilityContainer as? ASDisplayNode, containerNode.isNodeLoaded {
                focusedView = containerNode.view
            }
        }
        guard let focusedView else {
            return
        }
        // Клавиатура и строка поиска — не результаты; реагируем только на
        // фокус ВНУТРИ нашего контента (результаты, секции, фильтры).
        if !focusedView.isDescendant(of: self.view) {
            return
        }
        // dismissInput → resignFirstResponder: на уже неактивном поле — no-op,
        // так что повторные вызовы при каждом свайпе безвредны.
        self.dismissInput?()
    }
    
    open func updatePresentationData(_ presentationData: PresentationData) {
    }
    
    open func searchTextUpdated(text: String) {
    }
    
    open func searchTokensUpdated(tokens: [SearchBarToken]) {
    }
    
    open func searchTextClearPrefix() {
    }
    
    open func searchTextClearTokens() {
    }
    
    open func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
    
    }
    
    open func ready() -> Signal<Void, NoError> {
        return .single(Void())
    }
    
    open func previewViewAndActionAtLocation(_ location: CGPoint) -> (UIView, CGRect, Any)? {
        return nil
    }
    
    open func scrollToTop() {
    }
}
