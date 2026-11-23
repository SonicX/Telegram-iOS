import Foundation
import UIKit
import os
import AsyncDisplayKit
import SwiftSignalKit

/// Включает подробное VoiceOver-логирование (`[VO-…]`). По умолчанию ВЫКЛЮЧЕНО.
///
/// Эти `print`-логи вызываются на КАЖДОЕ событие фокуса VO во всех материализованных
/// `ListView`. `print()` на устройстве под отладчиком — синхронный и медленный, на
/// главном потоке, поэтому шторм таких вызовов вешает UI (долгий отклик при свайпе по
/// пунктам контекстного меню и т.п.). Держим выключенным в обычных сборках; включать
/// только точечно при отладке доступности.
public var voVerboseAccessibilityLogging = false

/// No-op-обёртка над `print` для VO-диагностики. Аргумент — `@autoclosure`, поэтому
/// при выключенном логировании интерполяция строки (часто с дорогими вычислениями)
/// вообще не выполняется.
@inline(__always)
public func voAccessibilityLog(_ message: @autoclosure () -> String) {
    if voVerboseAccessibilityLogging {
        let text = message()
        print(text)
        voSystemLog(text)
        voDiagnosticsSink?(text)
    }
}

/// Приёмник VO-диагностики для УДАЛЁННОГО сбора логов: приложение (TelegramUI)
/// подключает сюда файловый Logger, и тестировщики отправляют логи штатным
/// Debug → Send Logs. Без подключения диагностика идёт только в консоль.
public var voDiagnosticsSink: ((String) -> Void)?

/// Момент последнего accessibility hit-test (ощупывание экрана пальцем при
/// VoiceOver, iOS 18+). По нему отличаем касание от свайпа.
public var voAccessibilityLastTouchExplorationTimestamp: Double = 0.0

/// Точка того же hit-test в экранных координатах. iOS 27 зовёт hit-test и
/// при СВАЙПАХ (лог 2026-10-27: «касания» по элементам за экраном), поэтому
/// касанием считаем только hit-test, попавший в видимую часть элемента.
public var voAccessibilityLastTouchExplorationPoint: CGPoint?

/// Момент последнего ВКЛЮЧЕНИЯ VoiceOver (см. ListView.voTrackVoiceOverEnabling).
public var voAccessibilityVoiceOverEnabledTimestamp: Double = 0.0

/// Элемент списка, по которому VoiceOver последний раз сделал двойной тап,
/// и момент тапа. Запуск кружка/видео меняет раскладку, iOS 27 тут же
/// перевыбирает фокус hit-test'ом и уводил курсор на соседнее сообщение
/// (лог 2026-11-20, LOVEтамин: «кружки не открываются, сколько ни жми»).
public weak var voAccessibilityLastActivatedElement: FocusTrackingAccessibilityElement?
public var voAccessibilityLastActivatedTimestamp: Double = 0.0

public func voNoteAccessibilityHitTest(_ point: CGPoint, in view: UIView) {
    voAccessibilityLastTouchExplorationTimestamp = CACurrentMediaTime()
    voAccessibilityLastTouchExplorationPoint = UIAccessibility.convertToScreenCoordinates(CGRect(origin: point, size: CGSize(width: 1.0, height: 1.0)), in: view).origin
}

/// Диагностический принт [VO-DIAG]: в консоль + в файловый лог (если подключён)
/// + в системный журнал устройства.
public func voDiagLog(_ message: @autoclosure () -> String) {
    let text = message()
    print(text)
    voSystemLog(text)
    voDiagnosticsSink?(text)
}

private let voSystemLogObject = OSLog(subsystem: "Swiftgram.VoiceOver", category: "VO")

/// `print` без подключённого отладчика никуда не попадает, поэтому VO-логи
/// дублируем в системный журнал: их видно вживую с устройства по кабелю
/// (`scripts/device-logs.sh`, Console.app) — нужно для iPhone на iOS 16,
/// который Xcode 27 не умеет запускать под отладчиком.
@inline(__always)
private func voSystemLog(_ text: String) {
    os_log("%{public}@", log: voSystemLogObject, type: .default, text)
}

/// Описание реального VO-элемента, который `ListView` дописывает ПОСЛЕ
/// новейшего элемента (trailing pooled element). Используется историей чата для
/// кнопок «Написать сообщение»/«Отменить ответ» — они становятся пуловыми
/// `FocusTrackingAccessibilityElement` того же типа, что и сообщения, поэтому VO
/// ведёт на них штатно. Активация делегируется в `sourceView.accessibilityActivate()`.
public struct ListViewAccessibilityTrailingElement {
    public let sourceView: UIView
    public let label: String
    public let value: String?
    public let traits: UIAccessibilityTraits
    public let frame: CGRect

    public init(sourceView: UIView, label: String, value: String?, traits: UIAccessibilityTraits, frame: CGRect) {
        self.sourceView = sourceView
        self.label = label
        self.value = value
        self.traits = traits
        self.frame = frame
    }
}

/// Строка списка, у которой временно есть вспомогательные VO-элементы
/// (цели ротора). ListView вставляет их в массив сразу после элемента строки;
/// `container` — контейнер, который им надо проставить (вьюшка ListView).
public protocol ListViewAccessibilityAuxiliaryElementsSource: AnyObject {
    func accessibilityAuxiliaryElements(focused: Any?, container: UIView) -> [NSObject]
}

public final class FocusTrackingAccessibilityElement: UIAccessibilityElement {
    public var directionalFocusIndex: Int?
    public var directionalSnapshotId: Int?
    public var focused: ((Int, Int) -> Void)?
    public var focusLost: ((Int, Int) -> Void)?
    public weak var sourceView: UIView?
    /// Local item index this proxy is pooled under.  Set by
    /// `ListView.reuseOrCreateDirectionalElement(localIndex:childOrder:sourceView:)`.
    /// Used by `handleSystemAccessibilityFocusNotification` to scroll
    /// directly to the item via `ListView.transaction(scrollToItem:)`,
    /// bypassing geometric off-screen-frame computations that fail for
    /// rotated chat history with very tall message bubbles.
    public var pinnedLocalIndex: Int?
    /// Стабильный ключ элемента списка (например, id чата): по нему пул
    /// переносит элемент за строкой, когда та переехала на другой индекс,
    /// даже если ListView создал для неё новую ноду.
    public var stableItemKey: AnyHashable?

    override public func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        if let snapshotId = directionalSnapshotId, let index = directionalFocusIndex {
            focused?(snapshotId, index)
        }
    }

    /// Активация строки списка тем же путём, что и тап по строке (без
    /// хит-теста по центру фрейма). Ставит ListView, если список это просит.
    public var activateRow: (() -> Bool)?

    override public func accessibilityActivate() -> Bool {
        voAccessibilityLastActivatedElement = self
        voAccessibilityLastActivatedTimestamp = CACurrentMediaTime()
        voDiagLog("[VO-DIAG][ACT] activate pin=\(self.pinnedLocalIndex.map(String.init) ?? "-") label=«\(String((self.accessibilityLabel ?? "-").prefix(32)))»")
        if let activateRow = self.activateRow, activateRow() {
            return true
        }
        return sourceView?.accessibilityActivate() ?? false
    }

    override public func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        if let snapshotId = directionalSnapshotId, let index = directionalFocusIndex {
            focusLost?(snapshotId, index)
        }
    }
}

private func clipAccessibilityFrame(_ frame: CGRect, for node: ASDisplayNode) -> CGRect {
    guard !frame.isNull else {
        return .zero
    }
    var result = frame
    var currentNode: ASDisplayNode? = node
    while let node = currentNode {
        if let clippingContainer = node as? AccessibilityClippingContainer, let clippingFrame = clippingContainer.accessibilityClippingFrameInScreenCoordinates() {
            result = result.intersection(clippingFrame)
            if result.isNull || result.width <= 1.0 || result.height <= 1.0 {
                return .zero
            }
        }
        currentNode = node.supernode
    }
    return result
}

/// Публичная обёртка над обрезкой accessibility-фрейма по цепочке
/// `AccessibilityClippingContainer` вверх от узла. Возвращает `.zero`, если
/// видимая часть пуста (например, сообщение целиком уехало под навбар) —
/// VoiceOver считает такой элемент невидимым и не отдаёт его касанию.
public func clipAccessibilityFrameToContainers(_ frame: CGRect, for node: ASDisplayNode) -> CGRect {
    return clipAccessibilityFrame(frame, for: node)
}

public func makeAccessibilityElement(of node: ASDisplayNode, container: Any, trackFocus: Bool) -> UIAccessibilityElement {
    let element: UIAccessibilityElement
    if trackFocus {
        let focusElement = FocusTrackingAccessibilityElement(accessibilityContainer: container)
        focusElement.sourceView = node.view
        element = focusElement
    } else {
        element = UIAccessibilityElement(accessibilityContainer: container)
    }
    element.accessibilityFrame = clipAccessibilityFrame(UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view), for: node)
    element.accessibilityLabel = node.accessibilityLabel
    element.accessibilityValue = node.accessibilityValue
    element.accessibilityTraits = node.accessibilityTraits
    element.accessibilityHint = node.accessibilityHint
    element.accessibilityIdentifier = node.accessibilityIdentifier
    element.accessibilityCustomActions = node.view.accessibilityCustomActions
    return element
}

private func makeFocusTrackingElement(from element: UIAccessibilityElement, container: Any, sourceView: UIView?) -> FocusTrackingAccessibilityElement {
    let focusElement = FocusTrackingAccessibilityElement(accessibilityContainer: container)
    focusElement.sourceView = sourceView
    focusElement.accessibilityFrame = element.accessibilityFrame
    focusElement.accessibilityLabel = element.accessibilityLabel
    focusElement.accessibilityValue = element.accessibilityValue
    focusElement.accessibilityTraits = element.accessibilityTraits
    focusElement.accessibilityHint = element.accessibilityHint
    focusElement.accessibilityIdentifier = element.accessibilityIdentifier
    focusElement.accessibilityCustomActions = element.accessibilityCustomActions
    return focusElement
}

public func addAccessibilityChildren(of node: ASDisplayNode, container: Any, to list: inout [Any], trackFocus: Bool = false) {
    if node.isAccessibilityElement {
        if trackFocus {
            let element = FocusTrackingAccessibilityElement(accessibilityContainer: container)
            element.sourceView = node.view
            element.accessibilityFrame = clipAccessibilityFrame(UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view), for: node)
            element.accessibilityLabel = node.accessibilityLabel
            element.accessibilityValue = node.accessibilityValue
            element.accessibilityTraits = node.accessibilityTraits
            element.accessibilityHint = node.accessibilityHint
            element.accessibilityIdentifier = node.accessibilityIdentifier
            element.accessibilityCustomActions = node.view.accessibilityCustomActions
            list.append(element)
        } else {
            let element = UIAccessibilityElement(accessibilityContainer: container)
            element.accessibilityFrame = clipAccessibilityFrame(UIAccessibility.convertToScreenCoordinates(node.bounds, in: node.view), for: node)
            element.accessibilityLabel = node.accessibilityLabel
            element.accessibilityValue = node.accessibilityValue
            element.accessibilityTraits = node.accessibilityTraits
            element.accessibilityHint = node.accessibilityHint
            element.accessibilityIdentifier = node.accessibilityIdentifier
            
            //node.accessibilityFrame = UIAccessibilityConvertFrameToScreenCoordinates(node.bounds, node.view)
            list.append(element)
        }
    } else if let accessibilityElements = node.accessibilityElements {
        if trackFocus {
            for childElement in accessibilityElements {
                guard let childElement = childElement as? UIAccessibilityElement else {
                    list.append(childElement)
                    continue
                }
                let element = makeFocusTrackingElement(from: childElement, container: container, sourceView: node.view)
                element.accessibilityFrame = clipAccessibilityFrame(childElement.accessibilityFrame, for: node)
                if !element.accessibilityFrame.isEmpty {
                    list.append(element)
                }
            }
        } else {
            for childElement in accessibilityElements {
                if let childElement = childElement as? UIAccessibilityElement {
                    childElement.accessibilityFrame = clipAccessibilityFrame(childElement.accessibilityFrame, for: node)
                    if !childElement.accessibilityFrame.isEmpty {
                        list.append(childElement)
                    }
                } else {
                    list.append(childElement)
                }
            }
        }
    }
}

public func smartInvertColorsEnabled() -> Bool {
    if #available(iOSApplicationExtension 11.0, iOS 11.0, *), UIAccessibility.isInvertColorsEnabled {
        return true
    } else {
        return false
    }
}

public func isReduceMotionEnabled() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        subscriber.putNext(UIAccessibility.isReduceMotionEnabled)
        
        let observer = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main, using: { _ in
            subscriber.putNext(UIAccessibility.isReduceMotionEnabled)
        })
        
        return ActionDisposable {
            Queue.mainQueue().async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    } |> runOn(Queue.mainQueue())
}

public func isSpeakSelectionEnabled() -> Bool {
    return UIAccessibility.isSpeakSelectionEnabled
}

public func isSpeakSelectionEnabledSignal() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        subscriber.putNext(UIAccessibility.isSpeakSelectionEnabled)
        
        let observer = NotificationCenter.default.addObserver(forName: UIAccessibility.speakSelectionStatusDidChangeNotification, object: nil, queue: .main, using: { _ in
            subscriber.putNext(UIAccessibility.isSpeakSelectionEnabled)
        })
        
        return ActionDisposable {
            Queue.mainQueue().async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    } |> runOn(Queue.mainQueue())
}

public func isBoldTextEnabled() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        subscriber.putNext(UIAccessibility.isBoldTextEnabled)
        
        let observer = NotificationCenter.default.addObserver(forName: UIAccessibility.boldTextStatusDidChangeNotification, object: nil, queue: .main, using: { _ in
            subscriber.putNext(UIAccessibility.isBoldTextEnabled)
        })
        
        return ActionDisposable {
            Queue.mainQueue().async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
    |> runOn(Queue.mainQueue())
}

public func isReduceTransparencyEnabled() -> Bool {
    UIAccessibility.isReduceTransparencyEnabled
}

/// Прокси-элемент VoiceOver: живьём пересылает метку/значение/фрейм/действия
/// исходному элементу (UIView или UIAccessibilityElement). Нужен, когда
/// контейнер отдаёт VoiceOver плоский список листьев из вложенных
/// контейнеров: у прокси один явный `accessibilityContainer`, и VoiceOver
/// не путается во вложенных массивах с неверными фреймами контейнеров.
public final class AccessibilityForwardingElement: UIAccessibilityElement {
    public private(set) weak var target: NSObject?

    public init(container: Any, target: NSObject) {
        self.target = target
        super.init(accessibilityContainer: container)
    }

    override public var accessibilityLabel: String? {
        get { return self.target?.accessibilityLabel }
        set { }
    }

    override public var accessibilityValue: String? {
        get { return self.target?.accessibilityValue }
        set { }
    }

    override public var accessibilityHint: String? {
        get { return self.target?.accessibilityHint }
        set { }
    }

    override public var accessibilityTraits: UIAccessibilityTraits {
        get { return self.target?.accessibilityTraits ?? .none }
        set { }
    }

    override public var accessibilityFrame: CGRect {
        get { return self.target?.accessibilityFrame ?? .zero }
        set { }
    }

    override public var accessibilityActivationPoint: CGPoint {
        get { return self.target?.accessibilityActivationPoint ?? .zero }
        set { }
    }

    override public var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { return self.target?.accessibilityCustomActions }
        set { }
    }

    override public func accessibilityActivate() -> Bool {
        // false → VoiceOver сам «тапнет» в activation point исходного элемента.
        return self.target?.accessibilityActivate() ?? false
    }

    override public func accessibilityIncrement() {
        self.target?.accessibilityIncrement()
    }

    override public func accessibilityDecrement() {
        self.target?.accessibilityDecrement()
    }

    override public func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        self.target?.accessibilityElementDidBecomeFocused()
    }
}

/// Собирает конечные VO-элементы под `view` (саму `view` не опрашивает —
/// безопасно звать из её же accessibilityElements). Пропускает скрытые,
/// пустые (без метки и значения) и нулевого размера.
public func collectAccessibilityLeaves(inSubviewsOf view: UIView) -> [NSObject] {
    var result: [NSObject] = []
    for subview in view.subviews {
        collectAccessibilityLeaves(of: subview, depth: 0, into: &result)
    }
    return result
}

private func collectAccessibilityLeaves(of view: UIView, depth: Int, into result: inout [NSObject]) {
    if depth > 24 || view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden {
        return
    }
    if view.isAccessibilityElement {
        appendAccessibilityLeafIfMeaningful(view, into: &result)
        return
    }
    if let elements = view.accessibilityElements {
        for element in elements {
            if let subview = element as? UIView {
                collectAccessibilityLeaves(of: subview, depth: depth + 1, into: &result)
            } else if let object = element as? NSObject, object.isAccessibilityElement {
                appendAccessibilityLeafIfMeaningful(object, into: &result)
            }
        }
    } else {
        for subview in view.subviews {
            collectAccessibilityLeaves(of: subview, depth: depth + 1, into: &result)
        }
    }
}

private func appendAccessibilityLeafIfMeaningful(_ element: NSObject, into result: inout [NSObject]) {
    if (element.accessibilityLabel ?? "").isEmpty && (element.accessibilityValue ?? "").isEmpty {
        return
    }
    let frame = element.accessibilityFrame
    if frame.isNull || frame.width < 1.0 || frame.height < 1.0 {
        return
    }
    result.append(element)
}

/// Порядок чтения «как глазами»: строки сверху вниз (элементы, чьи верхние
/// края ближе `rowTolerance`, — одна строка), внутри строки слева направо.
public func sortAccessibilityElementsInVisualRows(_ elements: [NSObject], rowTolerance: CGFloat = 10.0) -> [NSObject] {
    let byTop = elements.sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY }
    var rows: [[NSObject]] = []
    var rowTop: CGFloat = -.greatestFiniteMagnitude
    for element in byTop {
        let top = element.accessibilityFrame.minY
        if rows.isEmpty || top - rowTop > rowTolerance {
            rows.append([element])
            rowTop = top
        } else {
            rows[rows.count - 1].append(element)
        }
    }
    return rows.flatMap { row in row.sorted { $0.accessibilityFrame.minX < $1.accessibilityFrame.minX } }
}
