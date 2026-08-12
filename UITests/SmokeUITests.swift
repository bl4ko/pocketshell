import XCTest
import UIKit

@MainActor
final class SmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PS_UI_TEST"] = "1"
        var environmentKeys = ["PS_TEST_KEY"]
        if name.contains("testTabStatuses") {
            environmentKeys += ["PS_TEST_STATUS_STABLE", "PS_TEST_STATUS_CHURN", "PS_TEST_STATUS_GAP"]
        }
        if name.contains("testTmuxRepaints") {
            environmentKeys.append("PS_TEST_FLICKER")
        }
        for key in environmentKeys {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        if name.contains("testKeyboardToggle") {
            app.launchEnvironment["PS_UI_TEST_KEYBOARD_RESIZE"] = "1"
        }
        app.launch()
    }

    func testAddHostAndRunExecSnippet() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PS_TEST_PORT"], let user = env["PS_TEST_USER"] else {
            throw XCTSkip("PS_TEST_PORT/PS_TEST_USER not set; sshd-backed smoke skipped")
        }

        addHost(named: "localbox", port: port, user: user)

        XCTAssertTrue(app.staticTexts["localbox"].firstMatch.waitForExistence(timeout: 5))

        app.buttons["plus"].firstMatch.tap()
        app.buttons["Snippets"].tap()
        app.buttons["plus"].firstMatch.tap()
        let snippetName = app.textFields["Name"]
        XCTAssertTrue(snippetName.waitForExistence(timeout: 5))
        snippetName.tap()
        snippetName.typeText("smoke")
        app.textFields["Command"].tap()
        app.textFields["Command"].typeText("echo pocketshell-ok")
        let runModePicker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Run mode'")
        ).firstMatch
        runModePicker.tap()
        app.buttons["Exec, show output"].firstMatch.tap()
        app.buttons["Save"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        let hostRow = app.staticTexts["localbox"].firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5))
        hostRow.press(forDuration: 1.5)
        let runButton = app.buttons["smoke"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        runButton.tap()

        let output = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'pocketshell-ok'")
        ).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 15))
    }

    func testGroupDropdownOffersExistingGroup() {
        app.buttons["plus"].firstMatch.tap()
        app.buttons["SSH Host"].firstMatch.tap()
        let picker = app.buttons["group-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        XCTAssertTrue(app.buttons["lab"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
    }

    func testTerminalOpensShellWithToolbar() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed smoke skipped")
        }

        XCTAssertTrue(app.staticTexts["localbox"].firstMatch.waitForExistence(timeout: 5))
        openHost("localbox")

        let escKey = app.buttons["esc"].firstMatch
        XCTAssertTrue(escKey.waitForExistence(timeout: 10))
        sleep(3)

        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'HOST KEY'")
            ).firstMatch.exists)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'retrying'")
            ).firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTerminalUsesSelectedTheme() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed theme test skipped")
        }

        app.buttons["Settings"].tap()
        let theme = app.buttons["Solarized Dark"]
        for _ in 0..<6 where !theme.exists {
            app.swipeUp()
        }
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.tap()
        XCTAssertTrue(theme.isSelected)
        app.navigationBars.buttons.firstMatch.tap()

        openHost("localbox")
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.typeText("printf '\\033]11;#000000\\007'\n")
        sleep(2)

        let capture = XCUIScreen.main.screenshot()
        let pixel = pixel(capture.image)
        XCTAssertLessThan(pixel.red, 20)
        XCTAssertGreaterThan(pixel.green, 25)
        XCTAssertGreaterThan(pixel.blue, 35)

        let screenshot = XCTAttachment(screenshot: capture)
        screenshot.name = "solarized-terminal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func pixel(_ image: UIImage, x: CGFloat = 0.5, y: CGFloat = 0.5)
        -> (red: UInt8, green: UInt8, blue: UInt8)
    {
        guard let source = image.cgImage,
            let crop = source.cropping(
                to: CGRect(
                    x: Int(CGFloat(source.width) * x),
                    y: Int(CGFloat(source.height) * y),
                    width: 1,
                    height: 1
                )
            )
        else {
            XCTFail("could not read terminal screenshot")
            return (0, 0, 0)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    func testTabStatusesStayIdleAcrossUpdatesAndRedraws() throws {
        let env = ProcessInfo.processInfo.environment
        guard
            env["PS_TEST_STATUS_STABLE"] != nil,
            env["PS_TEST_STATUS_CHURN"] != nil,
            env["PS_TEST_STATUS_GAP"] != nil
        else {
            throw XCTSkip("status fixtures not set; tmux status e2e skipped")
        }

        XCTAssertTrue(app.staticTexts["localbox"].firstMatch.waitForExistence(timeout: 5))
        openHost("localbox")
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))

        let tabs = (1...3).map { app.descendants(matching: .any)["terminal-tab-\($0)"] }
        let sessions = [env["PS_TEST_STATUS_STABLE"]!, env["PS_TEST_STATUS_CHURN"]!, env["PS_TEST_STATUS_GAP"]!]
        for tab in tabs {
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            expectation(
                for: NSPredicate(format: "label CONTAINS 'idle'"),
                evaluatedWith: tab
            )
        }
        waitForExpectations(timeout: 25)
        for (tab, session) in zip(tabs, sessions) {
            XCTAssertTrue(tab.label.contains(session), "tab omits tmux session: \(tab.label)")
        }

        let firstGroup = app.buttons["tab-strip-group-\(sessions[0])"]
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        firstGroup.tap()
        XCTAssertTrue(tabs[0].waitForNonExistence(timeout: 2))
        XCTAssertTrue(firstGroup.label.contains("collapsed"))
        firstGroup.tap()
        XCTAssertTrue(tabs[0].waitForExistence(timeout: 2))

        XCUIDevice.shared.press(.home)
        app.activate()

        for _ in 0..<25 {
            for tab in tabs {
                XCTAssertTrue(tab.label.contains("idle"), "unexpected tab status: \(tab.label)")
            }
            sleep(1)
        }

        firstGroup.tap()
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["localbox"].firstMatch.waitForExistence(timeout: 5))
        openHost("localbox")
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(firstGroup.label.contains("collapsed"))
        XCTAssertFalse(tabs[0].exists)

        app.buttons["tmux-sessions"].tap()
        for session in sessions {
            XCTAssertTrue(app.descendants(matching: .any)["tab-group-\(session)"].waitForExistence(timeout: 3))
        }
    }

    func testTmuxSessionListedAndAttaches() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PS_TEST_PORT"], let user = env["PS_TEST_USER"],
            let session = env["PS_TEST_TMUX"]
        else {
            throw XCTSkip("PS_TEST_TMUX not set; tmux e2e skipped")
        }

        let alternateHost = "backupbox-with-a-very-long-name"
        addHost(named: alternateHost, port: port, user: user)
        XCTAssertTrue(app.staticTexts["localbox"].firstMatch.waitForExistence(timeout: 5))
        openHost("localbox")

        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        let hostSwitcher = app.descendants(matching: .any)["host-switcher"]
        XCTAssertTrue(hostSwitcher.isHittable)
        hostSwitcher.tap()
        XCTAssertTrue(app.buttons[alternateHost].waitForExistence(timeout: 2))
        app.buttons[alternateHost].tap()
        let switchedHost = app.descendants(matching: .any)["host-switcher"]
        XCTAssertTrue(switchedHost.waitForExistence(timeout: 10))
        XCTAssertTrue(switchedHost.label.contains(alternateHost))
        let back = app.buttons["Back"]
        XCTAssertTrue(back.isHittable)
        XCTAssertLessThan(back.frame.maxX, switchedHost.frame.minX)
        for _ in 0..<7 {
            app.buttons["new-tab"].tap()
            dismissSessionPicker()
        }
        XCTAssertTrue(hostSwitcher.isHittable)
        let hostTitleScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        hostTitleScreenshot.name = "host-title-visible-with-tabs"
        hostTitleScreenshot.lifetime = .keepAlways
        add(hostTitleScreenshot)
        let firstTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'terminal-tab-'"))
            .firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: 10))
        firstTab.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Close Tab"].waitForExistence(timeout: 2))
        app.buttons["Close Tab"].tap()
        app.buttons["new-tab"].tap()
        app.buttons["tmux-sessions"].firstMatch.tap()

        let sessionRow = app.descendants(matching: .any)["tmux-session-\(session)"]
        XCTAssertTrue(app.navigationBars["Switcher"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search tabs, sessions, windows"].waitForExistence(timeout: 5))
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'switcher-tab-'"))
        let secondCard = cards.element(boundBy: 1)
        XCTAssertTrue(secondCard.waitForExistence(timeout: 5))
        let closedCardID = secondCard.identifier
        let retainedCardID = cards.element(boundBy: 2).identifier
        secondCard.press(forDuration: 1)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)[closedCardID].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)[retainedCardID].exists)
        app.buttons["toggle-tabs"].tap()
        XCTAssertTrue(app.navigationBars["Switcher"].firstMatch.exists)
        app.buttons["toggle-tabs"].tap()
        var swipes = 0
        while !sessionRow.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        if !sessionRow.waitForExistence(timeout: 5) {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "tmux-sheet"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("tmux session \(session) not listed")
        }

        let windowRow = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS 'pshwin'",
                "tmux-session-\(session)"
            )
        ).firstMatch
        if !windowRow.waitForExistence(timeout: 2) {
            sessionRow.tap()
        }
        swipes = 0
        while !windowRow.waitForExistence(timeout: 2) && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(windowRow.exists)
        if !windowRow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(windowRow.label.contains("OPEN IN NEW TAB"))
        let tabButtons = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'terminal-tab-'")
        )
        let tabCount = tabButtons.count
        windowRow.tap()

        XCTAssertTrue(app.navigationBars["Switcher"].firstMatch.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(tabButtons.count, tabCount + 1)
        let windowTab = tabButtons.element(boundBy: tabCount)
        XCTAssertTrue(windowTab.isSelected)
        XCTAssertTrue(windowTab.label.contains("pshwin"))
        XCTAssertFalse(windowTab.label.contains("\(session):"))
        firstTab.tap()
        XCTAssertTrue(firstTab.isSelected)

        app.buttons["tmux-sessions"].firstMatch.tap()
        let search = app.searchFields["Search tabs, sessions, windows"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(session)
        if !windowRow.waitForExistence(timeout: 2) {
            sessionRow.tap()
        }
        XCTAssertTrue(windowRow.waitForExistence(timeout: 5))
        windowRow.tap()
        XCTAssertTrue(windowTab.isSelected)
        XCTAssertEqual(tabButtons.count, tabCount + 1)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'HOST KEY'")
            ).firstMatch.exists)
    }

    func testTmuxNewWindowButtonCreatesWindow() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PS_TEST_PORT"], let user = env["PS_TEST_USER"],
            let session = env["PS_TEST_TMUX"]
        else {
            throw XCTSkip("PS_TEST_TMUX not set; tmux e2e skipped")
        }

        addHost(named: "windowbox", port: port, user: user)
        openHost("windowbox")
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["tmux-sessions"].firstMatch.tap()

        let sessionRow = app.descendants(matching: .any)["tmux-session-\(session)"]
        XCTAssertTrue(app.navigationBars["Switcher"].firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        for _ in 0..<20 where !sessionRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 10))
        sessionRow.tap()
        let newWindow = app.buttons["new window in \(session)"]
        for _ in 0..<4 where !newWindow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(newWindow.waitForExistence(timeout: 2))
        newWindow.tap()
        let updatedSession = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS '2 windows'", "tmux-session-\(session)"
            )
        ).firstMatch
        XCTAssertTrue(updatedSession.waitForExistence(timeout: 5))
        let createdWindow = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS '1:'", "tmux-session-\(session)")
        ).firstMatch
        XCTAssertTrue(createdWindow.waitForExistence(timeout: 5))
        createdWindow.press(forDuration: 1)
        app.buttons["Delete"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        XCTAssertLessThan(abs(alert.frame.midX - app.frame.midX), 2)
        app.buttons["Cancel"].tap()
    }

    func testTmuxRepaintsKeepCaretParked() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PS_TEST_PORT"], let user = env["PS_TEST_USER"],
            env["PS_TEST_FLICKER"] != nil
        else {
            throw XCTSkip("PS_TEST_FLICKER not set; tmux repaint e2e skipped")
        }

        addHost(named: "flickerbox", port: port, user: user)
        app.staticTexts["flickerbox"].firstMatch.tap()
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        let terminal = app.descendants(matching: .any)["terminal.view"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.tap()
        sleep(2)

        for frame in 0..<40 {
            // Local input used to bypass display coalescing, exposing tmux's
            // cursor hide and one partial repaint per split before the final park.
            app.buttons["esc"].firstMatch.tap()
            let capture = XCUIScreen.main.screenshot()
            if !caretVisible(capture.image, terminal: terminal.frame) {
                let attachment = XCTAttachment(screenshot: capture)
                attachment.name = "missing-parked-caret-\(frame)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTFail("tmux repaint hid the parked caret")
                return
            }
        }
    }

    func testKeysScreenShowsDevicePublicKey() {
        app.buttons["Keys"].tap()
        let installSection = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'authorized_keys'")
        ).firstMatch
        XCTAssertTrue(installSection.waitForExistence(timeout: 10))
        let keyLine = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'ecdsa-sha2-nistp256'")
        ).firstMatch
        XCTAssertTrue(keyLine.exists)
    }

    func testKeyboardToggleWithLongScrollback() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed keyboard test skipped")
        }

        openHost("localbox")
        let keyboardButton = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 10))
        let terminal = app.textViews["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.tap()
        terminal.typeText("i=0; while [ $i -lt 600 ]; do echo history-$i; i=$((i+1)); done\n")
        sleep(2)
        let compactHeight = terminal.frame.height
        XCTAssertEqual(terminal.value as? String, "bottom")
        terminal.swipeDown()
        XCTAssertEqual(terminal.value as? String, "history")
        terminal.swipeUp()
        XCTAssertEqual(terminal.value as? String, "bottom")

        for _ in 0..<3 {
            keyboardButton.tap()
            XCTAssertGreaterThan(terminal.frame.height, compactHeight + 200)
            XCTAssertEqual(terminal.value as? String, "bottom")
            keyboardButton.tap()
            XCTAssertEqual(terminal.frame.height, compactHeight, accuracy: 2)
            XCTAssertEqual(terminal.value as? String, "bottom")
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-long-scrollback-after-keyboard-toggle"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDiffSheetListsTheWorkingTree() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed diff test skipped")
        }

        openHost("localbox")
        XCTAssertTrue(app.buttons["terminal.compose"].waitForExistence(timeout: 10))
        app.buttons["terminal.more"].firstMatch.tap()
        let diffItem = app.buttons["menu-diff"].firstMatch
        XCTAssertTrue(diffItem.waitForExistence(timeout: 5))
        diffItem.tap()
        // The login directory is the developer's home: either a clean tree, a
        // real diff, or "not a git repository" — all of them mean the sheet ran.
        XCTAssertTrue(app.buttons["diff.reload"].waitForExistence(timeout: 15))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["terminal.compose"].waitForExistence(timeout: 10))
    }

    func testComposerSendsAPromptAndKeepsTheDraftAcrossNavigation() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed composer test skipped")
        }

        openHost("localbox")
        XCTAssertTrue(app.buttons["terminal.compose"].waitForExistence(timeout: 10))
        // Cmd-J opens it: toolbar buttons in the clipped keyboard row are not reliably
        // hittable from XCUITest, and the shortcut is the same path an iPad user takes.
        // The first key event can land before the terminal screen has settled.
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        for _ in 0..<3 where !field.exists {
            app.typeKey("j", modifierFlags: .command)
            _ = field.waitForExistence(timeout: 3)
        }
        // A vertical-axis SwiftUI TextField surfaces as a text view, not a text field.
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("echo composed-ok")

        // The draft belongs to the session, not to the screen: leaving and coming back
        // must not lose a half-written prompt.
        app.navigationBars.buttons.firstMatch.tap()
        app.staticTexts["localbox"].firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "echo composed-ok")

        app.buttons["composer.send"].tap()
        let empty = NSPredicate(format: "value == 'message…' OR value == ''")
        expectation(for: empty, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'error'")).firstMatch.exists)

        // The toolbar button is the touch path for the same toggle.
        app.buttons["terminal.compose"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(field.waitForExistence(timeout: 2))
    }

    func testJapaneseImeComposesInlineAtTheCaret() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed IME test skipped")
        }

        openHost("localbox")
        let keyboardButton = app.buttons["terminal.keyboard"]
        guard keyboardButton.waitForExistence(timeout: 15) else {
            throw XCTSkip("terminal toolbar never appeared")
        }
        keyboardButton.tap()
        guard app.keyboards.element.waitForExistence(timeout: 5) else {
            // The simulator hides it whenever a hardware keyboard is attached, and
            // xcodebuild-driven runs usually have one.
            throw XCTSkip("no software keyboard on this simulator")
        }
        // Japanese Romaji, not Korean: iOS composes kana through marked text, while the
        // Korean keyboard hands SwiftTerm finished jamo that it assembles itself.
        let globe = app.buttons["Next keyboard"]
        for _ in 0..<3 where globe.exists && !app.otherElements["terminal.composition"].exists {
            globe.tap()
            _ = app.keys["n"].waitForExistence(timeout: 2)
        }
        guard app.keys["n"].exists else {
            throw XCTSkip("no Japanese keyboard on this simulator")
        }

        // Marked text never reaches the host and SwiftTerm does not draw it, so this
        // overlay is the only thing a CJK user sees while composing.
        app.keys["n"].tap()
        app.keys["i"].tap()
        let composition = app.otherElements["terminal.composition"]
        guard composition.waitForExistence(timeout: 3), composition.value as? String == "に" else {
            throw XCTSkip(
                "Japanese IME did not compose here: \(composition.value as? String ?? "no overlay")")
        }

        // Enter commits: the bytes go to the shell and the overlay clears.
        app.keys["return"].firstMatch.tap()
        let cleared = NSPredicate(format: "value == '' OR exists == false")
        expectation(for: cleared, evaluatedWith: composition)
        waitForExpectations(timeout: 3)
    }

    func testSettingsThemeSelection() {
        app.buttons["Settings"].tap()
        let dracula = app.buttons["Dracula"]
        for _ in 0..<4 where !dracula.exists {
            app.swipeUp()
        }
        XCTAssertTrue(dracula.waitForExistence(timeout: 5))
        let defaultTheme = app.buttons["Default"]
        dracula.tap()
        XCTAssertTrue(dracula.isSelected)
        defaultTheme.tap()
        XCTAssertTrue(defaultTheme.isSelected)

        let solarized = app.buttons["Solarized Dark"]
        for _ in 0..<4 where !solarized.exists {
            app.swipeUp()
        }
        solarized.tap()
        XCTAssertTrue(solarized.isSelected)
        app.navigationBars.buttons.firstMatch.tap()

        let background = pixel(XCUIScreen.main.screenshot().image, x: 0.01, y: 0.5)
        XCTAssertLessThan(background.red, 20)
        XCTAssertGreaterThan(background.green, 25)
        XCTAssertGreaterThan(background.blue, 35)

        app.buttons["Settings"].tap()
        let pocketshellAgain = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Pocketshell'")
        ).firstMatch
        for _ in 0..<4 where !pocketshellAgain.exists {
            app.swipeUp()
        }
        pocketshellAgain.tap()
        app.navigationBars.buttons.firstMatch.tap()

        let accent = pixel(XCUIScreen.main.screenshot().image, x: 0.91, y: 0.11)
        XCTAssertGreaterThan(accent.red, 150)
        XCTAssertLessThan(accent.blue, 100)
    }

    private func caretVisible(_ image: UIImage, terminal: CGRect) -> Bool {
        for x in stride(from: terminal.minX + 1, through: terminal.minX + 50, by: 2) {
            for y in stride(from: terminal.minY + 1, through: terminal.minY + 18, by: 2) {
                let color = pixel(image, x: x / image.size.width, y: y / image.size.height)
                if color.red > 100, color.green > 100, color.blue > 100 {
                    return true
                }
            }
        }
        return false
    }

    /// Opens a saved host and lands in a terminal.
    ///
    /// A host that already has tmux or Herdr sessions shows the session picker first, so a
    /// test that wants a shell has to say so; on a host with no sessions it never appears.
    private func openHost(_ name: String) {
        app.staticTexts[name].firstMatch.tap()
        dismissSessionPicker()
    }

    private func dismissSessionPicker() {
        let plainShell = app.buttons["Plain shell"].firstMatch
        if plainShell.waitForExistence(timeout: 5) {
            plainShell.tap()
        }
    }

    private func addHost(named name: String, port: String, user: String) {
        app.buttons["plus"].firstMatch.tap()
        let sshHostItem = app.buttons["SSH Host"].firstMatch
        XCTAssertTrue(sshHostItem.waitForExistence(timeout: 5))
        sshHostItem.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        app.textFields["Hostname or IP"].tap()
        app.textFields["Hostname or IP"].typeText("127.0.0.1")
        let portField = app.textFields["Port"]
        portField.tap()
        portField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        portField.typeText(port)
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText(user)
        app.textFields["Group (optional)"].tap()
        app.textFields["Group (optional)"].typeText("lab")
        app.buttons["Save"].tap()
    }

}
