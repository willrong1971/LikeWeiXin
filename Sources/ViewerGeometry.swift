import Foundation
import CoreGraphics

enum ViewerGeometry {
    /// Fit the phone to the usable screen height, reducing height only when its
    /// aspect would exceed the screen width. The result is top aligned and
    /// horizontally centered near `centerX`, clamped inside the available area.
    /// Invalid screen geometry uses a finite 360 × 780 fallback; invalid source
    /// dimensions use a portrait phone aspect. No display or window state is read.
    static func heightFittedFrame(available: CGRect, source: CGSize, centerX: CGFloat) -> CGRect {
        let fallbackBounds = CGRect(x: 0, y: 0, width: 360, height: 780)
        let bounds = validBounds(available) ? available : fallbackBounds
        let defaultAspect: CGFloat = 9.0 / 19.5
        var aspect = defaultAspect
        if source.width.isFinite, source.height.isFinite,
           source.width > 0, source.height > 0 {
            let candidate = source.width / source.height
            if candidate.isFinite, candidate > 0 { aspect = candidate }
        }

        let width: CGFloat
        let height: CGFloat
        if aspect > bounds.width / bounds.height {
            width = bounds.width
            height = width / aspect
        } else {
            height = bounds.height
            width = height * aspect
        }
        // Subnormal coordinates can make an otherwise valid aspect round to 0.
        // In that unrepresentable case, prefer a finite visible rectangle.
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return bounds }

        let desiredCenter = centerX.isFinite ? centerX : bounds.origin.x + bounds.width / 2
        let minimumX = bounds.origin.x
        let maximumX = bounds.origin.x + bounds.width - width
        let x = min(max(desiredCenter - width / 2, minimumX), maximumX)
        let y = bounds.origin.y + bounds.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func validBounds(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite &&
        rect.size.width > 0 && rect.size.height > 0 &&
        (rect.origin.x + rect.size.width).isFinite &&
        (rect.origin.y + rect.size.height).isFinite
    }
}
