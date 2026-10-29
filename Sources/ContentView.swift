import SwiftUI
import UserNotifications

struct ContentView: View {
    @ObservedObject private var store = DataStore.shared
    @ObservedObject private var log = LogStore.shared
    @State private var draft = DataStore.shared.settings
    @State private var exportURLs: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                statusSection
                settingsSection
                permissionSection
                recentSection
                exportSection
                logSection
            }
            .navigationTitle("RightTime 수집")
        }
    }

    // MARK: - 화면 구성

    private var statusSection: some View {
        Section("수집 상태") {
            LabeledContent("상태", value: store.settings.enabled ? "수집 중" : "중지됨")
            LabeledContent("응답", value: "탭 \(count(.tapped)) · 지움 \(count(.dismissed)) · 무응답 \(count(.noResponse))")
            LabeledContent("예정된 알림", value: "\(upcoming.count)개")
            if let next = upcoming.first {
                LabeledContent("다음 알림", value: next.scheduledAt.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("앱 깨어남 기록", value: "\(store.wakes.count)회")
            if store.settings.enabled {
                Button("수집 중지", role: .destructive, action: stop)
            } else {
                Button("수집 시작", action: start)
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Stepper("시작 \(draft.startHour)시", value: $draft.startHour, in: 0...23)
            Stepper("종료 \(draft.endHour)시", value: $draft.endHour, in: 1...24)
            Stepper("하루 \(draft.promptsPerDay)회", value: $draft.promptsPerDay, in: 1...10)
            Button("설정 적용", action: applySettings)
                .disabled(draft == store.settings || draft.startHour >= draft.endHour)
        } header: {
            Text("알림 시간 범위")
        } footer: {
            Text("수면 시간은 범위 밖에 두세요. 적용하면 아직 오지 않은 알림을 새 설정으로 다시 예약합니다.")
        }
    }

    private var permissionSection: some View {
        Section("권한과 점검") {
            Button("알림 권한 요청", action: requestNotificationPermission)
            Button("모션 권한 요청") { ContextCollector.shared.requestMotionPermission() }
            Button("10초 뒤 시험 알림 (기록 안 됨)", action: scheduleQuickTest)
        }
    }

    private var recentSection: some View {
        Section("최근 알림") {
            if recent.isEmpty {
                Text("아직 전달된 알림이 없어요.").foregroundStyle(.secondary)
            }
            ForEach(recent) { prompt in
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.text).font(.subheadline)
                    Text(summary(of: prompt)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exportSection: some View {
        Section("데이터 내보내기") {
            Button("내보내기 파일 만들기") {
                do {
                    exportURLs = try store.makeExportFiles()
                } catch {
                    log.add("내보내기 실패: \(error.localizedDescription)")
                }
            }
            if !exportURLs.isEmpty {
                ShareLink(items: exportURLs) {
                    Label("CSV·JSON 공유", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var logSection: some View {
        Section("점검 로그") {
            Button("로그 지우기", role: .destructive, action: log.clear)
            ForEach(Array(log.lines.prefix(50).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        }
    }

    // MARK: - 데이터

    private var upcoming: [Prompt] {
        let now = Date()
        return store.prompts.filter { $0.outcome == .pending && $0.scheduledAt > now }
    }

    private var recent: [Prompt] {
        let now = Date()
        return Array(store.prompts.filter { $0.scheduledAt <= now }.reversed().prefix(15))
    }

    private func count(_ outcome: PromptOutcome) -> Int {
        store.prompts.filter { $0.outcome == outcome }.count
    }

    private func summary(of prompt: Prompt) -> String {
        let time = prompt.scheduledAt.formatted(date: .abbreviated, time: .shortened)
        let outcome: String
        switch prompt.outcome {
        case .pending: outcome = "대기"
        case .tapped: outcome = "탭"
        case .dismissed: outcome = "지움"
        case .noResponse: outcome = "무응답"
        }
        let response = prompt.responseSeconds.map { " · \(Int($0))초" } ?? ""
        let context = prompt.context == nil ? "context 대기" : "context ✓"
        return "\(time) · \(outcome)\(response) · \(context)"
    }

    // MARK: - 동작

    private func start() {
        requestNotificationPermission()
        ContextCollector.shared.requestMotionPermission()
        var settings = store.settings
        settings.enabled = true
        store.updateSettings(settings)
        draft = settings
        Pipeline.refresh(reason: "수집 시작")
    }

    private func stop() {
        Scheduler.cancelFuture()
        var settings = store.settings
        settings.enabled = false
        store.updateSettings(settings)
        draft = settings
    }

    private func applySettings() {
        var settings = draft
        settings.enabled = store.settings.enabled
        Scheduler.cancelFuture()
        store.updateSettings(settings)
        draft = settings
        Pipeline.refresh(reason: "설정 변경")
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                LogStore.shared.add("알림 권한 오류: \(error.localizedDescription)")
            } else {
                LogStore.shared.add("알림 권한: \(granted ? "허용" : "거부")")
            }
        }
    }

    private func scheduleQuickTest() {
        let content = UNMutableNotificationContent()
        content.title = "RightTime 시험 알림"
        content.body = "탭하면 응답 시간이 점검 로그에 찍힙니다."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            LogStore.shared.add(error.map { "예약 실패: \($0.localizedDescription)" } ?? "10초 뒤 시험 알림 예약됨")
        }
    }
}
