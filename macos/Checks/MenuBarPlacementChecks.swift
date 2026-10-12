import AppKit

@main
struct MenuBarPlacementChecks {
    static func main() {
        let suite = "app.fonoo.checks.menu-bar." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fixture", forKey: "unrelated-setting")
        MacMenuBarPlacement.prepare(in: defaults)
        precondition(defaults.double(forKey: MacMenuBarPlacement.positionKey) == 0)
        defaults.set(865.0, forKey: MacMenuBarPlacement.positionKey)
        MacMenuBarPlacement.prepare(in: defaults)
        precondition(defaults.double(forKey: MacMenuBarPlacement.positionKey) == 865)
        MacMenuBarPlacement.restore(in: defaults)
        precondition(defaults.double(forKey: MacMenuBarPlacement.positionKey) == 0)
        precondition(defaults.bool(forKey: MacMenuBarPlacement.visibilityKey))
        precondition(defaults.string(forKey: "unrelated-setting") == "fixture")
        print("PASS: new installation seeded right; saved order preserved; explicit recovery scoped to fonu")

        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let left = NSRect(x: 0, y: 950, width: 650, height: 32)
        let right = NSRect(x: 862, y: 950, width: 650, height: 32)
        func fits(_ x: CGFloat, _ width: CGFloat = 26) -> Bool {
            MacMenuBarPlacement.fits(NSRect(x: x, y: 950, width: width, height: 32),
                screen: screen, left: left, right: right)
        }
        precondition(fits(1400) && fits(600))
        precondition(!fits(640) && !fits(700) && !fits(-50) && !fits(1500))
        precondition(!fits(600, 0))
        precondition(MacMenuBarPlacement.fits(NSRect(x: 700, y: 950, width: 26, height: 32),
            screen: screen, left: nil, right: nil))
        print("PASS: notch overlap, offscreen positions, compact icons and displays without a notch")
    }
}
