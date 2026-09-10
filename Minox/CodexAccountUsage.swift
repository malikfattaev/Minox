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
        private var partialLine = Data()
        private var responses: [Int: Data] = [:]

        func append(_ chunk: Data) -> [Int] {
            lock.lock()
            defer { lock.unlock() }

            partialLine.append(chunk)
            var ids: [Int] = []
            while let newline = partialLine.firstIndex(of: 0x0A) {
                let line = Data(partialLine[..<newline])
                partialLine.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (object["id"] as? NSNumber)?.intValue
                else { continue }
                responses[id] = line
                ids.append(id)
            }
            return ids
        }

        func response(for id: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return responses[id]
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
        let initialized = DispatchSemaphore(value: 0)
        let responseReady = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)

        process.terminationHandler = { _ in terminated.signal() }

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for id in received.append(chunk) {
                if id == 1 { initialized.signal() }
                if id == Self.responseID { responseReady.signal() }
            }
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

            guard initialized.wait(timeout: .now() + .seconds(5)) == .success else {
                finish(process, input: input.fileHandleForWriting, terminated: terminated)
                output.fileHandleForReading.readabilityHandler = nil
                return nil
            }

            try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
            try send(["method": "account/usage/read", "id": Self.responseID], to: input.fileHandleForWriting)
            guard responseReady.wait(timeout: .now() + .seconds(5)) == .success else {
                finish(process, input: input.fileHandleForWriting, terminated: terminated)
                output.fileHandleForReading.readabilityHandler = nil
                return nil
            }
        } catch {
            finish(process, input: input.fileHandleForWriting, terminated: terminated)
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        output.fileHandleForReading.readabilityHandler = nil
        finish(process, input: input.fileHandleForWriting, terminated: terminated)

        guard let response = received.response(for: Self.responseID) else { return nil }
        return parse(response)
    }

    private func finish(_ process: Process, input: FileHandle, terminated: DispatchSemaphore) {
        try? input.close()
        guard process.isRunning else { return }
        if terminated.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
            process.terminate()
        }
        if process.isRunning { process.waitUntilExit() }
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
