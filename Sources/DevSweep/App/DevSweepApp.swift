import AppKit
import SwiftUI

@main
struct DevSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        Window("Zelvo", id: "general") {
            GeneralDashboard().environmentObject(model)
        }
        .defaultSize(width: 1000, height: 740)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setup()
        Task { @MainActor in
            AppModel.shared.start()
            Updater.shared.start()
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    static let brandIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 14)); path.line(to: NSPoint(x: 14, y: 14))
            path.line(to: NSPoint(x: 4, y: 4)); path.line(to: NSPoint(x: 14, y: 4))
            path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        let count = model.recommendations.filter { $0.risk != .dataLoss }.count
        let urgent = model.recommendations.contains(where: \.urgent) || model.system.pressure == .critical
        HStack(spacing: 3) {
            if urgent { Image(systemName: "exclamationmark.triangle.fill") }
            else { Image(nsImage: Self.brandIcon).accessibilityLabel("Zelvo") }
            if count > 0 {
                Text("\(count)")
            }
        }
    }
}
