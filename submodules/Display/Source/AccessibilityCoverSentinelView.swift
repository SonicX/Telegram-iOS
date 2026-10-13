import Foundation
import UIKit
import SwiftSignalKit

/// VoiceOver: полноэкранный экран, положенный поверх других (камера историй,
/// редактор, выбор обложки), не закрывает от VoiceOver то, что под ним —
/// курсор уходил на список чатов или кнопки камеры. Невидимая вьюшка-сторож,
/// добавленная в корень такого экрана: пока она в окне, всё, что лежит ниже
/// экрана (более ранние соседи по всей цепочке предков), скрыто от VoiceOver;
/// при уходе из окна скрытие снимается. Счётчик позволяет вкладывать экраны
/// друг в друга (камера → редактор → обложка).
public final class AccessibilityCoverSentinelView: UIView {
    private static var hideCounts: [ObjectIdentifier: Int] = [:]
    private static var originalHidden: [ObjectIdentifier: Bool] = [:]
    
    private var coveredViews: [Weak<UIView>] = []
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.isHidden = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        let covered = self.coveredViews
        DispatchQueue.main.async {
            AccessibilityCoverSentinelView.uncover(covered)
        }
    }
    
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        
        if self.window != nil {
            // Ждём, пока экран окончательно встанет в иерархию.
            DispatchQueue.main.async { [weak self] in
                self?.cover()
            }
        } else {
            let covered = self.coveredViews
            self.coveredViews = []
            AccessibilityCoverSentinelView.uncover(covered)
        }
    }
    
    private func cover() {
        guard self.window != nil, self.coveredViews.isEmpty, let screenView = self.superview else {
            return
        }
        var covered: [Weak<UIView>] = []
        var current: UIView = screenView
        while let parent = current.superview, !(current is UIWindow) {
            if let index = parent.subviews.firstIndex(of: current) {
                for sibling in parent.subviews[..<index] {
                    let id = ObjectIdentifier(sibling)
                    if AccessibilityCoverSentinelView.hideCounts[id] == nil {
                        AccessibilityCoverSentinelView.originalHidden[id] = sibling.accessibilityElementsHidden
                    }
                    AccessibilityCoverSentinelView.hideCounts[id, default: 0] += 1
                    sibling.accessibilityElementsHidden = true
                    covered.append(Weak(sibling))
                }
            }
            current = parent
        }
        self.coveredViews = covered
        if !covered.isEmpty {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
    
    private static func uncover(_ views: [Weak<UIView>]) {
        var changed = false
        for item in views {
            guard let view = item.value else {
                continue
            }
            let id = ObjectIdentifier(view)
            let count = (hideCounts[id] ?? 1) - 1
            if count <= 0 {
                hideCounts[id] = nil
                view.accessibilityElementsHidden = originalHidden.removeValue(forKey: id) ?? false
                changed = true
            } else {
                hideCounts[id] = count
            }
        }
        if changed {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
