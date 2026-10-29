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
            if phase == .active {
                Pipeline.refresh(reason: "앱 열림")
            }
        }
    }
}

// 알림 응답을 받아 자동 라벨(응답 시간)을 기록한다 (Response Logger).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Scheduler.registerCategory()
        Pipeline.registerBackgroundTask()
        LogStore.shared.add("앱 프로세스 시작")
        return true
    }

    // 사용자가 알림을 탭하거나 지웠을 때: 전달 시각과의 차이(응답 시간)를 기록
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let deliveredAt = response.notification.date
        let respondedAt = Date()
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        let seconds = Int(respondedAt.timeIntervalSince(deliveredAt))

        LogStore.shared.add("\(dismissed ? "알림 지움" : "알림 탭"): 전달 후 \(seconds)초")
        DataStore.shared.recordResponse(
            id: id,
            outcome: dismissed ? .dismissed : .tapped,
            deliveredAt: deliveredAt,
            respondedAt: respondedAt
        )
        completionHandler()
        Pipeline.refresh(reason: dismissed ? "알림 지움" : "알림 탭")
    }

    // 앱이 화면에 떠 있을 때 온 알림: 전달 시각을 남기고 배너를 보여준다
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let id = notification.request.identifier
        let deliveredAt = notification.date
        DataStore.shared.updatePrompt(id: id) { prompt in
            if prompt.deliveredAt == nil { prompt.deliveredAt = deliveredAt }
        }
        LogStore.shared.add("알림 전달됨(앱 사용 중)")
        completionHandler([.banner, .sound])
    }
}
