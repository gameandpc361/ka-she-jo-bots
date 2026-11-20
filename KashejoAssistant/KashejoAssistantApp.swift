import SwiftUI
import BackgroundTasks

@main
struct KashejoAssistantApp: App {
    @StateObject private var model = AppModel()
    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "jp.example.KashejoAssistant.queue-refresh", using: nil) { task in
            task.setTaskCompleted(success: true)
            // iOS background refresh is only a wake-up opportunity. WebKit form posting
            // is intentionally not attempted here; the user must reopen the app.
        }
    }
    var body: some Scene {
        WindowGroup { MainView().environmentObject(model) }
    }
}
