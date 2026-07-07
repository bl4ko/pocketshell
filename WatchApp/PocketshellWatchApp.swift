import SwiftUI

@main
struct PocketshellWatchApp: App {
    @StateObject private var client = WatchClient()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environmentObject(client)
        }
    }
}
