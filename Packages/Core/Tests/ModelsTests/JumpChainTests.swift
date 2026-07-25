import Foundation
import Models
import Testing

private func host(_ name: String, proxyJump: UUID? = nil) -> HostConfig {
    HostConfig(name: name, hostname: "\(name).test", username: "apollo", keyTag: "device", proxyJump: proxyJump)
}

@Test func jumpChainIsEmptyWithoutProxy() {
    let target = host("target")
    #expect(HostConfig.jumpChain(to: target, in: [target]).isEmpty)
}

@Test func jumpChainListsBastionsOutermostFirst() {
    let outer = host("outer")
    let inner = host("inner", proxyJump: outer.id)
    let target = host("target", proxyJump: inner.id)
    let chain = HostConfig.jumpChain(to: target, in: [outer, inner, target])
    #expect(chain.map(\.name) == ["outer", "inner"])
}

@Test func jumpChainStopsOnCycle() {
    var first = host("first")
    var second = host("second")
    first.proxyJump = second.id
    second.proxyJump = first.id
    let chain = HostConfig.jumpChain(to: first, in: [first, second])
    #expect(chain.map(\.name) == ["second"])
}

@Test func jumpChainStopsWhenBastionMissing() {
    let target = host("target", proxyJump: UUID())
    #expect(HostConfig.jumpChain(to: target, in: [target]).isEmpty)
}

@Test func hostWithoutProxyJumpDecodesFromOlderConfig() throws {
    let json = """
        {"id":"\(UUID().uuidString)","name":"mini","hostname":"a.test","port":22,"username":"apollo","keyTag":"device"}
        """
    let decoded = try JSONDecoder().decode(HostConfig.self, from: Data(json.utf8))
    #expect(decoded.proxyJump == nil)
}
