import SwiftUI
import UserNotifications

struct ContentView: View {
    @ObservedObject private var log = LogStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section("점검") {
                    Button("알림 권한 요청", action: requestPermission)
                    Button("10초 뒤 시험 알림 예약", action: scheduleTestNotification)
                    Button("로그 지우기", role: .destructive, action: log.clear)
                }
                Section("로그") {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("RightTime 빌드 점검")
        }
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                LogStore.shared.add("권한 요청 오류: \(error.localizedDescription)")
            } else {
                LogStore.shared.add("알림 권한: \(granted ? "허용" : "거부")")
            }
        }
    }

    private func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "RightTime 시험 알림"
        content.body = "탭하면 응답 시간이 로그에 기록됩니다."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                LogStore.shared.add("예약 실패: \(error.localizedDescription)")
            } else {
                LogStore.shared.add("10초 뒤 알림 예약됨")
            }
        }
    }
}
