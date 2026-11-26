import CoreGraphics

/// Where the NotchIsland sits. Pure math (no AppKit), so it is unit tested.
enum NotchGeometry {
    static let pillSize = CGSize(width: 156, height: 28)
    /// Gap between the notch and the pill.
    static let notchGap: CGFloat = 8

    /// - Parameters:
    ///   - screen: full screen frame.
    ///   - visible: frame without the menu bar and Dock.
    ///   - menuBarHeight: height of the menu bar region on this screen.
    ///   - notch: x-edges of the camera notch (left edge, right edge), or nil on a screen without one.
    /// - Returns: beside the notch, vertically centered in the menu bar. Without a notch:
    ///   centered just below the menu bar.
    static func frame(screen: CGRect, visible: CGRect, menuBarHeight: CGFloat,
                      notch: (left: CGFloat, right: CGFloat)?) -> CGRect {
        let size = pillSize
        if let notch {
            let y = screen.maxY - menuBarHeight + (menuBarHeight - size.height) / 2
            // Left of the notch: the right side is full of menu bar icons (including lắng's own),
            // and the pill must not cover them.
            return CGRect(x: notch.left - notchGap - size.width, y: y, width: size.width, height: size.height)
        }
        return CGRect(x: screen.midX - size.width / 2, y: visible.maxY - size.height - notchGap,
                      width: size.width, height: size.height)
    }
}
