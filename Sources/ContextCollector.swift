import CoreMotion
import Foundation

extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator {
        NSFastEnumerationIterator(self)
    }
}

extension ActivitySegment {
    init(_ activity: CMMotionActivity) {
        self.init(
            start: activity.startDate,
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            automotive: activity.automotive,
            cycling: activity.cycling,
            unknown: activity.unknown,
            confidence: activity.confidence.rawValue
        )
    }
}

/// 알림 전달 직전의 context를 Core Motion 기록에서 나중에 조회한다.
/// iOS가 기록을 보관하므로(가속도 최대 3일, 활동 최대 7일) 앱이 그 순간 깨어 있지 않아도 된다.
final class ContextCollector {
    static let shared = ContextCollector()

    static let accelWindow: TimeInterval = 5 * 60
    static let activityWindow: TimeInterval = 30 * 60
    static let accelBinsPerSecond = 5.0

    private let recorder = CMSensorRecorder()
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let motionQueue = OperationQueue()
    private let accelQueue = DispatchQueue(label: "righttime.accel", qos: .utility)

    // 앱이 화면에 떠 있을 때 쓰는 실시간 가속도 (CMSensorRecorder 기록은 몇 분 늦게 조회될 수 있다)
    private let motionManager = CMMotionManager()
    private var liveBuffer: [(date: Date, magnitude: Float)] = []
    private let liveLock = NSLock()

    private struct AccelSummary {
        var count = 0
        var mean: Double?
        var std: Double?
        var min: Double?
        var max: Double?
        var series: [Float] = []
    }

    static var isAuthorized: Bool {
        CMMotionActivityManager.authorizationStatus() == .authorized
            && CMSensorRecorder.authorizationStatus() == .authorized
    }

    /// 가속도 기록을 12시간(최대) 동안 켠다. 앱이 깨어날 때마다 다시 불러 기록이 끊기지 않게 한다.
    func startAccelerometerRecording() {
        guard CMSensorRecorder.isAccelerometerRecordingAvailable() else {
            LogStore.shared.add("이 기기는 가속도 기록을 지원하지 않음")
            return
        }
        recorder.recordAccelerometer(forDuration: 12 * 60 * 60)
    }

    /// 5 Hz로 가속도를 받아 최근 30초를 보관한다. 앱이 화면에 있을 때만 켠다.
    func startLiveAccelerometer() {
        guard motionManager.isAccelerometerAvailable, !motionManager.isAccelerometerActive else { return }
        motionManager.accelerometerUpdateInterval = 1 / Self.accelBinsPerSecond
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let magnitude = Float((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
            let now = Date()
            self.liveLock.lock()
            self.liveBuffer.append((now, magnitude))
            self.liveBuffer.removeAll { now.timeIntervalSince($0.date) > 30 }
            self.liveLock.unlock()
        }
    }

    func stopLiveAccelerometer() {
        motionManager.stopAccelerometerUpdates()
        liveLock.lock()
        liveBuffer.removeAll()
        liveLock.unlock()
    }

    /// 최근 30초 실시간 가속도 크기(g). 20초 이상 모였을 때만 돌려준다.
    func liveSeries() -> [Float]? {
        liveLock.lock()
        defer { liveLock.unlock() }
        guard let first = liveBuffer.first, Date().timeIntervalSince(first.date) >= 20 else { return nil }
        return liveBuffer.map(\.magnitude)
    }

    /// 첫 조회 때 iOS가 모션 권한을 묻는다.
    func requestMotionPermission() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            LogStore.shared.add("활동 인식 미지원")
            return
        }
        let now = Date()
        activityManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: motionQueue) { _, error in
            if let error {
                LogStore.shared.add("모션 권한 오류: \(error.localizedDescription)")
            } else {
                LogStore.shared.add("모션 권한 확인됨")
            }
        }
    }

    func collect(before time: Date, completion: @escaping (ContextSnapshot) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var notes: [String] = []
        func note(_ text: String) {
            lock.lock()
            notes.append(text)
            lock.unlock()
        }

        var accel = AccelSummary()
        group.enter()
        accelQueue.async {
            accel = self.accelSummary(from: time.addingTimeInterval(-Self.accelWindow), to: time, note: note)
            group.leave()
        }

        var activities: [ActivitySegment] = []
        if CMMotionActivityManager.isActivityAvailable() {
            group.enter()
            // 창 시작 전에 시작해 이어지던 활동도 잡기 위해 3시간 전부터 조회한다
            activityManager.queryActivityStarting(from: time.addingTimeInterval(-3 * 60 * 60), to: time, to: motionQueue) { list, error in
                if let error {
                    note("활동 조회 실패: \(error.localizedDescription)")
                }
                let windowStart = time.addingTimeInterval(-Self.activityWindow)
                let all = list ?? []
                let ongoing = all.last { $0.startDate < windowStart }
                let inside = all.filter { $0.startDate >= windowStart }
                activities = ([ongoing].compactMap { $0 } + inside).map(ActivitySegment.init)
                group.leave()
            }
        } else {
            note("활동 인식 미지원")
        }

        var steps5m: Int?
        var steps30m: Int?
        if CMPedometer.isStepCountingAvailable() {
            group.enter()
            pedometer.queryPedometerData(from: time.addingTimeInterval(-5 * 60), to: time) { data, error in
                if let error {
                    note("걸음 수 조회 실패(5분): \(error.localizedDescription)")
                }
                steps5m = data?.numberOfSteps.intValue
                group.leave()
            }
            group.enter()
            pedometer.queryPedometerData(from: time.addingTimeInterval(-30 * 60), to: time) { data, error in
                if let error {
                    note("걸음 수 조회 실패(30분): \(error.localizedDescription)")
                }
                steps30m = data?.numberOfSteps.intValue
                group.leave()
            }
        } else {
            note("걸음 수 미지원")
        }

        group.notify(queue: .main) {
            completion(ContextSnapshot(
                windowSeconds: Self.accelWindow,
                accelSampleCount: accel.count,
                accelMagMean: accel.mean,
                accelMagStd: accel.std,
                accelMagMin: accel.min,
                accelMagMax: accel.max,
                accelMag5Hz: accel.series,
                activities: activities,
                steps5m: steps5m,
                steps30m: steps30m,
                collectedAt: Date(),
                notes: notes
            ))
        }
    }

    private func accelSummary(from start: Date, to end: Date, note: (String) -> Void) -> AccelSummary {
        guard CMSensorRecorder.isAccelerometerRecordingAvailable() else {
            note("가속도 기록 미지원")
            return AccelSummary()
        }
        guard let list = recorder.accelerometerData(from: start, to: end) else {
            note("가속도 기록 없음")
            return AccelSummary()
        }

        let binCount = Int(Self.accelWindow * Self.accelBinsPerSecond)
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        var magnitudes: [Double] = []

        for item in list {
            guard let sample = item as? CMRecordedAccelerometerData else { continue }
            let a = sample.acceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            magnitudes.append(magnitude)
            let bin = Int(sample.startDate.timeIntervalSince(start) * Self.accelBinsPerSecond)
            if bin >= 0 && bin < binCount {
                sums[bin] += magnitude
                counts[bin] += 1
            }
        }
        guard !magnitudes.isEmpty else {
            note("가속도 샘플 0개")
            return AccelSummary()
        }

        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let variance = magnitudes.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(magnitudes.count)
        var summary = AccelSummary()
        summary.count = magnitudes.count
        summary.mean = mean
        summary.std = variance.squareRoot()
        summary.min = magnitudes.min()
        summary.max = magnitudes.max()
        summary.series = zip(sums, counts).map { $1 > 0 ? Float($0 / Double($1)) : -1 }
        return summary
    }
}
