import Foundation
import Testing
@testable import TracklogCore

@Suite("Accessibility motion")
struct AccessibilityMotionTests {
    @Test func theReducedCrossfadeIsUnderTwoHundredMilliseconds() {
        #expect(AccessibilityMotion.reducedCrossfade > 0)
        #expect(AccessibilityMotion.reducedCrossfade < 0.2)
    }
}
