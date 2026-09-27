import CoreGraphics
import Foundation

/// Where to put a guest window so it does not sit on top of the guest windows
/// already on screen.
///
/// Each `vm launch` is its own process with one window, so two booted guests
/// cannot be laid out by a shared window controller — every process places
/// itself and only learns about the others from the window server. The rule is
/// therefore one-sided: an arriving window moves, the windows already up never
/// do.
public enum VPhoneWindowTiling {
    /// Gap between tiled guest windows, in points.
    public static let gap: CGFloat = 8

    /// Origin for a window of `size` that clears every rect in `occupied`.
    ///
    /// Tries the right of the rightmost occupant first, then the left of the
    /// leftmost, then gives up and returns the centred origin — overlapping is
    /// better than placing a window where its titlebar cannot be grabbed.
    /// All rects are AppKit screen coordinates (y up).
    public static func origin(
        for size: CGSize, occupied: [CGRect], visibleFrame: CGRect
    ) -> CGPoint {
        let centred = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        let live = occupied.filter { $0.intersects(visibleFrame) }
        guard !live.isEmpty else { return centred }

        // Vertically centre on the occupants rather than the screen so a tiled
        // pair reads as one row even when an occupant was dragged off-centre.
        let band = live.reduce(live[0]) { $0.union($1) }
        let y = clamp(
            band.midY - size.height / 2,
            min: visibleFrame.minY,
            max: visibleFrame.maxY - size.height
        )

        for x in [band.maxX + gap, band.minX - gap - size.width] {
            let candidate = CGRect(x: x, y: y, width: size.width, height: size.height)
            if visibleFrame.contains(candidate), !live.contains(where: { $0.intersects(candidate) }) {
                return candidate.origin
            }
        }
        return centred
    }

    private static func clamp(_ v: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard hi > lo else { return lo }
        return Swift.min(Swift.max(v, lo), hi)
    }
}
