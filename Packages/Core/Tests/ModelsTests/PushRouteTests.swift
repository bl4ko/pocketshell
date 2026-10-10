import Foundation
import Models
import Testing

private let mini = HostConfig(name: "Mini", hostname: "mini", port: 22, username: "u", keyTag: "k")
private let other = HostConfig(name: "other", hostname: "o", port: 22, username: "u", keyTag: "k")

@Test func routePrefersHostIDOverName() {
    let info: [AnyHashable: Any] = ["hostID": other.id.uuidString, "hostName": "mini"]
    #expect(PushRoute.resolve(info, hosts: [mini, other]).host == other)
}

@Test func routeFallsBackToCaseInsensitiveNameWhenIDUnknown() {
    let info: [AnyHashable: Any] = ["hostID": UUID().uuidString, "hostName": "MINI"]
    #expect(PushRoute.resolve(info, hosts: [mini, other]).host == mini)
}

@Test func routeWithoutMatchHasNoHost() {
    let info: [AnyHashable: Any] = ["hostID": UUID().uuidString, "hostName": "ghost"]
    #expect(PushRoute.resolve(info, hosts: [mini]).host == nil)
    #expect(PushRoute.resolve([:], hosts: [mini]).host == nil)
}

@Test func routeParsesTmuxWindowFields() {
    let info: [AnyHashable: Any] = [
        "hostName": "mini", "backend": "tmux", "session": "agents", "windowIndex": 3, "windowID": "@7",
    ]
    let route = PushRoute.resolve(info, hosts: [mini])
    #expect(route.backend == "tmux")
    #expect(route.session == "agents")
    #expect(route.windowIndex == 3)
    #expect(route.windowID == "@7")
    #expect(route.visibleWindowKey == "\(mini.id):agents:3")
}

@Test func routeAcceptsStringWindowIndex() {
    let route = PushRoute.resolve(["hostName": "mini", "session": "s", "windowIndex": "2"], hosts: [mini])
    #expect(route.windowIndex == 2)
}

@Test func routeVisibleKeyForHerdrUsesWorkspace() {
    let info: [AnyHashable: Any] = [
        "hostID": mini.id.uuidString, "backend": "herdr", "session": "s", "workspaceID": "w1",
    ]
    #expect(PushRoute.resolve(info, hosts: [mini]).visibleWindowKey == "\(mini.id):herdr:s:w1")
}

@Test func routeVisibleKeyNeedsHostAndWindow() {
    #expect(PushRoute.resolve(["session": "s", "windowIndex": 1], hosts: [mini]).visibleWindowKey == nil)
    #expect(PushRoute.resolve(["hostName": "mini", "session": "s"], hosts: [mini]).visibleWindowKey == nil)
}

@Test func hookPushCacheParsesDetectionOutput() {
    #expect(HookPushCache.parse("pocketshell-push-yes\n") == true)
    #expect(HookPushCache.parse("pocketshell-push-no\n") == false)
    #expect(HookPushCache.parse("") == nil)
}

@Test func hookPushCacheRefreshesOnlyAfterTTL() {
    var cache = HookPushCache(ttl: 600)
    let id = UUID()
    let start = Date(timeIntervalSince1970: 1000)
    #expect(cache.needsRefresh(id, now: start))
    #expect(!cache.isInstalled(id))
    cache.record(true, for: id, at: start)
    #expect(cache.isInstalled(id))
    #expect(!cache.needsRefresh(id, now: start.addingTimeInterval(599)))
    #expect(cache.needsRefresh(id, now: start.addingTimeInterval(600)))
}
