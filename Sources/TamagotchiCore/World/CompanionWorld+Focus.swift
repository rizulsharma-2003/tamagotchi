import Foundation

extension CompanionWorld {
    /// The focus buddy reports its phase (nil when no focus session runs).
    public func updateFocus(_ status: FocusStatus?) {
        if focus != status { focus = status }
    }
}
