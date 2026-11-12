import Foundation

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

/// 사용자가 입력한 일정 하나. windowStart부터 deadline 사이에 AI가 알림 시점을 고른다.
struct Reminder: Codable, Identifiable {
    enum Status: String, Codable {
        case waiting     // 아직 전달 전 (AI가 시점을 고르는 중)
        case delivered   // 알림을 보냈고 응답 대기
        case done        // 확인했거나 마감이 지나 끝남
    }

    var id = UUID().uuidString
    var title: String
    var windowStart: Date
    var deadline: Date
    var createdAt = Date()
    var explore = false          // 탐색 일정: AI 판단 대신 무작위 시각에 보낸다
    var exploreAt: Date? = nil
    var status: Status = .waiting
    var cooldownUntil: Date? = nil   // "지금은 곤란해요" 뒤 다시 판단하기까지 기다리는 시각
}

enum DeliveryKind: String, Codable {
    case policy     // AI가 지금이 좋다고 판단해 보냄
    case explore    // 탐색용 무작위 시각
    case failsafe   // 마감 시각 안전장치

    var korean: String {
        switch self {
        case .policy: return "AI 판단"
        case .explore: return "탐색"
        case .failsafe: return "마감"
        }
    }
}

/// 알림 한 번 전달 = 학습 샘플 하나. 60초 안에 확인하면 라벨 1.
struct Sample: Codable, Identifiable {
    var id = UUID().uuidString
    var reminderId: String
    var title: String
    var kind: DeliveryKind
    var deliveredAt: Date
    var p: Double? = nil                 // 전달 시점의 예측 확률 (AI 판단일 때)
    var features: [Double?]? = nil       // 전달 시점 특징 (탐색·마감은 나중에 센서 기록으로 채움)
    var respondedAt: Date? = nil
    var response: String? = nil          // 확인 / 곤란 / 지움 / 탭
    var label: Int? = nil
    var learned = false
    var pBeforeUpdate: Double? = nil
    var pAfterUpdate: Double? = nil
}

/// AI가 판단할 때마다 남기는 기록
struct DecisionRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var time: Date
    var title: String
    var p: Double
    var theta: Double
    var delivered: Bool
    var note: String
}
