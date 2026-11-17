import XCTest

// Plays a flow (scripts/flows/*.flow, run by scripts/sim) on the installed hex Exact, one command a
// line. A query is an element's testId, text its label holds, or `home-row-*`: the first whose
// testId starts with `home-row-`.
//   launch <path>          starts the app afresh at that screen: /tasks, or call:/tasks for the demo
//                          call first; waits until it has drawn
//   open <path>            the same link into the running app
//   tap <query>            taps it; with the keyboard up, the middle of what shows of it above it
//   press <testId>         taps the one element with that testId (`*` at the end: the first whose
//                          testId starts so), found by one query: quicker than tap, which reads the
//                          whole tree to choose among elements that share a name
//   hold <query>           presses it for a second, as for a context menu
//   tap-at <x> <y>         taps that point of the window
//   type <query> <text>    taps the field and types on the software keyboard, after what it holds
//                          (each flow starts on a fresh install, so only this flow's drafts)
//   swipe-left <query>     swipes left across the row or pager holding it; swipe-right the other way
//   swipe-back <query>     drags from it across the screen, the way an edge swipe goes
//   swipe-down <query>     drags from it to the screen's foot, as to pull a sheet or keyboard away
//   scroll <query>         swipes up the list holding it; scroll-back swipes it down
//   reveal <query>         drags its list slowly until it sits in the middle half of the window
//   shoot <name>           holds still while scripts/sim screenshots the screen as <name>
//   snap <name>            has it screenshot at once and goes on, to catch what moves
//   pose <pose>            has scripts/sim fold or turn the Duo there, the app still running
//   wait <seconds>
//   exists <query>, absent <query>
//   shows <testId>         the element with that testId comes on screen within 10 s (a|b: either)
//   gone <testId>          it leaves the screen within 20 s (a Loading note, say)
//   mark <query>, then still <query>: it hasn't moved or resized
//   apart <query> <query>  the two don't overlap
//   above-keyboard <query> the keyboard is up and the element shows whole above it
//   no-keyboard            the keyboard has gone
//   tree <name>            keeps the accessibility tree as it is now, as <name>
//   system <label>         taps that button on a system alert, like a permission's Allow
// A line whose element isn't there fails and the flow goes on, so one run shows every step.
final class Flows: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.shahidy.hexexact")
    var marked: [String: CGRect] = [:]

    override func setUp() {
        // scripts/sim acts on each line as it's printed, so none may wait in a buffer.
        setvbuf(stdout, nil, _IONBF, 0)
        continueAfterFailure = true
    }

    override func tearDown() {
        keepTree(nil)
    }

    func testFlow() throws {
        let flow = try XCTUnwrap(ProcessInfo.processInfo.environment["FLOW"], "no flow")
        for line in flow.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = words.first, !command.hasPrefix("#") else { continue }
            print("flow-line \(line)")
            let argument = words.count > 1 ? words[1] : ""
            switch command {
            case "launch":
                app.terminate()
                // The shell opens a `-HexOpen` link at launch, without the prompt iOS shows before
                // a link from outside.
                app.launchArguments = ["-HexOpen", link(argument)]
                app.launch()
                XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 20), "\(argument) drew nothing in 20 s")
                sleep(3)
            case "open": app.open(try XCTUnwrap(URL(string: link(argument))))
            case "tap": element(argument).map { tap($0, argument) }
            case "press":
                guard seen(argument, within: 10) else { XCTFail("nothing has the testId \(argument), so its line was skipped"); break }
                app.descendants(matching: .any).matching(ids(argument)).firstMatch.tap()
            case "hold": element(argument)?.press(forDuration: 1)
            case "tap-at":
                let point = argument.split(separator: " ").compactMap { Double($0) }
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point[0], dy: point[1])).tap()
            case "type":
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard let field = element(parts[0]) else { break }
                // A second tap on a field that has the keyboard opens iOS's edit menu.
                if (field.value(forKey: "hasKeyboardFocus") as? Bool) != true { field.tap() }
                field.typeText(parts.count > 1 ? parts[1] : "")
            case "swipe-left": element(argument).map { holder($0, rows: true).swipeLeft() }
            case "swipe-right": element(argument).map { holder($0, rows: true).swipeRight() }
            case "swipe-back":
                element(argument)?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
            case "swipe-down":
                element(argument)?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            case "scroll": element(argument).map { list($0).swipeUp() }
            case "scroll-back": element(argument).map { list($0).swipeDown() }
            case "reveal":
                for _ in 0..<4 {
                    guard let found = element(argument) else { break }
                    let window = app.windows.firstMatch
                    let shift = found.frame.midY - window.frame.midY
                    if abs(shift) < window.frame.height / 4 { break }
                    // Held at the end of a slow drag, a list moves as far as the finger did and no further.
                    let middle = window.coordinate(withNormalizedOffset: CGVector(dx: (found.frame.midX - window.frame.minX) / window.frame.width, dy: 0.5))
                    let step = max(-window.frame.height * 0.4, min(window.frame.height * 0.4, shift))
                    middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -step)), withVelocity: .slow, thenHoldForDuration: 0.5)
                    sleep(1)
                }
            case "shoot", "pose":
                sleep(1)
                print("flow-\(command) \(argument)")
                waitForSim()
                // A fold or turn moves the window.
                if command == "pose" { screen = nil }
            case "snap": print("flow-snap \(argument)")
            case "wait": usleep(UInt32((Double(argument) ?? 1) * 1_000_000))
            case "exists": _ = element(argument)
            case "absent": XCTAssertFalse(app.descendants(matching: .any)[argument].exists, "\(argument) is there")
            case "shows": XCTAssertTrue(onScreen(argument, within: 10), "\(argument) didn't come on screen in 10 s")
            case "gone": XCTAssertTrue(onScreen(argument, within: 20, gone: true), "\(argument) was still on screen after 20 s")
            case "mark": marked[argument] = element(argument)?.frame
            case "still":
                guard let was = marked[argument] else { XCTFail("\(argument) wasn't marked"); break }
                guard let now = element(argument)?.frame else { break }
                XCTAssertEqual(now.minX, was.minX, accuracy: 1, "\(argument) moved from \(was) to \(now)")
                XCTAssertEqual(now.minY, was.minY, accuracy: 1, "\(argument) moved from \(was) to \(now)")
                XCTAssertEqual(now.width, was.width, accuracy: 1, "\(argument) resized from \(was) to \(now)")
                XCTAssertEqual(now.height, was.height, accuracy: 1, "\(argument) resized from \(was) to \(now)")
            case "apart":
                let names = argument.split(separator: " ").map(String.init)
                guard let one = element(names[0])?.frame, let other = element(names[1])?.frame else { break }
                XCTAssertFalse(one.intersects(other), "\(names[0]) \(one) overlaps \(names[1]) \(other)")
            case "above-keyboard":
                let keyboard = app.keyboards.firstMatch
                XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the keyboard isn't up")
                guard let frame = element(argument)?.frame else { break }
                XCTAssertLessThanOrEqual(frame.maxY, keyboard.frame.minY, "\(argument) ends \(frame.maxY) under the keyboard's top \(keyboard.frame.minY)")
            case "no-keyboard":
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the keyboard is still up")
            case "tree": keepTree(argument)
            case "system":
                let button = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons[argument]
                if button.waitForExistence(timeout: 5) { button.tap() } else { print("flow-note no system alert with \(argument)") }
            default: XCTFail("unknown flow command: \(line)")
            }
        }
    }

    /// Whether an element with exactly this testId is on screen (or, `gone`, isn't), asked until `within` seconds pass.
    private func onScreen(_ id: String, within seconds: Double, gone: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if seen(id, within: 0) != gone { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// Whether an element with these testIds has its middle on screen, read in one snapshot (each
    /// read of a big tree takes a moment), asked until `within` seconds pass.
    private var screen: CGRect?
    private func seen(_ id: String, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        let window = screen ?? app.windows.firstMatch.frame
        screen = window
        let found = app.descendants(matching: .any).matching(ids(id)).firstMatch
        repeat {
            if let frame = try? found.snapshot().frame, window.contains(CGPoint(x: frame.midX, y: frame.midY)) { return true }
            if seconds > 0 { usleep(200_000) }
        } while Date() < deadline
        return false
    }

    /// Exactly these testIds (`a|b`), or those starting so (`row-*`).
    private func ids(_ query: String) -> NSPredicate {
        query.hasSuffix("*")
            ? NSPredicate(format: "identifier BEGINSWITH %@", String(query.dropLast()))
            : NSPredicate(format: "identifier IN %@", query.split(separator: "|").map(String.init))
    }

    /// `/tasks` opens Tasks; `call:/tasks` starts the demo call, then opens Tasks over it.
    private func link(_ path: String) -> String {
        path.hasPrefix("call:") ? "hexexact://demo" + path.dropFirst(5) : path.hasPrefix("/") ? "hexexact://go" + path : path
    }

    private func keepTree(_ name: String?) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name.map { "tree-\($0)" } ?? "tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    // Pages that have left can stay in the tree off screen, so the first match on screen wins, one
    // named by the query before one that only mentions it, whole if one is. One snapshot decides,
    // since a live list can change between reading a match's place and touching it.
    private func element(_ query: String) -> XCUIElement? {
        let matches = app.descendants(matching: .any).matching(predicate(query))
        guard matches.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("nothing matches \(query), so its line was skipped")
            return nil
        }
        guard let tree = try? app.snapshot() else { return matches.firstMatch }
        let screen = app.windows.firstMatch.frame
        let onScreen = matching(query, in: tree).enumerated()
            .filter { screen.contains(CGPoint(x: $0.element.frame.midX, y: $0.element.frame.midY)) }
        let named = onScreen.filter { $0.element.identifier == query || $0.element.label == query || $0.element.label.hasPrefix(query + " ") }
        let pick = (named.isEmpty ? onScreen : named).first { screen.contains($0.element.frame) } ?? onScreen.first
        return pick.map { matches.element(boundBy: $0.offset) } ?? matches.firstMatch
    }

    // `home-row-*` is the first whose testId starts so, as a row's testId carries its id.
    private func predicate(_ query: String) -> NSPredicate {
        query.hasSuffix("*")
            ? NSPredicate(format: "identifier BEGINSWITH %@", String(query.dropLast()))
            : NSPredicate(format: "identifier == %@ OR label CONTAINS %@", query, query)
    }

    private func matching(_ query: String, in tree: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        let hit = query.hasSuffix("*")
            ? { (s: XCUIElementSnapshot) in s.identifier.hasPrefix(query.dropLast()) }
            : { (s: XCUIElementSnapshot) in s.identifier == query || s.label.contains(query) }
        return tree.children.flatMap { child in (hit(child) ? [child] : []) + matching(query, in: child) }
    }

    // With the keyboard up, XCUITest's own tap can land on the keyboard even for a view drawn wholly
    // above it, so it taps the middle of what shows of the view above the keyboard instead.
    private func tap(_ element: XCUIElement, _ query: String) {
        let keyboard = app.keyboards.firstMatch
        let window = app.windows.firstMatch
        var shows = element.frame.intersection(window.frame)
        if keyboard.exists { shows.size.height = max(0, min(shows.height, keyboard.frame.minY - shows.minY)) }
        guard keyboard.exists, !shows.isEmpty else { return element.tap() }
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: shows.midX, dy: shows.midY)).tap()
    }

    // Waits until scripts/sim has shot or posed what was just asked: it touches <FLOW_SYNC>/<n> for
    // the nth, in a folder on the Mac the simulator reads directly.
    private var asked = 0
    private func waitForSim() {
        asked += 1
        let done = (ProcessInfo.processInfo.environment["FLOW_SYNC"] ?? "") + "/\(asked)"
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: done) && Date() < deadline { usleep(100_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "scripts/sim didn't finish step \(asked) in 2 minutes")
    }

    // The list under the element, or the element when it is one.
    private func list(_ found: XCUIElement) -> XCUIElement {
        [.collectionView, .scrollView, .table].contains(found.elementType) ? found : holder(found, rows: false)
    }

    // The smallest list or scroll view under the element, or with rows the smallest row too.
    private func holder(_ inside: XCUIElement, rows: Bool) -> XCUIElement {
        let point = CGPoint(x: inside.frame.midX, y: inside.frame.midY)
        let around = (app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex + (rows ? app.cells.allElementsBoundByIndex : []))
            .filter { $0.frame.contains(point) }
        return around.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? inside
    }
}
