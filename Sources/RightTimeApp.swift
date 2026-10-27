import SwiftUI
import UserNotifications

@main
struct RightTimeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// 알림 응답을 받아 로그에 남긴다. 나중에 Response Logger의 출발점이 된다.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        LogStore.shared.add("앱 실행")
        return true
    }

    // 사용자가 알림을 탭했을 때: 전달 시각과의 차이(응답 시간)를 기록
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let seconds = Date().timeIntervalSince(response.notification.date)
        LogStore.shared.add("알림 탭: 전달 후 \(Int(seconds))초")
        completionHandler()
    }

    // 앱이 화면에 떠 있을 때도 배너를 보여준다
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        LogStore.shared.add("알림 전달됨(앱 실행 중)")
        completionHandler([.banner, .sound])
    }
}
