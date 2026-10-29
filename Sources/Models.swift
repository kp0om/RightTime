import Foundation

enum PromptOutcome: String, Codable {
    case pending      // 전달 전이거나 아직 응답 없음
    case tapped       // 알림을 탭함
    case dismissed    // 알림을 지움
    case noResponse   // 전달 후 일정 시간 동안 응답 없음
}

/// Core Motion 활동 기록 한 구간
struct ActivitySegment: Codable {
    var start: Date
    var stationary: Bool
    var walking: Bool
    var running: Bool
    var automotive: Bool
    var cycling: Bool
    var unknown: Bool
    var confidence: Int   // 0 낮음, 1 보통, 2 높음

    var label: String {
        if automotive { return "automotive" }
        if cycling { return "cycling" }
        if running { return "running" }
        if walking { return "walking" }
        if stationary { return "stationary" }
        return "unknown"
    }
}

/// 알림 전달 직전의 센서 context
struct ContextSnapshot: Codable {
    var windowSeconds: Double
    var accelSampleCount: Int
    var accelMagMean: Double?
    var accelMagStd: Double?
    var accelMagMin: Double?
    var accelMagMax: Double?
    var accelMag5Hz: [Float]          // 5 Hz 구간 평균 가속도 크기, 샘플 없는 칸은 -1
    var activities: [ActivitySegment] // 전달 전 30분 활동 기록
    var steps5m: Int?
    var steps30m: Int?
    var collectedAt: Date
    var notes: [String]               // 조회 실패 사유 등
}

/// 시험 reminder 하나
struct Prompt: Codable, Identifiable {
    var id: String
    var text: String
    var scheduledAt: Date
    var deliveredAt: Date? = nil
    var outcome: PromptOutcome = .pending
    var respondedAt: Date? = nil
    var context: ContextSnapshot? = nil

    var responseSeconds: Double? {
        guard let respondedAt else { return nil }
        return respondedAt.timeIntervalSince(deliveredAt ?? scheduledAt)
    }
}

/// 앱이 깨어난 시각과 이유 (feasibility 점검용)
struct WakeEvent: Codable {
    var date: Date
    var reason: String
}

struct CollectionSettings: Codable, Equatable {
    var startHour = 9
    var endHour = 22
    var promptsPerDay = 7
    var minGapMinutes = 45
    var enabled = false
}
