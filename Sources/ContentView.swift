import SwiftUI
import UserNotifications

struct ContentView: View {
    // 앱이 화면에 있는 동안 30초마다 AI가 지금 보낼지 다시 판단한다 (시연용)
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            ScheduleView()
                .tabItem { Label("일정", systemImage: "calendar") }
            AIView()
                .tabItem { Label("AI", systemImage: "brain") }
            SettingsView()
                .tabItem { Label("설정·기록", systemImage: "gearshape") }
        }
        .onReceive(timer) { _ in
            Planner.wake(reason: "화면 30초")
        }
    }
}

// MARK: - 일정

struct ScheduleView: View {
    @ObservedObject private var store = ReminderStore.shared
    @State private var showingAdd = false

    private var active: [Reminder] { store.reminders.filter { $0.status != .done } }
    private var finished: [Reminder] { store.reminders.filter { $0.status == .done }.reversed() }

    var body: some View {
        NavigationStack {
            List {
                if active.isEmpty {
                    Section {
                        Text("+ 버튼으로 할 일과 마감 시각을 넣으면, AI가 그 사이에서 알림을 보기 좋은 때를 골라 알려 줍니다.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groupedByDay(active)) { group in
                    Section(group.title) {
                        ForEach(group.items) { ReminderRow(reminder: $0) }
                            .onDelete { offsets in
                                offsets.map { group.items[$0].id }.forEach(Planner.delete)
                            }
                    }
                }
                if !finished.isEmpty {
                    Section("끝난 일정") {
                        ForEach(finished.prefix(30)) { ReminderRow(reminder: $0) }
                            .onDelete { offsets in
                                let items = Array(finished.prefix(30))
                                offsets.map { items[$0].id }.forEach(Planner.delete)
                            }
                    }
                }
            }
            .navigationTitle("RightTime")
            .toolbar {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddReminderView()
            }
        }
    }

    struct DayGroup: Identifiable {
        var title: String
        var items: [Reminder]
        var id: String { title }
    }

    private func groupedByDay(_ items: [Reminder]) -> [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for item in items.sorted(by: { $0.deadline < $1.deadline }) {
            let title: String
            if calendar.isDateInToday(item.deadline) {
                title = "오늘"
            } else if calendar.isDateInTomorrow(item.deadline) {
                title = "내일"
            } else {
                title = item.deadline.formatted(.dateTime.month().day().weekday())
            }
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append(DayGroup(title: title, items: [item]))
            }
        }
        return result
    }
}

struct ReminderRow: View {
    let reminder: Reminder
    @ObservedObject private var store = ReminderStore.shared

    private var lastSample: Sample? {
        store.samples.last { $0.reminderId == reminder.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(reminder.title).font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }
            Text("\(reminder.windowStart.formatted(date: .omitted, time: .shortened)) ~ \(reminder.deadline.formatted(date: .omitted, time: .shortened)) 사이")
                .font(.caption).foregroundStyle(.secondary)
            if let sample = lastSample {
                Text(sampleText(sample)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            if reminder.status != .done {
                Button("완료") { Planner.markDone(reminder.id) }.tint(.green)
            }
        }
    }

    private var statusText: String {
        switch reminder.status {
        case .waiting: return reminder.explore ? "탐색 예약" : "AI 대기"
        case .delivered: return "알림 보냄"
        case .done: return "끝남"
        }
    }

    private var statusColor: Color {
        switch reminder.status {
        case .waiting: return .blue
        case .delivered: return .orange
        case .done: return .secondary
        }
    }

    private func sampleText(_ s: Sample) -> String {
        var text = "\(s.kind.korean) 전달 \(s.deliveredAt.formatted(date: .omitted, time: .shortened))"
        if let p = s.p { text += String(format: " · p %.2f", p) }
        if let r = s.response { text += " · \(r)" }
        if let label = s.label { text += label == 1 ? " · 60초 내 확인" : " · 60초 내 확인 안 함" }
        return text
    }
}

struct AddReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var windowStart = Date()
    @State private var deadline = Date().addingTimeInterval(2 * 60 * 60)

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && deadline > Date().addingTimeInterval(2 * 60)
            && deadline > windowStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("할 일 (예: 과제 제출, 약 먹기)", text: $title)
                }
                Section {
                    DatePicker("이때부터", selection: $windowStart, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("마감", selection: $deadline, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("AI가 이 사이에서 확인하기 좋은 때를 골라 알립니다. 끝까지 좋은 때가 없으면 마감 시각에 알립니다.")
                }
                Section("빠르게 정하기") {
                    HStack {
                        quick("30분", 30)
                        quick("1시간", 60)
                        quick("3시간", 180)
                        quick("오늘 밤", nil)
                    }
                }
            }
            .navigationTitle("일정 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        Planner.add(title: title.trimmingCharacters(in: .whitespaces),
                                    windowStart: windowStart, deadline: deadline)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }

    private func quick(_ label: String, _ minutes: Int?) -> some View {
        Button(label) {
            windowStart = Date()
            if let minutes {
                deadline = Date().addingTimeInterval(Double(minutes) * 60)
            } else {
                let calendar = Calendar.current
                let tonight = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
                deadline = tonight > Date().addingTimeInterval(10 * 60) ? tonight : Date().addingTimeInterval(60 * 60)
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AI

struct AIView: View {
    @ObservedObject private var model = OnlineModel.shared
    @ObservedObject private var store = ReminderStore.shared
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("지금 확인할 확률 p", value: store.lastP.map { String(format: "%.2f", $0) } ?? "-")
                    LabeledContent("기준 θ (마감 가까우면 절반까지 낮춤)", value: String(format: "%.2f", model.theta))
                    if let t = store.lastEvaluated {
                        LabeledContent("마지막 판단", value: t.formatted(date: .omitted, time: .standard))
                    }
                    Button("지금 다시 판단") { Planner.wake(reason: "직접 판단") }
                } header: {
                    Text("현재 판단")
                } footer: {
                    Text("앱이 켜져 있으면 30초마다, 꺼져 있으면 iOS가 앱을 깨울 때 판단합니다.")
                }

                Section {
                    LabeledContent("응답으로 학습한 횟수", value: "\(model.state.updates)회")
                    LabeledContent("응답 결과", value: store.accuracySummary)
                    LabeledContent("시작 모델", value: model.initial.trainedOn.isEmpty ? "-" : model.initial.trainedOn)
                } header: {
                    Text("실시간 학습")
                } footer: {
                    Text("알림을 60초 안에 확인하면 1, 아니면 0으로 그 순간의 상황을 바로 학습합니다. 일정의 20%는 AI 판단 없이 무작위 시각에 보내 AI가 고르지 않은 상황도 배웁니다.")
                }

                Section("시작 대비 가장 많이 바뀐 가중치") {
                    ForEach(model.biggestChanges(5)) { change in
                        LabeledContent(change.name, value: String(format: "%+.2f → %+.2f", change.initial, change.now))
                    }
                }

                Section("최근 학습") {
                    let learned = store.samples.filter(\.learned).suffix(15).reversed()
                    if learned.isEmpty {
                        Text("아직 학습한 응답이 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(learned)) { s in
                        VStack(alignment: .leading) {
                            Text("\(s.title) · \(s.kind.korean) · 라벨 \(s.label ?? -1)")
                            Text(String(format: "이 상황의 p %.2f → %.2f", s.pBeforeUpdate ?? 0, s.pAfterUpdate ?? 0))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("판단 기록") {
                    ForEach(Array(store.decisions.suffix(20).reversed())) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.title)
                                Text("\(d.time.formatted(date: .omitted, time: .shortened)) · \(d.note)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "p %.2f / θ %.2f", d.p, d.theta)).font(.caption.monospacedDigit())
                            Image(systemName: d.delivered ? "bell.fill" : "pause.circle")
                                .foregroundStyle(d.delivered ? .orange : .secondary)
                        }
                    }
                }

                Section {
                    Button("학습 초기화", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("AI")
            .confirmationDialog("기기에서 학습한 가중치를 시작 모델로 되돌릴까요?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("되돌리기", role: .destructive) { model.reset() }
            }
        }
    }
}

// MARK: - 설정·기록

struct SettingsView: View {
    @ObservedObject private var log = LogStore.shared
    @State private var notificationStatus = "확인 중"

    var body: some View {
        NavigationStack {
            List {
                Section("권한") {
                    LabeledContent("알림", value: notificationStatus)
                    LabeledContent("모션", value: ContextCollector.isAuthorized ? "허용됨" : "허용 안 됨")
                    Button("알림 권한 요청") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                            LogStore.shared.add("알림 권한: \(granted ? "허용" : "거부")")
                            refreshStatus()
                        }
                    }
                    Button("모션 권한 요청") { ContextCollector.shared.requestMotionPermission() }
                }
                Section {
                    ShareLink("일정·학습 기록 내보내기 (JSON)", item: ReminderStore.fileURL)
                } footer: {
                    Text("파일 공유(iTunes)로도 righttime-v2.json, righttime-model.json, righttime-log.txt를 꺼낼 수 있습니다.")
                }
                Section("기록") {
                    Button("기록 지우기", role: .destructive) { log.clear() }
                    ForEach(Array(log.lines.prefix(150).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("설정·기록")
            .onAppear(perform: refreshStatus)
        }
    }

    private func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized: text = "허용됨"
            case .denied: text = "거부됨"
            case .notDetermined: text = "아직 묻지 않음"
            case .provisional, .ephemeral: text = "임시 허용"
            @unknown default: text = "알 수 없음"
            }
            DispatchQueue.main.async { notificationStatus = text }
        }
    }
}
