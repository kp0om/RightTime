import Foundation

/// 학습 때(ml/features.py, ml/common.py)와 같은 방식으로 19개 공통 특징을 만든다.
/// 값이 없으면 nil로 두고, 모델이 학습 데이터 중앙값으로 채운다.
enum Features {
    static let states = ["stationary", "walking", "running", "automotive", "cycling", "unknown"]
    static let activityWindow: TimeInterval = 30 * 60

    static let names: [String] =
        ["hour_sin", "hour_cos", "is_weekend", "act_now_age_log", "act_changes_30m",
         "phone_motion_avg_log", "phone_motion_max_log"]
        + states.map { "act_now_\($0)" } + states.map { "act_frac_\($0)" }

    static let koreanNames: [String: String] = [
        "hour_sin": "시각(sin)", "hour_cos": "시각(cos)", "is_weekend": "주말",
        "act_now_age_log": "현재 활동 지속 시간", "act_changes_30m": "30분 내 활동 변화 수",
        "phone_motion_avg_log": "폰 움직임 평균", "phone_motion_max_log": "폰 움직임 최대",
        "act_now_stationary": "지금 정지", "act_now_walking": "지금 걷기", "act_now_running": "지금 달리기",
        "act_now_automotive": "지금 차량", "act_now_cycling": "지금 자전거", "act_now_unknown": "지금 알 수 없음",
        "act_frac_stationary": "30분 중 정지 비율", "act_frac_walking": "30분 중 걷기 비율",
        "act_frac_running": "30분 중 달리기 비율", "act_frac_automotive": "30분 중 차량 비율",
        "act_frac_cycling": "30분 중 자전거 비율", "act_frac_unknown": "30분 중 알 수 없음 비율",
    ]

    /// - Parameters:
    ///   - snapshot: t 직전 센서 기록 (없으면 활동·움직임 특징은 비어 있는 값)
    ///   - accelSeries: 5 Hz 가속도 크기(g). 주면 snapshot의 기록 대신 쓴다 (앱이 켜져 있을 때 실시간 값).
    static func vector(at t: Date, snapshot: ContextSnapshot?, accelSeries: [Float]? = nil) -> [Double?] {
        var f: [String: Double?] = [:]

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: t)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        f["hour_sin"] = sin(2 * .pi * hour / 24)
        f["hour_cos"] = cos(2 * .pi * hour / 24)
        f["is_weekend"] = (parts.weekday == 1 || parts.weekday == 7) ? 1 : 0   // 1 일요일, 7 토요일

        for (key, value) in activityFeatures(snapshot?.activities ?? [], at: t) {
            f[key] = value
        }

        let series = accelSeries ?? snapshot?.accelMag5Hz ?? []
        let last30s = series.suffix(150).filter { $0 >= 0 }.map { abs(Double($0) - 1) * 9.81 }
        if last30s.isEmpty {
            f["phone_motion_avg_log"] = .some(nil)
            f["phone_motion_max_log"] = .some(nil)
        } else {
            let avg = last30s.reduce(0, +) / Double(last30s.count)
            let mx = last30s.max() ?? 0
            f["phone_motion_avg_log"] = log1p(min(max(avg, 0), 50))
            f["phone_motion_max_log"] = log1p(min(max(mx, 0), 50))
        }

        return names.map { (f[$0] ?? nil) }
    }

    private static func activityFeatures(_ segments: [ActivitySegment], at t: Date) -> [String: Double?] {
        var f: [String: Double?] = [:]
        for s in states {
            f["act_now_\(s)"] = 0
            f["act_frac_\(s)"] = 0
        }
        f["act_now_age_log"] = .some(nil)
        f["act_changes_30m"] = 0

        // 시간순 정렬, t 이후 기록 제외, 같은 상태가 이어지면 하나로 합친다
        var merged: [(start: Date, label: String)] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) where seg.start <= t {
            if merged.last?.label != seg.label {
                merged.append((seg.start, seg.label))
            }
        }
        guard let current = merged.last else { return f }

        f["act_now_\(current.label)"] = 1
        f["act_now_age_log"] = log1p(t.timeIntervalSince(current.start))

        let windowStart = t.addingTimeInterval(-activityWindow)
        var fractions: [String: Double] = [:]
        for (i, seg) in merged.enumerated() {
            let end = i + 1 < merged.count ? merged[i + 1].start : t
            let overlap = min(end, t).timeIntervalSince(max(seg.start, windowStart))
            if overlap > 0 {
                fractions[seg.label, default: 0] += overlap / activityWindow
            }
        }
        for (label, value) in fractions {
            f["act_frac_\(label)"] = value
        }
        f["act_changes_30m"] = Double(merged.filter { $0.start >= windowStart }.count)
        return f
    }
}
