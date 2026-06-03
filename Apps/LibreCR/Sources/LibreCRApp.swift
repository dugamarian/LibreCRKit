import SwiftUI
import LibreCRKit

@main
struct LibreCRApp: App {
    init() {
        GlucoseAlarmManager.shared.activate()
        WatchSensorStateSyncCoordinator.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
