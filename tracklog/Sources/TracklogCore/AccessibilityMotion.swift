import Foundation

/// The droplet-owned motion contract. The host's normal transitions are used
/// unless Reduce Motion asks for the reduced path, which is this crossfade.
public enum AccessibilityMotion {
    public static let reducedCrossfade: TimeInterval = 0.16
}
