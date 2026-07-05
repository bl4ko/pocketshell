import SwiftUI

@main
struct PocketshellApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            HostsListView()
                .environmentObject(store)
        }
    }
}
