import Foundation
import UserNotifications

/// 수집 단계: 설정한 시간 범위 안의 무작위 시각에 시험 reminder를 미리 예약한다.
/// 모델이 고른 시점에만 보내면 데이터가 편향되므로 무작위로 보낸다 (Proposal 3.1).
enum Scheduler {
    static let categoryID = "RIGHTTIME_PROMPT"
    static let daysAhead = 3

    static let texts = [
        "물 한 잔 마시기",
        "5분 스트레칭 하기",
        "오늘 일정 한 번 확인하기",
        "과제 마감일 확인하기",
        "답장 못 한 메시지 확인하기",
        "자세 바르게 고쳐 앉기",
        "내일 준비물 챙기기",
        "눈 쉬어 주기 (20초 동안 먼 곳 보기)",
        "책상 정리하기",
        "복습할 강의 하나 정하기",
        "가족에게 안부 연락하기",
        "잠깐 산책하기",
    ]

    /// 알림을 지운 경우(dismiss)도 앱에 전달되도록 customDismissAction 카테고리를 등록한다.
    static func registerCategory() {
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// 앞으로 daysAhead일 중 아직 계획하지 않은 날의 알림을 만든다. 메인 스레드에서 호출한다.
    static func topUp() {
        let store = DataStore.shared
        let settings = store.settings
        guard settings.enabled else { return }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let plannedDays = Set(store.prompts.map { calendar.startOfDay(for: $0.scheduledAt) })

        var newPrompts: [Prompt] = []
        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  !plannedDays.contains(day) else { continue }
            for time in randomTimes(on: day, settings: settings) where time > now.addingTimeInterval(120) {
                newPrompts.append(Prompt(id: UUID().uuidString, text: texts.randomElement() ?? "할 일 확인하기", scheduledAt: time))
            }
        }
        guard !newPrompts.isEmpty else { return }

        store.addPrompts(newPrompts)
        newPrompts.forEach(schedule)
        LogStore.shared.add("시험 알림 \(newPrompts.count)개 예약")
    }

    /// 앱 재서명·재설치 등으로 빠진 예약이 있으면 다시 등록한다.
    static func resyncPending() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let scheduledIDs = Set(requests.map(\.identifier))
            DispatchQueue.main.async {
                let soon = Date().addingTimeInterval(60)
                let missing = DataStore.shared.prompts.filter {
                    $0.outcome == .pending && $0.scheduledAt > soon && !scheduledIDs.contains($0.id)
                }
                missing.forEach(schedule)
                if !missing.isEmpty {
                    LogStore.shared.add("빠진 예약 \(missing.count)개 다시 등록")
                }
            }
        }
    }

    /// 아직 오지 않은 알림을 모두 취소한다 (수집 중지, 설정 변경 시).
    static func cancelFuture() {
        let now = Date()
        let ids = DataStore.shared.prompts
            .filter { $0.outcome == .pending && $0.scheduledAt > now }
            .map(\.id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        DataStore.shared.removePrompts(ids: Set(ids))
        LogStore.shared.add("예정된 알림 \(ids.count)개 취소")
    }

    private static func schedule(_ prompt: Prompt) {
        let content = UNMutableNotificationContent()
        content.title = prompt.text
        content.body = "확인했다면 이 알림을 눌러 주세요."
        content.sound = .default
        content.categoryIdentifier = categoryID

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: prompt.scheduledAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: prompt.id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                LogStore.shared.add("예약 실패: \(error.localizedDescription)")
            }
        }
    }

    /// 하루 promptsPerDay개의 시각을 범위 안에서 무작위로 고른다. 서로 minGapMinutes 이상 떨어지게 한다.
    private static func randomTimes(on day: Date, settings: CollectionSettings) -> [Date] {
        let startMinute = settings.startHour * 60
        let endMinute = settings.endHour * 60
        let count = settings.promptsPerDay
        guard endMinute > startMinute, count > 0 else { return [] }

        var minutes: [Int] = []
        for _ in 0..<500 {
            let picks = (0..<count).map { _ in Int.random(in: startMinute..<endMinute) }.sorted()
            if zip(picks, picks.dropFirst()).allSatisfy({ $1 - $0 >= settings.minGapMinutes }) {
                minutes = picks
                break
            }
        }
        if minutes.isEmpty {
            // 간격 조건을 못 맞추면 범위를 균등하게 나눠 각 칸에서 하나씩 고른다
            let step = max((endMinute - startMinute) / count, 1)
            minutes = (0..<count).map { startMinute + $0 * step + Int.random(in: 0..<step) }
        }
        return minutes.map { day.addingTimeInterval(TimeInterval($0 * 60 + Int.random(in: 0..<60))) }
    }
}
