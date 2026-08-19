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
    private var voDismissGeneration: Int = 0
    private var voLastTextChangeTimestamp: Double = 0.0

    /// Пользователь печатает (SearchDisplayController зовёт на каждый
    /// textUpdated): отменяем отложенное скрытие и на короткое окно глушим
    /// новые — при вводе VO перестраивает результаты и мимолётно фокусит
    /// их, это не «листание».
    public final func voNoteSearchTextChanged() {
        self.voDismissGeneration &+= 1
        self.voLastTextChangeTimestamp = CACurrentMediaTime()
    }

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

    private var voPreviousFocusWasInsideContent: Bool = false

    /// Замыкание от SearchDisplayController: «поле поиска сейчас first
    /// responder?». Единственный надёжный признак, что пользователь хочет
    /// печатать, — нотификации фокуса VO приходят с произвольной задержкой
    /// относительно becomeFirstResponder.
    public final var voIsSearchFieldFirstResponder: (() -> Bool)?

    private func voHandleFocusChange(_ notification: Notification) {
        // Любая смена фокуса отменяет отложенное скрытие.
        self.voDismissGeneration &+= 1
        guard UIAccessibility.isVoiceOverRunning, self.isNodeLoaded, self.view.window != nil else {
            self.voPreviousFocusWasInsideContent = false
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
        let isInsideContent: Bool
        if let focusedView {
            isInsideContent = focusedView.isDescendant(of: self.view)
        } else {
            isInsideContent = false
        }
        let previousWasInsideContent = self.voPreviousFocusWasInsideContent
        self.voPreviousFocusWasInsideContent = isInsideContent
        guard isInsideContent else {
            return
        }
        // Только что печатали — результаты перестраиваются, их мимолётные
        // фокусы не считаются листанием.
        if CACurrentMediaTime() - self.voLastTextChangeTimestamp < 0.8 {
            return
        }
        // Прячем ТОЛЬКО при листании ПО результатам (предыдущий фокус тоже
        // был в контенте). Первое попадание в список (свайп с поля/клавиш или
        // тап по результату) клавиатуру не трогает — иначе конфликт с тапом
        // по полю поиска: мгновенный resignFirstResponder срывал активацию
        // поля, курсор откатывался на результат, напечатать было нельзя.
        guard previousWasInsideContent else {
            return
        }
        // Поле активно прямо сейчас — пользователь печатает, не трогаем.
        if self.voIsSearchFieldFirstResponder?() != true {
            return
        }
        let generation = self.voDismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.voDismissGeneration == generation else {
                return
            }
            guard UIAccessibility.isVoiceOverRunning else {
                return
            }
            // Поле всё ещё first responder и фокус не ушёл — прячем.
            guard self.voIsSearchFieldFirstResponder?() == true else {
                return
            }
            if let current = UIAccessibility.focusedElement(using: nil) {
                if current is UITextField || current is UITextView {
                    return
                }
                if let currentView = current as? UIView, currentView.isFirstResponder {
                    return
                }
            }
            self.dismissInput?()
        }
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
