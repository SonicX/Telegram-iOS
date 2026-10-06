import Foundation
import UIKit

// VoiceOver: элемент доступности для экрана «Использование памяти».
// Строки здесь — UIButton с вложенными подстроками (раскрытая категория
// «Прочее») или layer-ы без view (сетка медиа), поэтому сам view нельзя
// сделать одним VO-элементом: вложенное пропадёт. Элемент берёт рамку из
// `frameProvider` (в координатах контейнера) и выполняет `activate`.
final class StorageUsageAccessibilityElement: UIAccessibilityElement {
    var frameProvider: (() -> CGRect)?
    var activate: (() -> Bool)?

    override var accessibilityFrameInContainerSpace: CGRect {
        get {
            if let frameProvider = self.frameProvider {
                return frameProvider()
            }
            return super.accessibilityFrameInContainerSpace
        }
        set {
            super.accessibilityFrameInContainerSpace = newValue
        }
    }

    override func accessibilityActivate() -> Bool {
        return self.activate?() ?? false
    }
}

enum StorageUsageAccessibilityStrings {
    static let selected = "выбрано"
    static let notSelected = "не выбрано"
    static let expanded = "развёрнуто"
    static let collapsed = "свёрнуто"
    static let select = "Выбрать"
    static let deselect = "Снять выбор"
    static let expand = "Развернуть"
    static let collapse = "Свернуть"
    static let openMenu = "Открыть меню"
}
