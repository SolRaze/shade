@testable import VPhoneCoreKit
import CoreGraphics
import Foundation
import Testing

struct TwoFingerGestureTests {
    private let panel = CGSize(width: 390, height: 844)
    private let centre = CGPoint(x: 195, y: 422)

    private func span(_ g: VPhoneTwoFingerGesture) -> CGFloat {
        let p = g.points
        return hypot(p[0].x - p[1].x, p[0].y - p[1].y)
    }

    @Test func startsAsAPairStraddlingTheCentre() {
        let g = VPhoneTwoFingerGesture(centre: centre, bounds: panel)
        #expect(g.points.count == 2)
        #expect(abs(span(g) - VPhoneTwoFingerGesture.startSpan) < 0.001)
        #expect(abs((g.points[0].x + g.points[1].x) / 2 - centre.x) < 0.001)
        #expect(abs((g.points[0].y + g.points[1].y) / 2 - centre.y) < 0.001)
    }

    @Test func magnifyingScalesTheSeparation() {
        var g = VPhoneTwoFingerGesture(centre: centre, bounds: panel)
        g.apply(scale: 1.5, radians: 0, bounds: panel)
        #expect(abs(span(g) - VPhoneTwoFingerGesture.startSpan * 1.5) < 0.001)
    }

    @Test func pinchingInStopsAtTheMinimumSpan() {
        var g = VPhoneTwoFingerGesture(centre: centre, bounds: panel)
        for _ in 0 ..< 20 { g.apply(scale: 0.5, radians: 0, bounds: panel) }
        #expect(abs(span(g) - VPhoneTwoFingerGesture.minSpan) < 0.001)
    }

    @Test func rotatingTurnsThePairAroundItsCentre() {
        var g = VPhoneTwoFingerGesture(centre: centre, bounds: panel)
        let before = g.points
        g.apply(scale: 1, radians: .pi / 2, bounds: panel)
        #expect(abs(span(g) - VPhoneTwoFingerGesture.startSpan) < 0.001)
        // A quarter turn swaps the axis the fingers lie on.
        #expect(abs(before[0].y - before[1].y) < 0.001)
        #expect(abs(g.points[0].x - g.points[1].x) < 0.001)
    }

    @Test func bothFingersStayOnThePanelNearAnEdge() {
        var g = VPhoneTwoFingerGesture(centre: CGPoint(x: 4, y: 4), bounds: panel)
        g.apply(scale: 2, radians: 0.3, bounds: panel)
        for p in g.points {
            #expect(p.x >= 0 && p.x <= panel.width)
            #expect(p.y >= 0 && p.y <= panel.height)
        }
    }

    @Test func aSpanWiderThanThePanelClampsToItsShortSide() {
        var g = VPhoneTwoFingerGesture(centre: centre, bounds: panel)
        g.apply(scale: 100, radians: 0, bounds: panel)
        #expect(abs(span(g) - panel.width) < 0.001)
    }
}
