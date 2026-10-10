import Foundation
import Models
import Testing
import UserNotifications

@testable import pocketshell

@MainActor
struct PushRoutingTests {
    let host = HostConfig(name: "Mini", hostname: "mini", username: "u", keyTag: "k", tmuxSession: "main")

    @Test func openRoutesResolvedHostWithWindowID() {
        let router = NotificationRouter()
        let route = PushRoute.resolve(
            ["hostName": "mini", "backend": "tmux", "session": "agents", "windowIndex": 2, "windowID": "@5"],
            hosts: [host]
        )
        router.open(route)
        #expect(router.pending?.hostID == host.id)
        #expect(router.pending?.session == "agents")
        #expect(router.pending?.windowIndex == 2)
        #expect(router.pending?.windowID == "@5")
    }

    @Test func openWithUnknownHostRequestsHostsList() {
        let router = NotificationRouter()
        router.open(PushRoute.resolve(["hostName": "ghost"], hosts: [host]))
        #expect(router.pending == nil)
        #expect(router.hostsListRequest == 1)
    }

    @Test func remotePushForVisibleWindowIsSuppressed() {
        let info: [AnyHashable: Any] = ["hostName": "mini", "backend": "tmux", "session": "agents", "windowIndex": 2]
        let key = SessionMonitor.windowKey(hostID: host.id, session: "agents", windowIndex: 2)
        #expect(NotificationRouter.presentationOptions(info, hosts: [host], visibleKey: key) == [])
        #expect(NotificationRouter.presentationOptions(info, hosts: [host], visibleKey: "other") != [])
        #expect(NotificationRouter.presentationOptions(info, hosts: [host], visibleKey: nil) != [])
    }

    @Test func hookPushHostSkipsLocalAgentNotifications() async {
        let installed = Script()
        let connection = FakeConnection { command in
            command.contains("pocketshell/push/config") ? "pocketshell-push-yes\n" : try installed.reply(command)
        }
        let store = AppStore()
        store.savedTabs = [:]
        store.hosts = [host]
        let monitor = SessionMonitor(store: store) { _ in connection }
        #expect(!monitor.hasHookPush(hostID: host.id))
        #expect(monitor.shouldPostLocal(userInfo: ["hostID": host.id.uuidString]))
        await monitor.pollOnce()
        #expect(monitor.hasHookPush(hostID: host.id))
        #expect(!monitor.shouldPostLocal(userInfo: ["hostID": host.id.uuidString]))
        #expect(monitor.shouldPostLocal(userInfo: ["hostID": UUID().uuidString]))
        await monitor.pollOnce()
        await monitor.pollOnce()
        #expect(connection.commands.filter { $0.contains("pocketshell/push/config") }.count == 1)
    }

    @Test func hostWithoutHookPushIsNotSuppressed() async {
        let script = Script()
        let connection = FakeConnection { command in
            command.contains("pocketshell/push/config") ? "pocketshell-push-no\n" : try script.reply(command)
        }
        let store = AppStore()
        store.savedTabs = [:]
        store.hosts = [host]
        let monitor = SessionMonitor(store: store) { _ in connection }
        await monitor.pollOnce()
        #expect(!monitor.hasHookPush(hostID: host.id))
        #expect(monitor.shouldPostLocal(userInfo: ["hostID": host.id.uuidString]))
    }
}
