import UIKit

public final class ListViewScroller: UIScrollView, UIGestureRecognizerDelegate {
    override public init(frame: CGRect) {
        super.init(frame: frame)
        
        self.scrollsToTop = false
        self.contentInsetAdjustmentBehavior = .never
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is ListViewTapGestureRecognizer {
            return true
        }
        return false
    }
    
    override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer, let gestureRecognizers = gestureRecognizer.view?.gestureRecognizers {
            for otherGestureRecognizer in gestureRecognizers {
                if otherGestureRecognizer !== gestureRecognizer, let panGestureRecognizer = otherGestureRecognizer as? UIPanGestureRecognizer, panGestureRecognizer.minimumNumberOfTouches == 2 {
                    return gestureRecognizer.numberOfTouches < 2
                }
            }
            
            if let view = gestureRecognizer.view?.hitTest(gestureRecognizer.location(in: gestureRecognizer.view), with: nil) as? UIControl {
                return !view.isTracking
            }
            
            return true
        } else {
            return true
        }
    }
    
    override public func touchesShouldCancel(in view: UIView) -> Bool {
        return true
    }
    
    var forceDecelerating = false
    public override var isDecelerating: Bool {
        return self.forceDecelerating || super.isDecelerating
    }

    // VoiceOver: когда фокус попадает на элемент, чья реальная вьюшка вне
    // вьюпорта (band-полосы у кромок, за-экранные цели свайпа), UIKit сам
    // подкручивает scroll view, чтобы «показать» сфокусированное — мимо всей
    // нашей focus-машинерии. Для списков, где скроллом управляем мы
    // (focus-scroll-to-item / boundary-edge-scroll), такой нативный подскролл —
    // чистый вред: он сдвигал список чатов на сотни pt, пока пользователь ждал
    // открытия чата. ListView ставит замыкание-гейт; сам ListView
    // scrollRectToVisible никогда не вызывает, так что подавление ничего
    // своего не ломает.
    var voSuppressScrollRectToVisible: (() -> Bool)?
    override public func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        if self.voSuppressScrollRectToVisible?() == true {
            print("[VO-DIAG][SCROLL] native-scroll-to-visible-suppressed rect=(\(Int(rect.minY))..\(Int(rect.maxY)))")
            return
        }
        super.scrollRectToVisible(rect, animated: animated)
    }
}
