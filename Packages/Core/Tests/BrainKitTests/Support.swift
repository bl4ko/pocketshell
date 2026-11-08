import Foundation
import Testing

func fixture(_ name: String) throws -> String {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    let url = try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
