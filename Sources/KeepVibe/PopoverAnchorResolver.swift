import CoreGraphics

struct PopoverAnchorResolver {
    private static let fallbackSize: CGFloat = 22

    static func resolve(
        statusItemRect: CGRect?,
        screenFrames: [CGRect],
        mouseLocation: CGPoint
    ) -> CGRect {
        let fallback = fallbackRect(centeredAt: mouseLocation)

        guard let rect = statusItemRect,
              isUsable(rect),
              intersectsAnyScreen(rect, screenFrames)
        else {
            return fallback
        }

        if intersectsAnyScreen(CGRect(origin: mouseLocation, size: .zero), screenFrames) {
            let tolerance = max(80, max(rect.width, rect.height) * 2)
            if !rect.insetBy(dx: -tolerance, dy: -tolerance).contains(mouseLocation) {
                return fallback
            }
        }

        return rect
    }

    private static func fallbackRect(centeredAt point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - fallbackSize / 2,
            y: point.y - fallbackSize / 2,
            width: fallbackSize,
            height: fallbackSize
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.size.width.isFinite &&
            rect.size.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }

    private static func intersectsAnyScreen(_ rect: CGRect, _ screenFrames: [CGRect]) -> Bool {
        screenFrames.contains { screen in
            if rect.isEmpty {
                return screen.contains(rect.origin)
            }
            return screen.intersects(rect)
        }
    }
}
