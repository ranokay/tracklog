import Foundation

/// What the palette does with one key event from its local monitor.
public enum PaletteKeyAction: Equatable, Sendable {
    case moveUp
    case moveDown
    case activate
    case commandActivate
    case escape
    case passThrough
}

/// The palette's keyboard rules, kept host-neutral so the input-method rule is
/// testable without AppKit. While an input method has marked text, every key
/// belongs to the field editor: Return commits the composition and Escape
/// cancels it, so none of them may run a palette action.
public enum PaletteKeyRouter {
    public enum KeyCode {
        public static let upArrow: UInt16 = 126
        public static let downArrow: UInt16 = 125
        public static let `return`: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let escape: UInt16 = 53
    }

    public static func route(
        keyCode: UInt16,
        command: Bool,
        hasMarkedText: Bool,
    ) -> PaletteKeyAction {
        guard !hasMarkedText else { return .passThrough }
        switch keyCode {
        case KeyCode.upArrow:
            return command ? .passThrough : .moveUp
        case KeyCode.downArrow:
            return command ? .passThrough : .moveDown
        case KeyCode.return, KeyCode.keypadEnter:
            return command ? .commandActivate : .activate
        case KeyCode.escape:
            return .escape
        default:
            return .passThrough
        }
    }
}
