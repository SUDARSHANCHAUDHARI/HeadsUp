import Foundation

// How the head looks: a shape, three swatches, a speed, and whether the
// antenna and the animation are on. Kept in UserDefaults, so a choice from
// the menu bar survives a relaunch.
//
// Only names cross the bridge to the page; the hex values live in the
// swatch tables in web/src/main.ts, and these lists must match them. Both
// come from robot-heads' own playground (site/src/App.tsx).
struct Look: Equatable {
    static let shapes = ["rectangle", "square", "circle", "hexagon"]
    static let shells = ["Cobalt", "Tomato", "Tangerine", "Mustard", "Mint", "Teal", "Grape", "Bubblegum", "Graphite", "Porcelain"]
    static let trims = ["Steel", "Silver", "Brass", "Copper", "Black"]
    static let screens = ["White", "Ice", "Matrix", "Amber", "Neon"]
    static let speeds: [Double] = [0.5, 1, 1.5, 2]

    var shape = "rectangle"
    var shell = "Cobalt"
    var trim = "Steel"
    var screen = "White"
    var speed = 1.0
    var paused = false
    var antenna = true

    private static let key = "look"

    /// Anything missing or unknown keeps its default, so a stale or
    /// hand-edited preference can never leave the head unreadable.
    static func load() -> Look {
        var look = Look()
        guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return look }
        if let value = saved["shape"] as? String, shapes.contains(value) { look.shape = value }
        if let value = saved["shell"] as? String, shells.contains(value) { look.shell = value }
        if let value = saved["trim"] as? String, trims.contains(value) { look.trim = value }
        if let value = saved["screen"] as? String, screens.contains(value) { look.screen = value }
        if let value = saved["speed"] as? Double, speeds.contains(value) { look.speed = value }
        if let value = saved["paused"] as? Bool { look.paused = value }
        if let value = saved["antenna"] as? Bool { look.antenna = value }
        return look
    }

    func save() {
        UserDefaults.standard.set([
            "shape": shape, "shell": shell, "trim": trim, "screen": screen,
            "speed": speed, "paused": paused, "antenna": antenna,
        ], forKey: Self.key)
    }

    /// The argument for the page's `setLook()`.
    var json: String {
        let fields: [String: Any] = [
            "shape": shape, "shell": shell, "trim": trim, "screen": screen,
            "speed": speed, "paused": paused, "antenna": antenna,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// `1×`, `0.5×` — a whole number loses its decimal point.
    static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }
}
