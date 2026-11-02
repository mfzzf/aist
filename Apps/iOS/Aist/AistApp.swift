import AistCore
import SwiftUI

@main
struct AistApp: App {
    @StateObject private var store: TodoStore
    @StateObject private var inbox: Inbox
    @Environment(\.scenePhase) private var phase

    init() {
        let store = TodoStore()
        _store = StateObject(wrappedValue: store)
        _inbox = StateObject(wrappedValue: Inbox(store: store))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(inbox)
                .tint(AistBrand.blue)
        }
        .onChange(of: phase) { phase in
            // Anything typed while offline gets another try when the app comes back.
            if phase == .active { Task { await inbox.process() } }
        }
    }
}
