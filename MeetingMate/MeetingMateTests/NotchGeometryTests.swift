import CoreGraphics
import Testing
@testable import MeetingMate

struct NotchGeometryTests {
    /// 16" MacBook Pro–like screen: 1512×982 points, 38 pt menu bar with a notch 200 pt wide.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

    @Test func beside_the_notch_inside_the_menu_bar() {
        let notch = (left: CGFloat(656), right: CGFloat(856))
        let frame = NotchGeometry.frame(screen: screen, visible: visible, menuBarHeight: 38, notch: notch)

        #expect(frame.maxX == 656 - NotchGeometry.notchGap)
        #expect(frame.size == NotchGeometry.pillSize)
        // Vertically centered in the menu bar (top 38 pt of the screen).
        let center = frame.midY
        #expect(abs(center - (982 - 19)) < 0.5)
        #expect(frame.maxY <= screen.maxY)
    }

    @Test func without_a_notch_centered_below_the_menu_bar() {
        let frame = NotchGeometry.frame(screen: screen, visible: visible, menuBarHeight: 24, notch: nil)
        #expect(abs(frame.midX - screen.midX) < 0.5)
        #expect(frame.maxY == visible.maxY - NotchGeometry.notchGap)
        #expect(frame.maxY < screen.maxY - 24) // below the menu bar, not inside it
    }
}
