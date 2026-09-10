import Foundation

/// Статистика всего аккаунта Codex. Локальные JSONL не содержат cloud-задачи,
/// работу с других устройств и удалённые сессии.
struct CodexAccountUsage {
    let lifetimeTokens: Int
    let dailyTokens: [String: Int]

    func tokensToday(now: Date = Date()) -> Int? {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        return dailyTokens[date]
    }
}

/// Читает account/usage/read через установленный Codex и его текущую авторизацию.
final class CodexAccountUsageClient: @unchecked Sendable {
    private static let responseID = 2

    private final class ResponseBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var didSignal = false

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            guard data.range(of: Data("\"id\":2,\"result\"".utf8)) != nil, !didSignal else { return false }
            didSignal = true
            return true
        }

        var snapshot: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    func read() -> CodexAccountUsage? {
        guard let executable = executableURL() else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let received = ResponseBuffer()
        let responseReady = DispatchSemaphore(value: 0)

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if received.append(chunk) { responseReady.signal() }
        }

        do {
            try process.run()
            try send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": ["name": "minox", "title": "Minox", "version": "0.1"]
                ]
            ], to: input.fileHandleForWriting)

            // app-server принимает initialized после завершения initialize.
            Thread.sleep(forTimeInterval: 0.1)
            try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
            try send(["method": "account/usage/read", "id": Self.responseID], to: input.fileHandleForWriting)
            _ = responseReady.wait(timeout: .now() + .seconds(5))
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        return parse(received.snapshot)
    }

    private func executableURL() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func parse(_ data: Data) -> CodexAccountUsage? {
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == Self.responseID,
                  let result = object["result"] as? [String: Any],
                  let summary = result["summary"] as? [String: Any],
                  let lifetime = (summary["lifetimeTokens"] as? NSNumber)?.intValue
            else { continue }

            let daily = (result["dailyUsageBuckets"] as? [[String: Any]] ?? []).reduce(into: [String: Int]()) {
                guard let date = $1["startDate"] as? String,
                      let tokens = ($1["tokens"] as? NSNumber)?.intValue
                else { return }
                $0[date] = tokens
            }
            return CodexAccountUsage(lifetimeTokens: lifetime, dailyTokens: daily)
        }
        return nil
    }
}
