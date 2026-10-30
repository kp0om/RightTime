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

    /// 앞으로 daysAhead일 동안 날마다 promptsPerDay개가 되도록 모자란 알림을 채운다. 메인 스레드에서 호출한다.
    /// 설정 변경으로 오늘의 남은 알림이 취소된 경우에도 남은 시간에 다시 채운다.
    static func topUp() {
        let store = DataStore.shared
        let settings = store.settings
        guard settings.enabled else { return }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let earliest = now.addingTimeInterval(120)

        var newPrompts: [Prompt] = []
        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let existing = store.prompts.map(\.scheduledAt).filter { calendar.isDate($0, inSameDayAs: day) }
            let missing = settings.promptsPerDay - existing.count
            guard missing > 0 else { continue }
            for time in randomTimes(on: day, count: missing, after: earliest, avoiding: existing, settings: settings) {
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

    /// 범위 안에서 무작위 시각을 최대 count개 고른다. 기존 알림과 새 알림이 서로 minGapMinutes 이상 떨어지게 하며,
    /// 남은 시간이 부족하면 들어갈 수 있는 만큼만 고른다.
    private static func randomTimes(on day: Date, count: Int, after earliest: Date, avoiding existing: [Date],
                                    settings: CollectionSettings) -> [Date] {
        let rangeStart = day.addingTimeInterval(TimeInterval(settings.startHour * 3600))
        let rangeEnd = day.addingTimeInterval(TimeInterval(settings.endHour * 3600))
        let start = max(rangeStart, earliest)
        guard rangeEnd > start, count > 0 else { return [] }

        let gap = TimeInterval(settings.minGapMinutes * 60)
        var taken = existing
        var picked: [Date] = []
        let candidates = stride(from: start.timeIntervalSince1970, to: rangeEnd.timeIntervalSince1970, by: 60)
            .map { Date(timeIntervalSince1970: $0 + Double(Int.random(in: 0..<60))) }
            .filter { $0 < rangeEnd }
            .shuffled()
        for time in candidates where picked.count < count {
            if taken.allSatisfy({ abs($0.timeIntervalSince(time)) >= gap }) {
                picked.append(time)
                taken.append(time)
            }
        }
        return picked.sorted()
    }
}
