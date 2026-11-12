import BackgroundTasks
import UIKit
import UserNotifications

/// 일정마다 알림 시점을 정하고, 응답이 올 때마다 모델을 바로 갱신한다.
///
/// - 일반 일정 (80%): 앱이 깨어날 때마다 지금 context로 확인 확률 p를 예측해 p ≥ θ면 바로 보낸다.
///   마감이 다가올수록 θ를 절반까지 낮추고, 끝까지 안 보내면 마감 시각 알림(안전장치)이 나간다.
/// - 탐색 일정 (20%): AI 판단 없이 기간 안 무작위 시각에 보낸다. AI가 고르지 않은 순간의 응답도
///   배워야 모델이 자기 판단에만 맞춰 치우치지 않는다.
enum Planner {
    static let refreshTaskID: String = {
        // 재서명 도구가 이 값을 바꿀 수 있으므로 Info.plist에 실제로 들어 있는 값을 쓴다
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return ids?.first ?? "com.gipum.righttime.refresh"
    }()
    static let exploreRate = 0.2
    static let labelSeconds: TimeInterval = 60
    static let sensorDelay: TimeInterval = 5 * 60   // 센서 기록이 조회 가능해질 때까지 기다리는 시간
    static let cooldown: TimeInterval = 15 * 60
    static let categoryID = "reminder"
    static let confirmAction = "confirm"
    static let laterAction = "later"

    private static var store: ReminderStore { .shared }
    private static var model: OnlineModel { .shared }
    private static var running = false

    // MARK: - 알림 종류

    static func registerCategory() {
        let confirm = UNNotificationAction(identifier: confirmAction, title: "확인했어요", options: [])
        let later = UNNotificationAction(identifier: laterAction, title: "지금은 곤란해요", options: [])
        let category = UNNotificationCategory(identifier: categoryID, actions: [confirm, later],
                                              intentIdentifiers: [], options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func notificationID(_ reminderId: String, _ kind: DeliveryKind) -> String {
        "\(reminderId)|\(kind.rawValue)"
    }

    static func parse(_ identifier: String) -> (reminderId: String, kind: DeliveryKind)? {
        let parts = identifier.split(separator: "|").map(String.init)
        guard parts.count == 2, let kind = DeliveryKind(rawValue: parts[1]) else { return nil }
        return (parts[0], kind)
    }

    private static func schedule(_ reminder: Reminder, kind: DeliveryKind, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        // 알림 종류(AI·탐색·마감)를 문구로 드러내면 응답이 달라질 수 있어 모두 같은 문구를 쓴다
        content.body = "마감 \(reminder.deadline.formatted(date: .omitted, time: .shortened))까지 할 일이에요."
        content.sound = .default
        content.categoryIdentifier = categoryID
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: notificationID(reminder.id, kind), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                LogStore.shared.add("알림 예약 실패: \(error.localizedDescription)")
            }
        }
    }

    private static func cancel(_ reminderId: String, kinds: [DeliveryKind]) {
        let ids = kinds.map { notificationID(reminderId, $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - 일정 추가·삭제

    static func add(title: String, windowStart: Date, deadline: Date) {
        let now = Date()
        var reminder = Reminder(title: title, windowStart: max(windowStart, now), deadline: deadline)
        if Double.random(in: 0..<1) < exploreRate {
            reminder.explore = true
            let earliest = max(reminder.windowStart, now.addingTimeInterval(60)).timeIntervalSince1970
            let latest = deadline.addingTimeInterval(-60).timeIntervalSince1970
            let at = earliest < latest ? Date(timeIntervalSince1970: .random(in: earliest...latest)) : deadline
            reminder.exploreAt = at
            schedule(reminder, kind: .explore, at: at)
            LogStore.shared.add("일정 추가(탐색): \(title), \(at.formatted(date: .omitted, time: .shortened))에 전달")
        } else {
            schedule(reminder, kind: .failsafe, at: deadline)
            LogStore.shared.add("일정 추가: \(title), AI가 시점 판단, 마감 안전장치 예약")
        }
        store.reminders.append(reminder)
        store.reminders.sort { $0.deadline < $1.deadline }
        store.save()
        wake(reason: "일정 추가")
    }

    static func delete(_ reminderId: String) {
        let all: [DeliveryKind] = [.policy, .explore, .failsafe]
        cancel(reminderId, kinds: all)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: all.map { notificationID(reminderId, $0) })
        store.reminders.removeAll { $0.id == reminderId }
        store.save()
    }

    static func markDone(_ reminderId: String) {
        guard let i = store.reminderIndex(reminderId) else { return }
        cancel(reminderId, kinds: [.policy, .explore, .failsafe])
        store.reminders[i].status = .done
        store.save()
    }

    // MARK: - 알림 전달·응답 (AppDelegate에서 부름)

    /// 이 전달에 해당하는 샘플을 찾거나 만든다. 일정 상태도 '전달됨'으로 바꾼다.
    @discardableResult
    private static func ensureSample(reminderId: String, kind: DeliveryKind, deliveredAt: Date) -> Int? {
        guard let ri = store.reminderIndex(reminderId) else { return nil }
        if store.reminders[ri].status == .waiting {
            store.reminders[ri].status = .delivered
        }
        if let si = store.openSampleIndex(reminderId: reminderId, kind: kind) {
            store.samples[si].deliveredAt = deliveredAt
            return si
        }
        store.samples.append(Sample(reminderId: reminderId, title: store.reminders[ri].title,
                                    kind: kind, deliveredAt: deliveredAt))
        return store.samples.count - 1
    }

    static func notificationPresented(identifier: String, at date: Date) {
        guard let parsed = parse(identifier) else { return }
        ensureSample(reminderId: parsed.reminderId, kind: parsed.kind, deliveredAt: date)
        store.save()
    }

    static func handleResponse(identifier: String, action: String, deliveredAt: Date, respondedAt: Date) {
        guard let parsed = parse(identifier),
              let si = ensureSample(reminderId: parsed.reminderId, kind: parsed.kind, deliveredAt: deliveredAt) else { return }
        let rid = parsed.reminderId
        let seconds = respondedAt.timeIntervalSince(store.samples[si].deliveredAt)
        let positive = action == confirmAction || action == UNNotificationDefaultActionIdentifier
        let response: String
        switch action {
        case confirmAction: response = "확인"
        case UNNotificationDefaultActionIdentifier: response = "탭"
        case laterAction: response = "곤란"
        default: response = "지움"
        }
        store.samples[si].respondedAt = respondedAt
        store.samples[si].response = response
        if store.samples[si].label == nil {
            store.samples[si].label = positive && seconds <= labelSeconds ? 1 : 0
        }
        LogStore.shared.add("응답 \(response): \(store.samples[si].title), 전달 후 \(Int(seconds))초")

        if let ri = store.reminderIndex(rid) {
            if positive {
                store.reminders[ri].status = .done
                cancel(rid, kinds: [.failsafe, .explore])
            } else {
                requeue(ri)
            }
        }
        store.save()
    }

    /// "지금은 곤란해요"나 지움: 15분 뒤부터 다시 AI가 판단하고, 마감 안전장치를 다시 건다.
    private static func requeue(_ ri: Int) {
        let reminder = store.reminders[ri]
        guard reminder.deadline.timeIntervalSinceNow > 2 * 60 else {
            store.reminders[ri].status = .done
            return
        }
        store.reminders[ri].status = .waiting
        store.reminders[ri].explore = false
        store.reminders[ri].cooldownUntil = Date().addingTimeInterval(cooldown)
        schedule(store.reminders[ri], kind: .failsafe, at: reminder.deadline)
    }

    // MARK: - 깨어날 때마다

    /// 앱 열림, 화면 타이머, 알림 응답, 백그라운드 갱신 때 부른다.
    static func wake(reason: String, completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { wake(reason: reason, completion: completion) }
            return
        }
        guard !running else {
            completion?()
            return
        }
        running = true
        ContextCollector.shared.startAccelerometerRecording()

        syncDeliveries {
            finalizeLabels()
            collectMissingFeatures {
                learn()
                evaluate(reason: reason) {
                    store.save()
                    scheduleBackgroundRefresh()
                    running = false
                    completion?()
                }
            }
        }
    }

    /// 앱이 잠든 동안 나간 탐색·마감 알림을 찾아 샘플로 만든다.
    private static func syncDeliveries(then next: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.getDeliveredNotifications { delivered in
                let pendingIDs = Set(pending.map(\.identifier))
                let deliveredDates = Dictionary(delivered.map { ($0.request.identifier, $0.date) },
                                                uniquingKeysWith: { first, _ in first })
                DispatchQueue.main.async {
                    let now = Date()
                    for reminder in store.reminders where reminder.status == .waiting {
                        let kind: DeliveryKind = reminder.explore ? .explore : .failsafe
                        let at = reminder.explore ? (reminder.exploreAt ?? reminder.deadline) : reminder.deadline
                        let id = notificationID(reminder.id, kind)
                        guard at <= now, !pendingIDs.contains(id) else { continue }
                        ensureSample(reminderId: reminder.id, kind: kind, deliveredAt: deliveredDates[id] ?? at)
                        LogStore.shared.add("\(kind.korean) 알림 전달 확인: \(reminder.title)")
                    }
                    next()
                }
            }
        }
    }

    /// 전달 후 60초가 지나도 확인이 없으면 라벨 0으로 정한다 (나중에 탭해도 라벨은 그대로).
    private static func finalizeLabels() {
        let now = Date()
        for i in store.samples.indices where store.samples[i].label == nil
            && now.timeIntervalSince(store.samples[i].deliveredAt) > labelSeconds {
            store.samples[i].label = 0
        }
    }

    /// 탐색·마감 알림은 앱이 잠든 사이 나가므로, 전달 시점 센서 기록을 나중에 조회해 특징을 만든다.
    private static func collectMissingFeatures(then next: @escaping () -> Void) {
        let now = Date()
        let targets = store.samples.filter {
            let age = now.timeIntervalSince($0.deliveredAt)
            return $0.features == nil && age > sensorDelay && age < 3 * 24 * 60 * 60
        }
        guard !targets.isEmpty, ContextCollector.isAuthorized else {
            next()
            return
        }
        let group = DispatchGroup()
        for sample in targets {
            group.enter()
            ContextCollector.shared.collect(before: sample.deliveredAt) { snapshot in
                if let i = store.samples.firstIndex(where: { $0.id == sample.id }) {
                    let x = Features.vector(at: sample.deliveredAt, snapshot: snapshot)
                    store.samples[i].features = x
                    store.samples[i].p = store.samples[i].p ?? model.predict(x)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            LogStore.shared.add("전달 시점 센서 특징 \(targets.count)건 채움")
            next()
        }
    }

    /// 라벨과 특징이 모두 있는 샘플로 모델을 한 걸음씩 갱신한다.
    private static func learn() {
        for i in store.samples.indices where !store.samples[i].learned {
            guard let label = store.samples[i].label, let x = store.samples[i].features else { continue }
            let (before, after) = model.update(x, label: label)
            store.samples[i].learned = true
            store.samples[i].pBeforeUpdate = before
            store.samples[i].pAfterUpdate = after
            LogStore.shared.add(String(format: "학습: %@ 라벨 %d, 이 상황의 p %.2f → %.2f", store.samples[i].title, label, before, after))
        }
    }

    /// 기다리는 일정 중 마감이 가장 가까운 것 하나를 지금 보낼지 정한다.
    private static func evaluate(reason: String, then next: @escaping () -> Void) {
        let now = Date()
        let waiting = store.reminders.filter {
            $0.status == .waiting && !$0.explore && $0.windowStart <= now && now < $0.deadline
                && ($0.cooldownUntil ?? .distantPast) <= now
        }
        guard let target = waiting.min(by: { $0.deadline < $1.deadline }) else {
            next()
            return
        }
        guard ContextCollector.isAuthorized else {
            LogStore.shared.add("모션 권한이 없어 AI 판단을 건너뜀 (마감 안전장치는 유지)")
            next()
            return
        }
        ContextCollector.shared.collect(before: now) { snapshot in
            let x = Features.vector(at: now, snapshot: snapshot, accelSeries: ContextCollector.shared.liveSeries())
            let p = model.predict(x)
            let total = max(target.deadline.timeIntervalSince(target.windowStart), 1)
            let remaining = min(max(target.deadline.timeIntervalSince(now) / total, 0), 1)
            let theta = model.theta * (0.5 + 0.5 * remaining)
            let deliver = p >= theta
            store.lastP = p
            store.lastEvaluated = now
            store.decisions.append(DecisionRecord(time: now, title: target.title, p: p, theta: theta,
                                                  delivered: deliver, note: reason))

            if deliver, let ri = store.reminderIndex(target.id), store.reminders[ri].status == .waiting {
                cancel(target.id, kinds: [.failsafe])
                schedule(store.reminders[ri], kind: .policy, at: now.addingTimeInterval(1))
                store.reminders[ri].status = .delivered
                store.samples.append(Sample(reminderId: target.id, title: target.title, kind: .policy,
                                            deliveredAt: now, p: p, features: x))
                LogStore.shared.add(String(format: "AI 전달: %@ (p %.2f ≥ θ %.2f)", target.title, p, theta))
            }
            next()
        }
    }

    // MARK: - 백그라운드 갱신

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            wake(reason: "백그라운드 갱신") {
                task.setTaskCompleted(success: true)
            }
        }
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            LogStore.shared.add("백그라운드 갱신 예약 실패: \(error.localizedDescription)")
        }
    }
}
