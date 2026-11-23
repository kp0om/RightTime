import SwiftUI
import UserNotifications

extension Color {
    /// 앱 아이콘의 남색 (#4F5BD5)과 주황 (#FF9F43)
    static let brand = Color(red: 0x4F / 255, green: 0x5B / 255, blue: 0xD5 / 255)
    static let brandAccent = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x43 / 255)
}

struct ContentView: View {
    // 앱이 화면에 있는 동안 30초마다 AI가 지금 보낼지 다시 판단한다 (시연용)
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            CalendarView()
                .tabItem { Label("캘린더", systemImage: "calendar") }
            AIView()
                .tabItem { Label("AI", systemImage: "brain") }
            SettingsView()
                .tabItem { Label("설정·기록", systemImage: "gearshape") }
        }
        .tint(.brand)
        .onReceive(timer) { _ in
            Planner.wake(reason: "화면 30초")
        }
    }
}

// MARK: - 캘린더

extension Calendar {
    static let mondayFirst: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    func startOfMonth(_ date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

struct CalendarView: View {
    @ObservedObject private var store = ReminderStore.shared
    @AppStorage(Planner.learningModeKey) private var learningMode = false
    @State private var month = Calendar.mondayFirst.startOfMonth(Date())
    @State private var path: [Date] = []
    @State private var showingAdd = false

    private let calendar = Calendar.mondayFirst
    private let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                weekdayRow
                Divider()
                GeometryReader { geo in
                    let days = gridDays
                    let rows = days.count / 7
                    let height = geo.size.height / CGFloat(max(rows, 1))
                    VStack(spacing: 0) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { column in
                                    let day = days[row * 7 + column]
                                    DayCell(day: day,
                                            inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                                            isSunday: column == 6,
                                            items: reminders(on: day))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: height)
                                        .contentShape(Rectangle())
                                        .onTapGesture { path.append(day) }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.width < -60 { move(1) }
                if value.translation.width > 60 { move(-1) }
            })
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Date.self) { day in
                DayDetailView(day: day)
            }
            .sheet(isPresented: $showingAdd) {
                AddReminderView()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(monthTitle).font(.title2.bold())
            if learningMode {
                Text("학습 모드")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
            Button("오늘") { month = calendar.startOfMonth(Date()) }.font(.subheadline)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
            Button { showingAdd = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(.caption)
                    .foregroundStyle(index == 6 ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 6)
    }

    private var monthTitle: String {
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0)년 \(parts.month ?? 0)월"
    }

    /// 월요일부터 시작하는 주 단위 날짜 칸 (앞뒤 달 날짜 포함)
    private var gridDays: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) + 5) % 7
        let weeks = Int(ceil(Double(leading + range.count) / 7))
        guard let first = calendar.date(byAdding: .day, value: -leading, to: month) else { return [] }
        return (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    private func reminders(on day: Date) -> [Reminder] {
        store.reminders
            .filter { calendar.isDate($0.deadline, inSameDayAs: day) }
            .sorted { $0.deadline < $1.deadline }
    }

    private func move(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            withAnimation(.easeInOut(duration: 0.2)) { month = next }
        }
    }
}

struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isSunday: Bool
    let items: [Reminder]

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.subheadline)
                .foregroundStyle(isToday ? Color.white : (isSunday ? Color.red : Color.primary))
                .frame(width: 26, height: 26)
                .background {
                    if isToday { Circle().fill(Color.accentColor) }
                }
            ForEach(items.prefix(3)) { item in
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(chipColor(item)))
                    .foregroundStyle(.white)
            }
            if items.count > 3 {
                Text("+\(items.count - 3)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
        .opacity(inMonth ? 1 : 0.35)
    }

    private func chipColor(_ item: Reminder) -> Color {
        switch item.status {
        case .waiting: return .brand
        case .delivered: return .brandAccent
        case .done: return .gray
        }
    }
}

struct DayDetailView: View {
    let day: Date
    @ObservedObject private var store = ReminderStore.shared
    @State private var showingAdd = false

    private var items: [Reminder] {
        store.reminders
            .filter { Calendar.current.isDate($0.deadline, inSameDayAs: day) }
            .sorted { $0.windowStart < $1.windowStart }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image("EmptyDay")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                        Text("이날 할 일이 없어요. 오른쪽 위 +로 추가하면, AI가 시간대 안에서 알림을 보기 좋은 때를 골라 알려 줘요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(items) { ReminderRow(reminder: $0) }
                        .onDelete { offsets in
                            offsets.map { items[$0].id }.forEach(Planner.delete)
                        }
                } header: {
                    Text("할 일 \(items.count)개")
                } footer: {
                    Text("오른쪽으로 밀면 완료, 왼쪽으로 밀면 삭제돼요. 파란색은 AI가 시점을 고르는 중, 주황색은 알림을 보낸 것, 회색은 끝난 일정이에요.")
                }
            }
        }
        .navigationTitle(day.formatted(.dateTime.month().day().weekday(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showingAdd = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showingAdd) {
            AddReminderView(day: day)
        }
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
    @State private var windowStart: Date
    @State private var deadline: Date
    @State private var now = Date()
    @State private var confirmUntitled = false

    static let untitled = "이름 없는 알림"

    /// day를 주면 그날 일정으로 시작한다 (미래 날짜는 오전 9시부터).
    init(day: Date? = nil) {
        let calendar = Calendar.current
        let now = Date()
        var start = now
        if let day, !calendar.isDateInToday(day), day > now,
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) {
            start = morning
        }
        _windowStart = State(initialValue: start)
        _deadline = State(initialValue: start.addingTimeInterval(2 * 60 * 60))
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }

    /// 추가할 수 없는 이유. nil이면 추가할 수 있다.
    private var problem: String? {
        if deadline <= windowStart { return "마감은 시작 시각보다 뒤여야 해요." }
        if deadline <= now.addingTimeInterval(2 * 60) { return "마감은 지금부터 2분 뒤 이후로 정해 주세요." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("할 일 (예: 과제 제출, 약 먹기)", text: $title)
                } footer: {
                    if trimmedTitle.isEmpty {
                        Text("비워 두고 추가하면 '\(Self.untitled)'으로 추가할지 물어봐요.")
                    }
                }
                Section {
                    DatePicker("이때부터", selection: $windowStart, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("마감", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("시간대")
                } footer: {
                    Text("AI가 이 사이에서 확인하기 좋은 때를 골라 알립니다. 끝까지 좋은 때가 없으면 마감 시각에 알립니다.")
                }
                Section("빠르게 정하기") {
                    HStack {
                        quick("30분", 30)
                        quick("1시간", 60)
                        quick("3시간", 180)
                        quick("그날 밤", nil)
                    }
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.subheadline)
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
                        if trimmedTitle.isEmpty {
                            confirmUntitled = true
                        } else {
                            save(trimmedTitle)
                        }
                    }
                    .disabled(problem != nil)
                }
            }
            .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { now = $0 }
            .alert("알림 이름이 작성되지 않았습니다. 적용하시겠습니까?", isPresented: $confirmUntitled) {
                Button("예") { save(Self.untitled) }
                Button("아니오", role: .cancel) {}
            } message: {
                Text("'예'를 누르면 '\(Self.untitled)'으로 추가돼요.")
            }
        }
    }

    private func save(_ name: String) {
        Planner.add(title: name, windowStart: windowStart, deadline: deadline)
        dismiss()
    }

    /// 시작 시각(오늘이면 지금)부터 정한 길이만큼, 또는 그날 밤 10시까지
    private func quick(_ label: String, _ minutes: Int?) -> some View {
        Button(label) {
            let base = max(windowStart, Date())
            windowStart = base
            if let minutes {
                deadline = base.addingTimeInterval(Double(minutes) * 60)
            } else {
                let night = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: base) ?? base
                deadline = night > base.addingTimeInterval(10 * 60) ? night : base.addingTimeInterval(60 * 60)
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
    @AppStorage(Planner.learningModeKey) private var learningMode = false

    private var upcomingProbes: Int {
        store.probes.filter { !$0.delivered && $0.at > Date() }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Image("LearningMode")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 90)
                        .opacity(learningMode ? 1 : 0.4)
                    Toggle("사용자 학습 모드", isOn: Binding(
                        get: { learningMode },
                        set: { on in
                            learningMode = on
                            Planner.setLearningMode(on)
                        }))
                    if learningMode {
                        LabeledContent("예약된 학습 알림", value: "\(upcomingProbes)개")
                    }
                } footer: {
                    Text(learningMode
                         ? "하루 \(Planner.probesPerDay)번(\(Planner.probeStartHour)~\(Planner.probeEndHour)시) 무작위 시각에 학습 알림을 보내 응답을 더 모읍니다. 데이터가 빨리 쌓여 더 빨리 내게 맞춰집니다."
                         : "꺼 두면 직접 넣은 일정 알림만 보내고, 그 응답으로만 학습합니다. 켜면 무작위 학습 알림을 더 보내 더 빨리 개인화합니다.")
                }

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
                    Text("앱이 켜져 있으면 30초마다 p를 계산해 보여 주기만 하고, 앱을 보고 있는 동안에는 알림을 보내지 않습니다. 실제 전달은 다른 알림에 응답했을 때나 iOS가 앱을 깨울 때 판단하고, 일정을 넣고 15분이 지나야 보냅니다.")
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
                Section {
                    HStack(spacing: 14) {
                        Image("LogoMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("RightTime").font(.title3.bold())
                            Text("알림 보기 좋은 때를 기기 안 AI가 골라 줘요")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("버전 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
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
