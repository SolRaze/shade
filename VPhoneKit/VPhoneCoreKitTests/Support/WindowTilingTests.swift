@testable import VPhoneCoreKit
import CoreGraphics
import Testing

struct WindowTilingTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let panel = CGSize(width: 406, height: 890)

    private func centred() -> CGPoint {
        CGPoint(x: screen.midX - panel.width / 2, y: screen.midY - panel.height / 2)
    }

    @Test func centresWithNothingElseOnScreen() {
        let p = VPhoneWindowTiling.origin(for: panel, occupied: [], visibleFrame: screen)
        #expect(p == centred())
    }

    @Test func tilesToTheRightOfOneOccupant() {
        let first = CGRect(origin: centred(), size: panel)
        let p = VPhoneWindowTiling.origin(for: panel, occupied: [first], visibleFrame: screen)
        #expect(p.x == first.maxX + VPhoneWindowTiling.gap)
        #expect(!CGRect(origin: p, size: panel).intersects(first))
    }

    @Test func fallsBackToTheLeftWhenTheRightIsFull() {
        // Occupant hugging the right edge: no room for a panel plus gap beside it.
        let first = CGRect(x: screen.maxX - panel.width, y: 95, width: panel.width, height: panel.height)
        let p = VPhoneWindowTiling.origin(for: panel, occupied: [first], visibleFrame: screen)
        #expect(p.x == first.minX - VPhoneWindowTiling.gap - panel.width)
    }

    @Test func centresWhenNeitherSideFits() {
        let wide = CGRect(x: 0, y: 95, width: screen.width, height: panel.height)
        let p = VPhoneWindowTiling.origin(for: panel, occupied: [wide], visibleFrame: screen)
        #expect(p == centred())
    }

    @Test func ignoresOccupantsOnAnotherDisplay() {
        let offscreen = CGRect(x: 4000, y: 0, width: panel.width, height: panel.height)
        let p = VPhoneWindowTiling.origin(for: panel, occupied: [offscreen], visibleFrame: screen)
        #expect(p == centred())
    }

    @Test func staysOnScreenVerticallyForATallOccupant() {
        let tall = CGRect(x: 100, y: -200, width: 300, height: 1400)
        let p = VPhoneWindowTiling.origin(for: panel, occupied: [tall], visibleFrame: screen)
        #expect(p.y >= screen.minY)
        #expect(p.y + panel.height <= screen.maxY)
    }
}
