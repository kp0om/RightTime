import Foundation

/// 수집한 알림·응답·센서 context를 기기 안 JSON 파일에 저장한다. 모든 변경은 메인 스레드에서 한다.
final class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published private(set) var prompts: [Prompt] = []
    @Published private(set) var wakes: [WakeEvent] = []
    @Published private(set) var settings = CollectionSettings()

    private struct Saved: Codable {
        var prompts: [Prompt]
        var wakes: [WakeEvent]
        var settings: CollectionSettings
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("righttime-data.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode(Saved.self, from: data) {
            prompts = saved.prompts
            wakes = saved.wakes
            settings = saved.settings
        }
    }

    // MARK: - 변경

    func addPrompts(_ new: [Prompt]) {
        onMain {
            self.prompts.append(contentsOf: new)
            self.prompts.sort { $0.scheduledAt < $1.scheduledAt }
            self.save()
        }
    }

    func updatePrompt(id: String, _ change: @escaping (inout Prompt) -> Void) {
        onMain {
            guard let index = self.prompts.firstIndex(where: { $0.id == id }) else { return }
            change(&self.prompts[index])
            self.save()
        }
    }

    func removePrompts(ids: Set<String>) {
        onMain {
            self.prompts.removeAll { ids.contains($0.id) }
            self.save()
        }
    }

    func recordResponse(id: String, outcome: PromptOutcome, deliveredAt: Date, respondedAt: Date) {
        updatePrompt(id: id) { prompt in
            guard prompt.respondedAt == nil else { return }
            prompt.deliveredAt = deliveredAt
            prompt.respondedAt = respondedAt
            prompt.outcome = outcome
        }
    }

    func addWake(_ reason: String) {
        onMain {
            self.wakes.append(WakeEvent(date: Date(), reason: reason))
            self.save()
        }
    }

    func updateSettings(_ newSettings: CollectionSettings) {
        onMain {
            self.settings = newSettings
            self.save()
        }
    }

    // MARK: - 저장과 내보내기

    private func save() {
        do {
            let data = try Self.encoder.encode(Saved(prompts: prompts, wakes: wakes, settings: settings))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogStore.shared.add("저장 실패: \(error.localizedDescription)")
        }
    }

    /// 학습용 CSV(요약 특징)와 JSON(원본 전체)을 만들어 공유할 수 있게 한다.
    func makeExportFiles() throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())

        let jsonURL = directory.appendingPathComponent("righttime-\(stamp).json")
        try Self.encoder.encode(Saved(prompts: prompts, wakes: wakes, settings: settings)).write(to: jsonURL)

        let csvURL = directory.appendingPathComponent("righttime-\(stamp).csv")
        try Data(csvText().utf8).write(to: csvURL)

        return [csvURL, jsonURL]
    }

    private func csvText() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        func date(_ value: Date?) -> String { value.map { iso.string(from: $0) } ?? "" }
        func number(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "" }
        func integer(_ value: Int?) -> String { value.map { String($0) } ?? "" }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

        var lines = [
            "id,text,scheduled_at,delivered_at,outcome,responded_at,response_seconds,"
            + "accel_count,accel_mean,accel_std,accel_min,accel_max,steps_5m,steps_30m,"
            + "last_activity,last_activity_confidence,last_activity_age_s,context_notes"
        ]
        let now = Date()
        for prompt in prompts where prompt.scheduledAt <= now {
            let context = prompt.context
            let reference = prompt.deliveredAt ?? prompt.scheduledAt
            let lastActivity = context?.activities.last { $0.start <= reference }
            let fields = [
                prompt.id,
                quoted(prompt.text),
                date(prompt.scheduledAt),
                date(prompt.deliveredAt),
                prompt.outcome.rawValue,
                date(prompt.respondedAt),
                number(prompt.responseSeconds),
                integer(context?.accelSampleCount),
                number(context?.accelMagMean),
                number(context?.accelMagStd),
                number(context?.accelMagMin),
                number(context?.accelMagMax),
                integer(context?.steps5m),
                integer(context?.steps30m),
                lastActivity?.label ?? "",
                integer(lastActivity?.confidence),
                number(lastActivity.map { reference.timeIntervalSince($0.start) }),
                quoted(context?.notes.joined(separator: "; ") ?? ""),
            ]
            lines.append(fields.joined(separator: ","))
        }
        // Excel에서 한글이 깨지지 않게 BOM을 붙인다
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
