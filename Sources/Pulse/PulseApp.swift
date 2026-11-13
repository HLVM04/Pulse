import SwiftUI

@main
struct PulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView().environment(store)
        } label: {
            Image(nsImage: store.statusImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }
    }
}
