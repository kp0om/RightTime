import UIKit
import UserNotifications

/// 발표 시연용 상황. 그 상황의 특징 값으로 AI 판단을 보여 준다.
struct DemoScenario: Identifiable {
    var id: String { name }
    var name: String
    var detail: String
    var hour: Double
    var values: [String: Double]

    static let all: [DemoScenario] = [
        DemoScenario(name: "수업 중, 폰은 책상 위", detail: "오후 3시 · 1시간 반째 정지 · 폰 움직임 거의 없음", hour: 15,
                     values: ["act_now_age_log": log1p(5400), "act_changes_30m": 0,
                              "phone_motion_avg_log": log1p(0.02), "phone_motion_max_log": log1p(0.05),
                              "act_now_stationary": 1, "act_frac_stationary": 1]),
        DemoScenario(name: "버스로 이동 중", detail: "오후 6시 · 15분째 차량 · 30분 중 60% 차량", hour: 18,
                     values: ["act_now_age_log": log1p(900), "act_changes_30m": 1,
                              "phone_motion_avg_log": log1p(1), "phone_motion_max_log": log1p(3),
                              "act_now_automotive": 1, "act_frac_automotive": 0.6, "act_frac_stationary": 0.4]),
        DemoScenario(name: "강의실에서 나와 걷는 중", detail: "오후 3시 · 5분째 걷기 · 활동 변화 2번", hour: 15,
                     values: ["act_now_age_log": log1p(300), "act_changes_30m": 2,
                              "phone_motion_avg_log": log1p(3), "phone_motion_max_log": log1p(8),
                              "act_now_walking": 1, "act_frac_stationary": 0.7, "act_frac_walking": 0.3]),
        DemoScenario(name: "저녁에 폰을 들고 쉬는 중", detail: "밤 9시 · 활동 '알 수 없음'(손에 들고 사용) 10분째", hour: 21,
                     values: ["act_now_age_log": log1p(600), "act_changes_30m": 1,
                              "phone_motion_avg_log": log1p(0.5), "phone_motion_max_log": log1p(1.5),
                              "act_now_unknown": 1, "act_frac_unknown": 0.5, "act_frac_stationary": 0.5]),
    ]

    var vector: [Double?] {
        var f: [String: Double] = ["hour_sin": sin(2 * .pi * hour / 24), "hour_cos": cos(2 * .pi * hour / 24), "is_weekend": 0]
        for state in Features.states {
            f["act_now_\(state)"] = 0
            f["act_frac_\(state)"] = 0
        }
        f.merge(values) { _, new in new }
        return Features.names.map { f[$0] }
    }
}

/// 발표 시연: 지금 상황(10초 뒤) 또는 정해 둔 상황으로 AI가 판단하고, 결과를 알림으로 보여 준다.
/// 시연 결과는 학습에 쓰지 않는다.
final class DemoRunner: ObservableObject {
    static let shared = DemoRunner()
    static let liveDelay = 10
    static let scenarioDelay: TimeInterval = 5

    struct Result {
        var title: String
        var p: Double
        var theta: Double
        var send: Bool
        var up: [String]
        var down: [String]
    }

    @Published private(set) var running = false
    @Published private(set) var remaining = 0
    @Published private(set) var last: Result?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// 버튼을 누른 뒤 폰을 내려놓거나 들고 걸을 시간을 주고, 10초 뒤 그 순간의 센서로 판단한다.
    func startLive() {
        guard !running else { return }
        running = true
        remaining = Self.liveDelay
        ContextCollector.shared.startLiveAccelerometer()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "demo") { [weak self] in
            self?.finish()
        }
        tick()
    }

    private func tick() {
        guard running else { return }
        if remaining <= 0 {
            decideLive()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.remaining -= 1
            self.tick()
        }
    }

    private func decideLive() {
        let now = Date()
        ContextCollector.shared.collect(before: now) { snapshot in
            let x = Features.vector(at: now, snapshot: snapshot, accelSeries: ContextCollector.shared.liveSeries())
            self.report(title: "지금 이 순간", x: x, delay: 1)
            self.finish()
        }
    }

    func runScenario(_ scenario: DemoScenario) {
        report(title: scenario.name, x: scenario.vector, delay: Self.scenarioDelay)
    }

    private func report(title: String, x: [Double?], delay: TimeInterval) {
        let model = OnlineModel.shared
        let p = model.predict(x)
        let theta = model.theta
        let parts = model.contributions(x)
        let up = parts.filter { $0.value > 0.05 }.sorted { $0.value > $1.value }.prefix(2).map { $0.name }
        let down = parts.filter { $0.value < -0.05 }.sorted { $0.value < $1.value }.prefix(2).map { $0.name }
        let result = Result(title: title, p: p, theta: theta, send: p >= theta, up: Array(up), down: Array(down))
        last = result

        ReminderStore.shared.decisions.append(DecisionRecord(time: Date(), title: "[시연] \(title)", p: p, theta: theta,
                                                             delivered: result.send, note: "발표 시연 (학습 안 함)"))
        ReminderStore.shared.save()
        LogStore.shared.add(String(format: "발표 시연: %@ p %.2f / θ %.2f → %@", title, p, theta, result.send ? "보냄" : "보류"))

        let content = UNMutableNotificationContent()
        content.title = result.send ? "[시연] 지금이 알림 보기 좋은 때예요" : "[시연] AI가 알림을 보류했어요"
        var body = String(format: "%@ · 60초 안에 확인할 확률 %.0f%% %@ 기준 %.0f%%", title, p * 100, result.send ? "≥" : "<", theta * 100)
        if let first = (result.send ? result.up : result.down).first {
            body += " · 가장 큰 이유: \(first)"
        }
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "demo-\(UUID().uuidString)", content: content, trigger: trigger))
    }

    private func finish() {
        running = false
        remaining = 0
        if UIApplication.shared.applicationState != .active {
            ContextCollector.shared.stopLiveAccelerometer()
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
