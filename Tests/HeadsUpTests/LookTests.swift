import XCTest
@testable import HeadsUp

// Look is the only part of the app with logic worth pinning down: it reads
// preferences a human can edit by hand, and it builds the JSON the page
// trusts. Every test uses its own UserDefaults suite, so the real
// preferences are never touched.
final class LookTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "HeadsUpTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testLoadWithNothingSavedGivesTheDefaults() {
        XCTAssertEqual(Look.load(from: defaults), Look())
    }

    func testSavedLookSurvivesARoundTrip() {
        var look = Look()
        look.shape = "hexagon"
        look.shell = "Tomato"
        look.trim = "Brass"
        look.screen = "Matrix"
        look.speed = 1.5
        look.paused = true
        look.antenna = false
        look.save(to: defaults)

        XCTAssertEqual(Look.load(from: defaults), look)
    }

    /// The point of the guard: a hand-edited preference cannot leave the head
    /// unreadable, however wrong it is.
    func testUnknownValuesFallBackToTheirDefaults() {
        defaults.set([
            "shape": "banana",
            "shell": "Octarine",
            "trim": 7,
            "screen": "",
            "speed": 99.0,
            "paused": "yes",
            "antenna": "no",
        ], forKey: "look")

        XCTAssertEqual(Look.load(from: defaults), Look())
    }

    func testAMissingFieldKeepsItsDefaultAndTheRestStillLoads() {
        defaults.set(["shape": "circle"], forKey: "look")

        let look = Look.load(from: defaults)
        XCTAssertEqual(look.shape, "circle")
        XCTAssertEqual(look.shell, Look().shell)
        XCTAssertEqual(look.speed, Look().speed)
        XCTAssertEqual(look.antenna, Look().antenna)
    }

    /// A speed the menu never offers is still rejected, since the page clamps
    /// at 4 and anything else would silently stick in the preferences.
    func testOnlyOfferedSpeedsLoad() {
        for speed in Look.speeds {
            defaults.set(["speed": speed], forKey: "look")
            XCTAssertEqual(Look.load(from: defaults).speed, speed)
        }
        defaults.set(["speed": 3.0], forKey: "look")
        XCTAssertEqual(Look.load(from: defaults).speed, Look().speed)
    }

    func testJSONCarriesEveryFieldThePageReads() throws {
        var look = Look()
        look.shape = "square"
        look.screen = "Neon"
        look.speed = 0.5
        look.paused = true

        let data = Data(look.json.utf8)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(fields["shape"] as? String, "square")
        XCTAssertEqual(fields["shell"] as? String, "Cobalt")
        XCTAssertEqual(fields["trim"] as? String, "Steel")
        XCTAssertEqual(fields["screen"] as? String, "Neon")
        XCTAssertEqual(fields["speed"] as? Double, 0.5)
        XCTAssertEqual(fields["paused"] as? Bool, true)
        XCTAssertEqual(fields["antenna"] as? Bool, true)
    }

    func testSpeedLabelDropsTheDecimalPointOnWholeNumbers() {
        XCTAssertEqual(Look.speedLabel(0.5), "0.5×")
        XCTAssertEqual(Look.speedLabel(1), "1×")
        XCTAssertEqual(Look.speedLabel(1.5), "1.5×")
        XCTAssertEqual(Look.speedLabel(2), "2×")
    }

    /// The Swift lists and the page's swatch tables are two halves of one
    /// bridge: a name only on this side would silently fall back on the page.
    func testTheSwatchListsMatchThePage() throws {
        let page = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("web/src/main.ts"),
            encoding: .utf8
        )
        for name in Look.shells + Look.trims + Look.screens {
            XCTAssertTrue(page.contains("  \(name): '#"), "web/src/main.ts has no swatch named \(name)")
        }
        for shape in Look.shapes {
            XCTAssertTrue(page.contains("'\(shape)'"), "web/src/main.ts does not know the shape \(shape)")
        }
    }
}
