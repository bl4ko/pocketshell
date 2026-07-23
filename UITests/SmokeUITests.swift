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

        app.buttons["plus"].firstMatch.tap()
        let sshHostItem = app.buttons["SSH Host"].firstMatch
        XCTAssertTrue(sshHostItem.waitForExistence(timeout: 5))
        sshHostItem.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("localbox")
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

        let hostRow = app.staticTexts["localbox"].firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5))
        hostRow.tap()

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

        app.staticTexts["localbox"].firstMatch.tap()
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

        let hostRow = app.staticTexts["localbox"].firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5))
        hostRow.tap()
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))

        let tabs = (1...3).map { app.descendants(matching: .any)["terminal-tab-\($0)"] }
        for tab in tabs {
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            expectation(
                for: NSPredicate(format: "label CONTAINS 'idle'"),
                evaluatedWith: tab
            )
        }
        waitForExpectations(timeout: 25)

        XCUIDevice.shared.press(.home)
        app.activate()

        for _ in 0..<25 {
            for tab in tabs {
                XCTAssertTrue(tab.label.contains("idle"), "unexpected tab status: \(tab.label)")
            }
            sleep(1)
        }
    }

    func testTmuxSessionListedAndAttaches() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PS_TEST_PORT"] != nil, let session = env["PS_TEST_TMUX"] else {
            throw XCTSkip("PS_TEST_TMUX not set; tmux e2e skipped")
        }

        let hostRow = app.staticTexts["localbox"].firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5))
        hostRow.tap()

        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["tmux-sessions"].firstMatch.tap()

        let sessionRow = app.descendants(matching: .any)["tmux-session-\(session)"]
        XCTAssertTrue(app.navigationBars["Switcher"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search tabs, sessions, windows"].waitForExistence(timeout: 5))
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

        let windowRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'pshwin'")
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
        windowRow.tap()

        XCTAssertTrue(app.navigationBars["Switcher"].firstMatch.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["esc"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'HOST KEY'")
            ).firstMatch.exists)
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

        app.staticTexts["localbox"].firstMatch.tap()
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

}
