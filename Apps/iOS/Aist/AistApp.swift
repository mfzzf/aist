import AistCore
import SwiftUI
import UIKit

@main
struct AistApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var store: TodoStore
    @StateObject private var inbox: Inbox
    @StateObject private var cloud: CloudSync
    @Environment(\.scenePhase) private var phase

    init() {
        let store = TodoStore()
        _store = StateObject(wrappedValue: store)
        _inbox = StateObject(wrappedValue: Inbox(store: store))
        _cloud = StateObject(wrappedValue: CloudSync(store: store))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(inbox)
                .environmentObject(cloud)
                .tint(AistBrand.blue)
                .onAppear {
                    appDelegate.onRemoteChange = { [cloud] in await cloud.syncNow() }
                    if cloud.isEnabled { UIApplication.shared.registerForRemoteNotifications() }
                }
        }
        .onChange(of: phase) { phase in
            guard phase == .active else { return }
            // Anything typed while offline gets another try; pick up edits made on the Mac.
            Task { await inbox.process() }
            cloud.sync()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    var onRemoteChange: (@MainActor () async -> Void)?

    /// CloudKit's silent push: the other device changed something.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let onRemoteChange else { return .noData }
        await onRemoteChange()
        return .newData
    }
}
