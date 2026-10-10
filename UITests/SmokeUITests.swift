import XCTest
import UIKit

@MainActor
final class SmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PS_UI_TEST"] = "1"
        app.launchEnvironment["PS_UI_TEST_RESET_TABS"] = "1"
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
        if name.contains("testKeyboard") {
            app.launchEnvironment["PS_UI_TEST_RESIZE_COUNT"] = "1"
        }
        if name.contains("testTerminalAttachment") {
            app.launchEnvironment["PS_UI_TEST_ATTACHMENT"] = "pocketshell-file-attachment\n"
        }
        if name.contains("testTerminalCamera") {
            app.launchEnvironment["PS_UI_TEST_CAMERA"] = "1"
        }
        if name.contains("testHerdrHostChoice") {
            app.launchEnvironment["PS_UI_TEST_HERDR_SESSIONS"] =
                #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
        }
        if name.contains("testHerdrSessionSwitch") {
            app.launchEnvironment["PS_UI_TEST_HERDR_SESSIONS"] =
                #"{"sessions":[{"name":"pskbdtest","default":false,"running":true}]}"#
        }
        if name.contains("testZZCloudRefresh") {
            app.launchEnvironment["PS_UI_TEST_LOCAL_CONFIG"] = configFixture(
                hosts: [
                    ("00000000-0000-0000-0000-000000000001", "bl4ot"),
                    ("00000000-0000-0000-0000-000000000002", "bl4ot-tailscale"),
                ])
            app.launchEnvironment["PS_UI_TEST_CLOUD_CONFIG"] = configFixture(
                hosts: [("00000000-0000-0000-0000-000000000001", "bl4ot")])
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
        XCTAssertTrue(output.waitForExistence(timeout: 45))
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

    func testHerdrHostChoiceSurvivesRestoredTabsAndOpensWithoutTabChrome() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; Herdr host choice skipped")
        }

        let host = app.staticTexts["localbox"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        XCTAssertTrue(app.buttons["Herdr"].waitForExistence(timeout: 5))
        app.buttons["Shells & tmux"].tap()
        dismissSessionPicker()
        XCTAssertTrue(app.descendants(matching: .any)["host-switcher"].waitForExistence(timeout: 10))
        app.buttons["Back"].tap()

        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        XCTAssertTrue(app.buttons["Herdr"].waitForExistence(timeout: 5))
        app.buttons["Herdr"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["host-switcher"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["new-tab"].exists)
        XCTAssertFalse(app.buttons["tmux-sessions"].exists)
    }

    func testHerdrSessionSwitchKeepsKeyboardHidden() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; Herdr keyboard test skipped")
        }
        let host = app.staticTexts["localbox"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        let shellMode = app.buttons["Shells & tmux"].firstMatch
        XCTAssertTrue(shellMode.waitForExistence(timeout: 5))
        shellMode.tap()
        let session = app.buttons["pskbdtest"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.element.exists)
        session.tap()
        XCTAssertTrue(app.buttons["terminal.shortcutsToggle"].waitForExistence(timeout: 20))
        sleep(4)
        XCTAssertFalse(app.keyboards.element.exists)
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

    func testTerminalArrowPanelReplacesKeyboardAndClearsShift() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; toolbar test skipped")
        }
        openHost("localbox")
        let toggle = app.buttons["terminal.shortcutsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["terminal.dpad"].exists)
        let terminal = app.textViews["terminal.view"]
        terminal.tap()
        terminal.typeText(" ")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        let typingHeight = terminal.frame.height
        let shift = app.buttons["terminal.arrowShift"]
        toggle.tap()
        let arrows = app.buttons["shortcuts.arrows"]
        XCTAssertTrue(arrows.waitForExistence(timeout: 5))
        arrows.tap()
        XCTAssertTrue(shift.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(terminal.frame.height, typingHeight - 30)
        XCTAssertGreaterThan(shift.frame.minY, toggle.frame.maxY)
        XCTAssertEqual(shift.value as? String, "off")
        shift.tap()
        XCTAssertEqual(shift.value as? String, "on")
        app.buttons["terminal.arrow.←"].tap()
        XCTAssertTrue(shift.exists)
        XCTAssertEqual(shift.value as? String, "off")

        for arrow in ["←", "↓", "↑", "→"] {
            app.buttons["terminal.arrow.\(arrow)"].tap()
            XCTAssertTrue(shift.exists)
            XCTAssertEqual(shift.value as? String, "off")
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-arrows-in-keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["shortcuts.close"].tap()
        XCTAssertTrue(shift.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
    }

    func testTerminalAutomaticallyShowsArrowsForSelectionPrompt() throws {
        guard let fixture = ProcessInfo.processInfo.environment["PS_TEST_ARROW_PROMPT"] else {
            throw XCTSkip("PS_TEST_ARROW_PROMPT not set; automatic arrow test skipped")
        }
        openHost("localbox")
        let terminal = app.textViews["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.tap()
        terminal.typeText("\u{03}")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))

        terminal.typeText("'\(fixture)'\n")
        let arrows = app.buttons["terminal.arrowShift"]
        XCTAssertTrue(arrows.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))
        app.buttons["terminal.arrow.↓"].tap()
        XCTAssertTrue(arrows.exists)
        app.buttons["terminal.enter"].tap()
        XCTAssertTrue(arrows.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))

        terminal.typeText("'\(fixture)'\n")
        XCTAssertTrue(arrows.waitForExistence(timeout: 10))
        app.buttons["shortcuts.close"].tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        // The fixture keeps redrawing the same prompt. Manual close must last.
        sleep(2)
        XCTAssertFalse(arrows.exists)
        app.buttons["terminal.enter"].tap()
        XCTAssertTrue(app.keyboards.element.exists)
    }

    func testTerminalAttachmentUploadsFileAndInsertsPath() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; file attachment test skipped")
        }
        openHost("localbox")
        let attach = app.buttons["terminal.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["terminal.dpad"].exists)
        attach.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), app.debugDescription)
        defer { if cancel.exists && cancel.isHittable { cancel.tap() } }
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["File upload failed"].exists)
        XCTAssertTrue(attach.isEnabled)

        let capture = "/tmp/psh-attachment-path-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: capture) }
        let terminal = app.textViews["terminal.view"]
        terminal.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        terminal.typeText("printf '%s' ")
        attach.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), app.debugDescription)
        let file = app.cells["pocketshell-attachment-test, txt"]
        if !file.waitForExistence(timeout: 3) {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists && !browse.isSelected { browse.tap() }
            let local = app.cells["DOC.sidebar.item.On My iPhone"]
            if local.exists { local.tap() }
            let folder = app.staticTexts["pocketshell"].firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        file.tap()
        let imported = NSPredicate { _, _ in
            attach.exists && attach.isEnabled && attach.value as? String == "Ready" && !cancel.exists
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: imported, object: nil)], timeout: 15), .completed)
        terminal.tap()
        terminal.typeText(" > '\(capture)'\n")
        let captured = NSPredicate { _, _ in
            FileManager.default.contents(atPath: capture)?.isEmpty == false
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: captured, object: nil)], timeout: 5), .completed)
        let path = try XCTUnwrap(
            FileManager.default.contents(atPath: capture).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(path.hasPrefix("/tmp/psh-"))
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "pocketshell-attachment-test.txt")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "pocketshell-file-attachment\n")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    func testTerminalCameraPhotoUploadsAndInsertsPath() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; camera paste test skipped")
        }
        openHost("localbox")
        let attach = app.buttons["terminal.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        let capture = "/tmp/psh-camera-path-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: capture) }
        let terminal = app.textViews["terminal.view"]
        terminal.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        terminal.typeText("printf '%s' ")
        attach.tap()
        let takePhoto = app.buttons["terminal.camera"]
        XCTAssertTrue(takePhoto.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["terminal.chooseFile"].exists)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [])
        takePhoto.tap()
        let uploaded = NSPredicate { _, _ in
            ((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []).contains {
                $0.hasPrefix("psh-") && $0.hasSuffix(".jpg") && !before.contains($0)
            }
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: uploaded, object: nil)], timeout: 15), .completed)
        terminal.tap()
        terminal.typeText("> '\(capture)'\n")
        let captured = NSPredicate { _, _ in
            FileManager.default.contents(atPath: capture)?.isEmpty == false
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: captured, object: nil)], timeout: 10), .completed)
        let path = try XCTUnwrap(
            FileManager.default.contents(atPath: capture).flatMap { String(data: $0, encoding: .utf8) }
        ).trimmingCharacters(in: .whitespaces)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(path.hasPrefix("/tmp/psh-") && path.hasSuffix(".jpg"), path)
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    func testTopBarButtonsHaveNoAdaptiveGlass() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; top bar test skipped")
        }
        openHost("localbox")
        let tmux = app.buttons["tmux-sessions"]
        let more = app.buttons["terminal.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertTrue(tmux.exists)
        let y = more.frame.midY
        let between = luminance(at: CGPoint(x: (tmux.frame.maxX + more.frame.minX) / 2, y: y))
        let bar = luminance(at: CGPoint(x: tmux.frame.minX - 20, y: y))
        XCTAssertEqual(between, bar, accuracy: 6, "trailing buttons sit on a glass capsule")
    }

    private func luminance(at point: CGPoint) -> Double {
        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage else { return -1 }
        let scale = CGFloat(cg.width) / app.frame.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(
            cg,
            in: CGRect(
                x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale), width: CGFloat(cg.width),
                height: CGFloat(cg.height)))
        return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
    }

    func testTerminalShortcutsReplaceKeyboardAndRememberCategory() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; shortcut keyboard test skipped")
        }
        openHost("localbox")
        let toggle = app.buttons["terminal.shortcutsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let terminal = app.textViews["terminal.view"]
        terminal.tap()
        terminal.typeText(" ")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        let typingHeight = terminal.frame.height

        let enter = app.buttons["terminal.enter"]
        XCTAssertTrue(enter.isHittable)
        XCTAssertFalse(app.buttons["terminal.prefix"].exists)
        let path = "/tmp/psh-enter-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        terminal.typeText("\u{03}printf toolbar-enter > \(path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        enter.tap()
        let entered = NSPredicate { _, _ in
            (try? String(contentsOfFile: path, encoding: .utf8)) == "toolbar-enter"
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: nil)], timeout: 10), .completed)

        toggle.tap()
        let shell = app.buttons["shortcuts.shell"]
        let opened = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        opened.name = "shortcut-keyboard-opened"
        opened.lifetime = .keepAlways
        add(opened)
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(terminal.frame.height, typingHeight - 30)
        XCTAssertGreaterThan(shell.frame.minY, toggle.frame.maxY)
        app.buttons["shortcuts.favorites"].tap()
        let keyQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shortcuts.key.'"))
        XCTAssertTrue(keyQuery.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let keys = keyQuery.allElementsBoundByIndex
        XCTAssertGreaterThan(keys.count, 5)
        let keySize = try XCTUnwrap(keys.first?.frame.size)
        XCTAssertGreaterThanOrEqual(keySize.height, 44)
        for key in keys {
            XCTAssertEqual(key.frame.height, keySize.height, accuracy: 1, key.identifier)
            XCTAssertEqual(key.frame.width, keySize.width, accuracy: 1, key.identifier)
        }
        let uniformGrid = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        uniformGrid.name = "uniform-special-keys"
        uniformGrid.lifetime = .keepAlways
        add(uniformGrid)
        shell.tap()
        XCTAssertEqual(shell.value as? String, "selected")
        app.buttons["shortcuts.key.^C"].tap()
        XCTAssertTrue(shell.exists)

        let herdr = app.buttons["shortcuts.herdr"]
        XCTAssertTrue(herdr.exists)
        if !herdr.isHittable { shell.swipeLeft() }
        XCTAssertTrue(herdr.isHittable)
        herdr.tap()
        XCTAssertEqual(herdr.value as? String, "selected")
        XCTAssertTrue(app.buttons["shortcuts.key.^b,w"].isHittable)
        XCTAssertTrue(app.buttons["shortcuts.key.^b,v"].exists)
        XCTAssertTrue(app.buttons["shortcuts.key.^b,-"].exists)
        let close = app.buttons["shortcuts.close"]
        XCTAssertGreaterThan(herdr.frame.maxY, toggle.frame.maxY)
        XCTAssertLessThanOrEqual(herdr.frame.maxX, close.frame.minX)
        let herdrPanel = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        herdrPanel.name = "terminal-herdr-shortcuts"
        herdrPanel.lifetime = .keepAlways
        add(herdrPanel)
        if !shell.isHittable { herdr.swipeRight() }
        shell.tap()

        app.buttons["shortcuts.close"].tap()
        XCTAssertTrue(shell.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        let restored = NSPredicate { _, _ in
            toggle.isHittable && toggle.frame.maxY <= self.app.keyboards.element.frame.minY + 5
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 5), .completed)
        toggle.tap()
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        XCTAssertEqual(shell.value as? String, "selected")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-shortcuts-in-keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["shortcuts.close"].tap()
    }

    func testTerminalHoldAndDragSendsArrowsAndStopsOnRelease() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; cursor gesture test skipped")
        }
        openHost("localbox")
        let terminal = app.textViews["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.tap()
        let path = "/tmp/psh-cursor-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Record the whole gesture and the quiet period after release, not just its first key.
        terminal.typeText(
            "stty -icanon -echo; /usr/bin/perl -e '$SIG{ALRM}=sub{exit}; alarm 8; "
                + "open my $f, \">\", \"\(path)\"; while (sysread STDIN, my $b, 256) { print $f $b; }'; stty sane\n")
        sleep(2)
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)

        let finished = NSPredicate { _, _ in
            (try? Data(contentsOf: URL(fileURLWithPath: path)).isEmpty) == false
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 10), .completed)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(bytes == Data("\u{1b}[C".utf8) || bytes == Data("\u{1b}OC".utf8))
        let indicator = app.staticTexts["terminal.cursorGesture"]
        XCTAssertFalse(indicator.isHittable)
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
        for (tab, name) in zip(tabs, ["stable", "churn", "gap"]) {
            XCTAssertTrue(tab.label.hasPrefix("\(name),"), "tab omits window name: \(tab.label)")
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
        dismissSessionPicker()
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
        let newWindow = app.buttons["new window in \(session)"]
        if !newWindow.waitForExistence(timeout: 2) {
            app.buttons.matching(
                NSPredicate(format: "identifier == %@ AND label CONTAINS ' windows'", "tmux-session-\(session)")
            ).firstMatch.tap()
        }
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
        let shellMode = app.buttons["Shells & tmux"].firstMatch
        if shellMode.waitForExistence(timeout: 3) { shellMode.tap() }
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
        for _ in 0..<3 where terminal.value as? String != "history" {
            terminal.swipeDown()
        }
        XCTAssertEqual(terminal.value as? String, "history")
        terminal.swipeUp()
        for _ in 0..<4 where terminal.value as? String != "bottom" {
            terminal.swipeUp()
        }
        XCTAssertEqual(terminal.value as? String, "bottom")

        for _ in 0..<3 {
            let beforeHide = terminal.label
            let motionBeforeHide = keyboardMotionFrames()
            keyboardButton.tap()
            waitForKeyboardLayout(terminal, button: keyboardButton)
            XCTAssertGreaterThan(terminal.frame.height, compactHeight + 200)
            XCTAssertEqual(terminal.value as? String, "bottom")
            assertSingleTerminalResize(terminal, from: beforeHide)
            XCTAssertGreaterThan(keyboardMotionFrames(), motionBeforeHide + 3)
            XCTAssertEqual(terminal.frame.maxY, keyboardButton.frame.minY, accuracy: 20)
            let beforeShow = terminal.label
            let motionBeforeShow = keyboardMotionFrames()
            keyboardButton.tap()
            assertTerminalHeightCommitsOnce(terminal, button: keyboardButton)
            XCTAssertEqual(terminal.frame.height, compactHeight, accuracy: 2)
            XCTAssertEqual(terminal.value as? String, "bottom")
            assertSingleTerminalResize(terminal, from: beforeShow)
            XCTAssertGreaterThan(keyboardMotionFrames(), motionBeforeShow + 3)
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-long-scrollback-after-keyboard-toggle"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertSingleTerminalResize(_ terminal: XCUIElement, from previousLabel: String) {
        let previous = Int(previousLabel.split(separator: " ").last ?? "")
        let current = Int(terminal.label.split(separator: " ").last ?? "")
        XCTAssertNotNil(previous)
        XCTAssertNotNil(current)
        if let previous, let current { XCTAssertEqual(current - previous, 1) }
    }

    private func keyboardMotionFrames() -> Int {
        let probe = app.otherElements["keyboard.motion"]
        XCTAssertTrue(probe.exists)
        return Int(probe.label.split(separator: " ").last ?? "") ?? 0
    }

    private func keyboardLayoutCommits() -> (commits: Int, before: Int, after: Int) {
        let label = app.otherElements["keyboard.motion"].label
        let numbers = label.split { !$0.isNumber }.compactMap { Int($0) }
        XCTAssertEqual(numbers.count, 4, "unexpected probe label: \(label)")
        return numbers.count == 4 ? (numbers[0], numbers[1], numbers[2]) : (-1, -1, -1)
    }

    private func assertTerminalHeightCommitsOnce(_ terminal: XCUIElement, button: XCUIElement) {
        var heights: [CGFloat] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            heights.append(terminal.frame.height)
            if abs(terminal.frame.maxY - button.frame.minY) < 20 { break }
        } while Date() < deadline
        XCTAssertLessThan(abs(terminal.frame.maxY - button.frame.minY), 20, "keyboard layout never settled")
        XCTAssertLessThanOrEqual(Set(heights).count, 2, "terminal resized gradually: \(heights)")
    }

    private func waitForKeyboardLayout(_ terminal: XCUIElement, button: XCUIElement) {
        let settled = NSPredicate { _, _ in abs(terminal.frame.maxY - button.frame.minY) < 20 }
        let wait = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 5), .completed)
    }

    func testKeyboardLayoutCommitsOnlyOutsideShowMotion() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed keyboard test skipped")
        }
        openHost("localbox")
        let keyboardButton = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 10))
        let terminal = app.textViews["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.tap()
        terminal.typeText(" ")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        sleep(1)
        for _ in 0..<3 {
            let beforeHide = keyboardLayoutCommits()
            keyboardButton.tap()
            waitForKeyboardLayout(terminal, button: keyboardButton)
            let afterHide = keyboardLayoutCommits()
            XCTAssertEqual(afterHide.commits - beforeHide.commits, 1, "hide: \(afterHide)")
            XCTAssertEqual(afterHide.before, 0, "hide: \(beforeHide) \(afterHide)")
            XCTAssertGreaterThan(afterHide.after, 3, "hide must animate after the layout grew")

            keyboardButton.tap()
            let shown = NSPredicate { _, _ in self.keyboardLayoutCommits().commits > afterHide.commits }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 5),
                .completed)
            let afterShow = keyboardLayoutCommits()
            XCTAssertEqual(afterShow.commits - afterHide.commits, 1, "show: \(afterShow)")
            XCTAssertGreaterThan(afterShow.before, 3, "show must commit the layout only after the motion frames")
            XCTAssertEqual(afterShow.after, 0, "show must not animate after the layout shrank")
        }
    }

    func testKeyboardTracksSoftwareKeyboard() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; keyboard layout test skipped")
        }
        openHost("localbox")
        let keyboardButton = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 10))
        let terminal = app.textViews["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let fullHeight = terminal.frame.height
        terminal.tap()
        terminal.typeText(" ")
        let visibleKeyboard = NSPredicate { _, _ in
            self.app.keyboards.element.exists && self.app.keyboards.element.isHittable
        }
        guard
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleKeyboard, object: nil)], timeout: 5)
                == .completed
        else {
            throw XCTSkip("no software keyboard on this simulator")
        }
        let shown = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shown.name = "terminal-with-software-keyboard"
        shown.lifetime = .keepAlways
        add(shown)
        XCTAssertLessThan(terminal.frame.height, fullHeight - 200)
        let beforeHide = terminal.label
        let motionBeforeHide = keyboardMotionFrames()
        keyboardButton.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.element)
        waitForExpectations(timeout: 5)
        waitForKeyboardLayout(terminal, button: keyboardButton)
        XCTAssertEqual(terminal.frame.height, fullHeight, accuracy: 2)
        assertSingleTerminalResize(terminal, from: beforeHide)
        XCTAssertGreaterThan(keyboardMotionFrames(), motionBeforeHide + 3)
        XCTAssertEqual(terminal.frame.maxY, keyboardButton.frame.minY, accuracy: 20)
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
        openHost("localbox")
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

    func testFindBarIsEmptyWhenReopened() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed find test skipped")
        }
        openHost("localbox")
        XCTAssertTrue(app.buttons["terminal.compose"].waitForExistence(timeout: 10))
        let field = app.descendants(matching: .any).matching(identifier: "find-field").firstMatch
        let close = app.buttons["find-close"]

        func openFind() {
            for _ in 0..<3 where !field.exists {
                app.typeKey("f", modifierFlags: .command)
                _ = field.waitForExistence(timeout: 3)
            }
            XCTAssertTrue(field.waitForExistence(timeout: 5))
        }

        openFind()
        field.tap()
        field.typeText("needle")
        XCTAssertEqual(field.value as? String, "needle")
        close.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        openFind()
        let empty = NSPredicate(format: "value == 'find in scrollback' OR value == ''")
        expectation(for: empty, evaluatedWith: field)
        waitForExpectations(timeout: 5)
    }

    func testTabStripReordersByDragAndHoldShowsActions() throws {
        guard ProcessInfo.processInfo.environment["PS_TEST_PORT"] != nil else {
            throw XCTSkip("PS_TEST_PORT not set; sshd-backed tab strip test skipped")
        }
        openHost("localbox")
        let newTab = app.buttons["new-tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 10))
        newTab.tap()
        dismissSessionPicker()
        let first = app.descendants(matching: .any)["terminal-tab-1"]
        let second = app.descendants(matching: .any)["terminal-tab-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertLessThan(first.frame.minX, second.frame.minX)

        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.4,
            thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 0.2)
        let reordered = NSPredicate { _, _ in first.frame.minX > second.frame.minX }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reordered, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["Close Tab"].exists)

        app.buttons["Back"].tap()
        openHost("localbox")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(first.frame.minX, second.frame.minX)

        let before = first.frame.minX
        first.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Close Tab"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Rename Tab"].exists)
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        }
        XCTAssertTrue(app.buttons["Close Tab"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(first.frame.minX, before, accuracy: 1)
        XCTAssertGreaterThan(first.frame.minX, second.frame.minX)
    }

    func testZZCloudRefreshKeepsRemoteDeletion() {
        XCTAssertTrue(app.staticTexts["bl4ot"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["bl4ot-tailscale"].firstMatch.exists)
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
        let shellMode = app.buttons["Shells & tmux"].firstMatch
        if shellMode.waitForExistence(timeout: 3) { shellMode.tap() }
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

    private func configFixture(hosts: [(id: String, name: String)]) -> String {
        let hostsJSON = hosts.map { host in
            #"{"id":"\#(host.id)","name":"\#(host.name)","hostname":"127.0.0.1","port":22,"username":"test","keyTag":"pocketshell-device-key"}"#
        }.joined(separator: ",")
        let json =
            #"{"version":1,"hosts":[\#(hostsJSON)],"vncHosts":[],"snippets":[],"toolbarKeys":[],"knownHosts":{}}"#
        return Data(json.utf8).base64EncodedString()
    }

}
