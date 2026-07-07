import Foundation
import Testing
@testable import Models

@Test func vncHostConfigDefaultsPort5900AndRoundTrips() throws {
    let host = VNCHostConfig(name: "mac mini", hostname: "192.0.2.10", username: "alice")
    #expect(host.port == 5900)
    let data = try JSONEncoder().encode([host])
    let decoded = try JSONDecoder().decode([VNCHostConfig].self, from: data)
    #expect(decoded == [host])
}
