import Testing
@testable import TracklogCore

@Suite("Palette key routing")
struct PaletteKeyRouterTests {
    private enum Key {
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let tab: UInt16 = 48
    }

    @Test func plainKeysMoveActivateAndClose() {
        #expect(PaletteKeyRouter.route(keyCode: Key.upArrow, command: false, hasMarkedText: false) == .moveUp)
        #expect(PaletteKeyRouter.route(keyCode: Key.downArrow, command: false, hasMarkedText: false) == .moveDown)
        #expect(PaletteKeyRouter.route(keyCode: Key.return, command: false, hasMarkedText: false) == .activate)
        #expect(PaletteKeyRouter.route(keyCode: Key.keypadEnter, command: false, hasMarkedText: false) == .activate)
        #expect(PaletteKeyRouter.route(keyCode: Key.escape, command: false, hasMarkedText: false) == .escape)
        #expect(PaletteKeyRouter.route(keyCode: Key.tab, command: false, hasMarkedText: false) == .passThrough)
    }

    @Test func commandReturnOpensLastFMAndCommandArrowsPassThrough() {
        #expect(PaletteKeyRouter.route(keyCode: Key.return, command: true, hasMarkedText: false) == .commandActivate)
        #expect(PaletteKeyRouter.route(keyCode: Key.keypadEnter, command: true, hasMarkedText: false) == .commandActivate)
        #expect(PaletteKeyRouter.route(keyCode: Key.upArrow, command: true, hasMarkedText: false) == .passThrough)
        #expect(PaletteKeyRouter.route(keyCode: Key.downArrow, command: true, hasMarkedText: false) == .passThrough)
    }

    @Test func markedInputMethodTextKeepsEveryPaletteKeyInTheFieldEditor() {
        for key in [Key.upArrow, Key.downArrow, Key.return, Key.keypadEnter, Key.escape] {
            #expect(
                PaletteKeyRouter.route(keyCode: key, command: false, hasMarkedText: true) == .passThrough,
                "key \(key) should go to the field editor while text is marked",
            )
        }
        #expect(PaletteKeyRouter.route(keyCode: Key.return, command: true, hasMarkedText: true) == .passThrough)
    }
}
