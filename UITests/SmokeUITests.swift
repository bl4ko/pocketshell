import XCTest

@MainActor
final class SmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if let key = ProcessInfo.processInfo.environment["PS_TEST_KEY"] {
            app.launchEnvironment["PS_TEST_KEY"] = key
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
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["localbox"].firstMatch.waitForExistence(timeout: 5))

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

        let sessionRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", session)
        ).firstMatch
        XCTAssertTrue(app.staticTexts["Sessions"].firstMatch.waitForExistence(timeout: 10))
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
}
