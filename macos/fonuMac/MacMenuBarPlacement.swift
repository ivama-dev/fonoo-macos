import AppKit

/// AppKit persists positions as a distance from the right edge. Keep these
/// implementation-specific defaults isolated and never touch other apps' layout.
enum MacMenuBarPlacement {
    static let autosaveName = "fonoo.menu-bar"
    static let positionKey = "NSStatusItem Preferred Position " + autosaveName
    static let visibilityKey = "NSStatusItem Visible " + autosaveName

    static func prepare(in defaults: UserDefaults = .standard) {
        // Seed only new installations. A user's later Command-drag remains intact.
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(0.0, forKey: positionKey)
        }
    }

    static func restore(in defaults: UserDefaults = .standard) {
        defaults.set(0.0, forKey: positionKey)
        defaults.set(true, forKey: visibilityKey)
    }

    static func fits(_ item: NSRect, screen: NSRect, left: NSRect?, right: NSRect?) -> Bool {
        guard item.width > 0, item.height > 0, screen.contains(item) else { return false }
        if let left, let right { return left.contains(item) || right.contains(item) }
        return true
    }
}
