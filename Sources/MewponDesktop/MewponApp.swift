import SwiftUI
import AppKit

/// SwiftUI supplies the system App Intents lifecycle; AppKit still owns all Mewpon windows.
@main struct MewponApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) private var coordinator
    var body: some Scene {
        Settings { EmptyView() }
    }
}
