import AppKit
import SwiftUI

/// Development aid: `PULSE_SNAPSHOT=/tmp/pulse` renders the panel (main view and
/// each pool's detail) to PNGs once data has loaded, then quits.
@MainActor
enum DebugSnapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["PULSE_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
    }

    static func runIfRequested(_ store: AppStore) {
        guard let directory else { return }
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(6))
            for scheme in [ColorScheme.dark, .light] {
                store.route = .main
                render(store, to: directory.appending(path: "panel-\(scheme == .dark ? "dark" : "light").png"), scheme: scheme)
                for pool in store.pools {
                    store.route = .quota(pool.provider)
                    render(store, to: directory.appending(path: "quota-\(pool.provider)-\(scheme == .dark ? "dark" : "light").png"), scheme: scheme)
                }
            }
            store.route = .main
            let icon = store.statusImage
            if let tiff = icon.tiffRepresentation {
                try? tiff.write(to: directory.appending(path: "status-icon.tiff"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func render(_ store: AppStore, to url: URL, scheme: ColorScheme) {
        let view = PanelView()
            .environment(store)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
