import CoreGraphics
import Foundation

/// The pair of synthetic fingers a host pinch or rotate gesture drives.
///
/// A trackpad reports magnification and rotation as separate events that
/// interleave inside one physical gesture, so both feed the same pair: the
/// guest must keep seeing two fingers that move, never a second pair arriving
/// mid-gesture.
public struct VPhoneTwoFingerGesture {
    /// Separation the pair starts at, in points. Wide enough for UIKit to read
    /// a pinch rather than a jittering single touch, narrow enough to fit a
    /// phone panel at any rotation.
    public static let startSpan: CGFloat = 120
    /// Closest the fingers may come. At zero they would land on one point and
    /// the guest would lose the gesture.
    public static let minSpan: CGFloat = 24

    /// Midpoint of the pair, in view-local points.
    public private(set) var centre: CGPoint
    /// Distance between the fingers, in points.
    public private(set) var span: CGFloat
    /// Angle of the line through both fingers, radians counter-clockwise.
    public private(set) var angle: CGFloat

    public init(centre: CGPoint, bounds: CGSize, span: CGFloat = startSpan, angle: CGFloat = 0) {
        self.centre = centre
        self.span = span
        self.angle = angle
        fit(in: bounds)
    }

    /// Scales the separation and adds to the angle, then pulls the pair back
    /// inside `bounds`.
    public mutating func apply(scale: CGFloat, radians: CGFloat, bounds: CGSize) {
        span *= scale
        angle += radians
        fit(in: bounds)
    }

    /// Both finger positions. Index 0 is the one on the `angle` side; the order
    /// is the identity the guest assigns, so it must not change mid-gesture.
    public var points: [CGPoint] {
        let r = span / 2
        let dx = cos(angle) * r
        let dy = sin(angle) * r
        return [
            CGPoint(x: centre.x + dx, y: centre.y + dy),
            CGPoint(x: centre.x - dx, y: centre.y - dy),
        ]
    }

    /// Keeps both fingers on the panel. A finger clamped to an edge on its own
    /// would collapse the pair, so the whole gesture slides instead.
    private mutating func fit(in bounds: CGSize) {
        span = max(Self.minSpan, min(span, min(bounds.width, bounds.height)))
        let r = span / 2
        let hx = abs(cos(angle)) * r
        let hy = abs(sin(angle)) * r
        centre.x = Self.clamp(centre.x, lo: hx, hi: bounds.width - hx)
        centre.y = Self.clamp(centre.y, lo: hy, hi: bounds.height - hy)
    }

    /// Midpoint when the range is empty — a span wider than the panel has no
    /// position that fits, and centring loses the least of the gesture.
    private static func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        guard hi > lo else { return (lo + hi) / 2 }
        return Swift.min(Swift.max(v, lo), hi)
    }
}
