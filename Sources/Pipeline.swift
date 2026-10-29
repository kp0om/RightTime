import BackgroundTasks
import UIKit
import Foundation
import UserNotifications

/// 앱이 깨어날 때마다(앱 열림, 알림 응답, 백그라운드 갱신) 하는 일을 한곳에 모은다.
/// iOS는 원하는 시각에 앱을 깨워 주지 않으므로, 깨어날 때마다 밀린 일을 처리하고 다음 예약을 채운다.
enum Pipeline {
    /// AltStore가 재서명하면서 번들 ID와 함께 이 값도 바꾸므로(예: com.gipum.righttime.XXXX.refresh)
    /// 코드에 고정하지 않고 Info.plist에 실제로 들어 있는 값을 쓴다.
    static let refreshTaskID: String = {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return ids?.first ?? "com.gipum.righttime.refresh"
    }()
    static let noResponseAfter: TimeInterval = 2 * 60 * 60
    static let sensorDelay: TimeInterval = 5 * 60   // 센서 기록이 조회 가능해질 때까지 기다리는 시간

    static func refresh(reason: String, completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { refresh(reason: reason, completion: completion) }
            return
        }
        DataStore.shared.addWake(reason)
        LogStore.shared.add("깨어남: \(reason)")
        ContextCollector.shared.startAccelerometerRecording()

        resolveOutcomes {
            collectMissingContexts {
                Scheduler.topUp()
                Scheduler.resyncPending()
                scheduleBackgroundRefresh()
                completion?()
            }
        }
    }

    // MARK: - 백그라운드 갱신

    static func registerBackgroundTask() {
        logBackgroundDiagnostics()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            refresh(reason: "백그라운드 갱신") {
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// 백그라운드 갱신 예약이 거부될 때 원인을 찾기 위한 정보 (재서명 후 실제 번들 값)
    private static func logBackgroundDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        let modes = (info["UIBackgroundModes"] as? [String])?.joined(separator: ",") ?? "없음"
        let ids = (info["BGTaskSchedulerPermittedIdentifiers"] as? [String])?.joined(separator: ",") ?? "없음"
        let status: String
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: status = "켜짐"
        case .denied: status = "꺼짐"
        case .restricted: status = "제한됨"
        @unknown default: status = "알 수 없음"
        }
        LogStore.shared.add("번들 \(bundleID) / 모드 \(modes) / 허용 ID \(ids) / 백그라운드 새로 고침 \(status)")
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            LogStore.shared.add("백그라운드 갱신 예약 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 단계

    /// 전달된 알림의 전달 시각을 채우고, 오래 응답이 없는 알림은 무응답으로 확정한다.
    private static func resolveOutcomes(then next: @escaping () -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let deliveredDates = Dictionary(
                notifications.map { ($0.request.identifier, $0.date) },
                uniquingKeysWith: { first, _ in first }
            )
            DispatchQueue.main.async {
                let now = Date()
                for prompt in DataStore.shared.prompts where prompt.outcome == .pending && prompt.scheduledAt <= now {
                    let delivered = deliveredDates[prompt.id]
                    let expired = now.timeIntervalSince(prompt.scheduledAt) > noResponseAfter
                    guard delivered != nil || expired else { continue }
                    DataStore.shared.updatePrompt(id: prompt.id) { p in
                        if p.deliveredAt == nil { p.deliveredAt = delivered }
                        if expired { p.outcome = .noResponse }
                    }
                }
                next()
            }
        }
    }

    /// 전달 시각이 지났는데 context가 없는 알림의 센서 기록을 조회한다.
    private static func collectMissingContexts(then next: @escaping () -> Void) {
        let now = Date()
        let targets = DataStore.shared.prompts.filter {
            let age = now.timeIntervalSince($0.scheduledAt)
            return $0.context == nil && age > sensorDelay && age < 7 * 24 * 60 * 60
        }
        guard !targets.isEmpty else {
            next()
            return
        }

        let group = DispatchGroup()
        for prompt in targets {
            group.enter()
            ContextCollector.shared.collect(before: prompt.deliveredAt ?? prompt.scheduledAt) { snapshot in
                DataStore.shared.updatePrompt(id: prompt.id) { $0.context = snapshot }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            LogStore.shared.add("context \(targets.count)건 수집")
            next()
        }
    }
}
