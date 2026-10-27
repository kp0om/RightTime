import Foundation

// Xcode 콘솔이 없으므로 앱 안에서 로그를 보고, 재실행해도 남도록 저장한다.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var lines: [String]
    private let key = "logLines"

    private init() {
        lines = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ text: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        DispatchQueue.main.async {
            self.lines.insert("[\(stamp)] \(text)", at: 0)
            UserDefaults.standard.set(self.lines, forKey: self.key)
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines = []
            UserDefaults.standard.removeObject(forKey: self.key)
        }
    }
}
