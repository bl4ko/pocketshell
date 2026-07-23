import Foundation
import Testing

@testable import KeyKit

@Test func synchronizableStoreRequiresSignedApp() {
    #expect(throws: SynchronizableStore.StoreError.self) {
        try SynchronizableStore.set(Data("pocketshell".utf8), account: "unsigned-test")
    }
}
