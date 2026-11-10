import Foundation

// Xcode 콘솔이 없으므로 앱 안에서 로그를 보고, 재실행해도 남도록 저장한다.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var lines: [String]
    private let key = "logLines"

    private init() {
        lines = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 앱이 화면을 띄우기 전에 꺼져도 로그를 볼 수 있도록 Documents에도 바로 쓴다 (iTunes 파일 공유로 확인).
    private static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("righttime-log.txt")
    private static let fileLock = NSLock()

    func add(_ text: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        Self.appendToFile("[\(stamp)] \(text)\n")
        DispatchQueue.main.async {
            self.lines.insert("[\(stamp)] \(text)", at: 0)
            UserDefaults.standard.set(self.lines, forKey: self.key)
        }
    }

    private static func appendToFile(_ line: String) {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines = []
            UserDefaults.standard.removeObject(forKey: self.key)
        }
    }
}
