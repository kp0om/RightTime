import SwiftUI
import UserNotifications

@main
struct RightTimeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ContextCollector.shared.startLiveAccelerometer()
                Planner.wake(reason: "앱 열림")
            case .background:
                ContextCollector.shared.stopLiveAccelerometer()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Planner.registerCategory()
        Planner.registerBackgroundTask()
        LogStore.shared.add("앱 시작 (v2, 번들 \(Bundle.main.bundleIdentifier ?? "?"))")
        return true
    }

    // 알림을 탭했거나, 버튼(확인했어요/지금은 곤란해요)을 눌렀거나, 지웠을 때
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let deliveredAt = response.notification.date
        let action = response.actionIdentifier
        let respondedAt = Date()
        DispatchQueue.main.async {
            Planner.handleResponse(identifier: identifier, action: action,
                                   deliveredAt: deliveredAt, respondedAt: respondedAt)
            Planner.wake(reason: "알림 응답") {
                completionHandler()
            }
        }
    }

    // 앱이 화면에 떠 있을 때 온 알림도 배너로 보여 준다
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        let date = notification.date
        DispatchQueue.main.async {
            Planner.notificationPresented(identifier: identifier, at: date)
        }
        completionHandler([.banner, .list, .sound])
    }
}
