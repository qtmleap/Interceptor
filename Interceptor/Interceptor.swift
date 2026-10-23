import Mudmouth
import SwiftData
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var tuberose: Tuberose?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { try? self.tuberose?.setToken(response) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(CaptureAuthorization.isGranted ? [.banner, .sound] : [])
    }
}

@main
struct Interceptor: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let tuberose = Tuberose.default
    @State private var automation = AutomationController.live()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tuberose)
                .environment(tuberose.mudmouth)
                .environment(automation)
                .environmentIsFirstLaunch()
                .modelContainer(ModelContainer.default)
                .onAppear { appDelegate.tuberose = tuberose }
                .task { await automation.start() }
        }
    }
}
