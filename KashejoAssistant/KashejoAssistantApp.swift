import SwiftUI
import BackgroundTasks

@main
struct KashejoAssistantApp: App {
    @StateObject private var model = AppModel()
    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "jp.example.KashejoAssistant.queue-refresh", using: nil) { task in
            task.setTaskCompleted(success: true)
        }
    }
    var body: some Scene { WindowGroup { MainView().environmentObject(model) } }
}
