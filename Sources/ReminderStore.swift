import Foundation

/// 일정, 학습 샘플, AI 판단 기록을 기기 안 JSON 파일 하나에 저장한다. 모든 변경은 메인 스레드에서 한다.
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published var reminders: [Reminder] = []
    @Published var samples: [Sample] = []
    @Published var decisions: [DecisionRecord] = []
    @Published var lastP: Double? = nil
    @Published var lastEvaluated: Date? = nil

    private struct Saved: Codable {
        var reminders: [Reminder]
        var samples: [Sample]
        var decisions: [DecisionRecord]
    }

    static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("righttime-v2.json")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? decoder.decode(Saved.self, from: data) {
            reminders = saved.reminders
            samples = saved.samples
            decisions = saved.decisions
        }
    }

    func save() {
        if decisions.count > 300 {
            decisions.removeFirst(decisions.count - 300)
        }
        let saved = Saved(reminders: reminders, samples: samples, decisions: decisions)
        if let data = try? Self.encoder.encode(saved) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func reminderIndex(_ id: String) -> Int? {
        reminders.firstIndex { $0.id == id }
    }

    /// 이 일정의 가장 최근 전달 중 아직 응답이 없는 샘플
    func openSampleIndex(reminderId: String, kind: DeliveryKind) -> Int? {
        samples.lastIndex { $0.reminderId == reminderId && $0.kind == kind && $0.response == nil }
    }

    var accuracySummary: String {
        let labeled = samples.filter { $0.label != nil }
        guard !labeled.isEmpty else { return "아직 없음" }
        let confirmed = labeled.filter { $0.label == 1 }.count
        return "\(labeled.count)회 중 \(confirmed)회 60초 내 확인"
    }
}
