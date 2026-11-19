import Foundation

/// 기기 안에서 응답 하나마다 바로 갱신하는 로지스틱 회귀.
/// 시작 가중치는 공개 데이터(MPU)와 내 데이터 47개로 학습한 개인화 모델(InitialModel.swift).
final class OnlineModel: ObservableObject {
    static let shared = OnlineModel()

    struct State: Codable {
        var features: [String]
        var impute: [Double]
        var mean: [Double]
        var scale: [Double]
        var coef: [Double]
        var intercept: Double
        var theta: Double
        var updates: Int = 0
        var trainedOn: String = ""
    }

    /// 학습률과, 시작 가중치에서 너무 멀어지지 않게 하는 정도
    static let learningRate = 0.1
    static let l2 = 0.01

    @Published private(set) var state: State
    let initial: State

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("righttime-model.json")

    private init() {
        let start = Self.loadInitial()
        initial = start
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("righttime-model.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(State.self, from: data),
           saved.features == start.features, saved.trainedOn == start.trainedOn {
            state = saved
        } else {
            state = start
        }
    }

    private static func loadInitial() -> State {
        State(features: InitialModel.features, impute: InitialModel.impute, mean: InitialModel.mean,
              scale: InitialModel.scale, coef: InitialModel.coef, intercept: InitialModel.intercept,
              theta: InitialModel.theta, trainedOn: InitialModel.trainedOn)
    }

    var theta: Double { state.theta }

    private func standardized(_ x: [Double?]) -> [Double] {
        x.enumerated().map { i, v in
            let value = v ?? state.impute[i]
            let s = state.scale[i] == 0 ? 1 : state.scale[i]
            return (value - state.mean[i]) / s
        }
    }

    private static func sigmoid(_ v: Double) -> Double { 1 / (1 + exp(-v)) }

    func predict(_ x: [Double?]) -> Double {
        let z = standardized(x)
        let logit = zip(state.coef, z).reduce(state.intercept) { $0 + $1.0 * $1.1 }
        return Self.sigmoid(logit)
    }

    /// 샘플 하나로 SGD 한 걸음. 갱신 전후 예측값을 돌려준다.
    @discardableResult
    func update(_ x: [Double?], label y: Int) -> (before: Double, after: Double) {
        let before = predict(x)
        let z = standardized(x)
        let g = before - Double(y)
        for i in state.coef.indices {
            state.coef[i] -= Self.learningRate * (g * z[i] + Self.l2 * (state.coef[i] - initial.coef[i]))
        }
        state.intercept -= Self.learningRate * g
        state.updates += 1
        save()
        return (before, predict(x))
    }

    func reset() {
        state = initial
        save()
    }

    /// 시작 가중치 대비 가장 많이 바뀐 특징
    struct WeightChange: Identifiable {
        var name: String
        var initial: Double
        var now: Double
        var id: String { name }
    }

    func biggestChanges(_ count: Int) -> [WeightChange] {
        let all = state.features.indices.map { i in
            WeightChange(name: Features.koreanNames[state.features[i]] ?? state.features[i],
                         initial: initial.coef[i], now: state.coef[i])
        }
        return Array(all.sorted { abs($0.now - $0.initial) > abs($1.now - $1.initial) }.prefix(count))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL)
        }
    }
}
