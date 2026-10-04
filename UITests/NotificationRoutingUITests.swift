import XCTest

@MainActor
final class NotificationRoutingUITests: XCTestCase {
    func testHerdrNotificationOpensHerdrOnlyWithWorkspacePreset() {
        let app = launchNotification(backend: "herdr", session: "work", workspaceID: "workspace-7")
        let switcher = app.descendants(matching: .any)["host-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        let target = NSPredicate(format: "value == %@", "herdr:work:workspace-7:consumed:1")
        expectation(for: target, evaluatedWith: switcher)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["tmux-sessions"].exists)
        XCTAssertFalse(app.buttons["new-tab"].exists)
        XCTAssertFalse(app.buttons["Shells & tmux"].exists)
    }

    func testLegacyTmuxNotificationKeepsShellsView() {
        let app = launchNotification(backend: nil, session: "work", windowIndex: 7)
        let switcher = app.descendants(matching: .any)["host-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        let target = NSPredicate(format: "value == %@", "tmux:work:7:consumed")
        expectation(for: target, evaluatedWith: switcher)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["tmux-sessions"].exists)
        XCTAssertTrue(app.buttons["new-tab"].exists)
    }

    private func launchNotification(
        backend: String?, session: String, workspaceID: String? = nil, windowIndex: Int? = nil
    ) -> XCUIApplication {
        continueAfterFailure = false
        let hostID = "00000000-0000-0000-0000-000000000007"
        let config =
            #"{"version":1,"hosts":[{"id":"\#(hostID)","name":"notification-host","hostname":"127.0.0.1","port":1,"username":"test","keyTag":"pocketshell-device-key"}],"vncHosts":[],"snippets":[],"toolbarKeys":[],"knownHosts":{}}"#
        var target: [String: Any] = ["hostID": hostID, "session": session]
        target["backend"] = backend
        target["workspaceID"] = workspaceID
        target["windowIndex"] = windowIndex
        let app = XCUIApplication()
        app.launchEnvironment["PS_UI_TEST"] = "1"
        app.launchEnvironment["PS_UI_TEST_LOCAL_CONFIG"] = Data(config.utf8).base64EncodedString()
        app.launchEnvironment["PS_UI_TEST_CLOUD_CONFIG"] = Data(config.utf8).base64EncodedString()
        app.launchEnvironment["PS_UI_TEST_NOTIFICATION_TARGET"] = String(
            data: try! JSONSerialization.data(withJSONObject: target), encoding: .utf8)
        app.launch()
        return app
    }
}
