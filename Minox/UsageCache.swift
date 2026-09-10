import Foundation

// MARK: - Построчное чтение с offset

enum LineReader {
    /// Вызывает body для каждой полной строки начиная с offset.
    /// Возвращает новый offset — ровно за последним переводом строки,
    /// чтобы недописанный хвост файла перечитался в следующий раз.
    static func forEachLine(path: String, from offset: UInt64, _ body: (Data) -> Void) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return offset }

        var consumed = offset
        var carry = Data()

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                if carry.isEmpty {
                    body(chunk[start..<newline])
                } else {
                    carry.append(chunk[start..<newline])
                    body(carry)
                    carry.removeAll(keepingCapacity: true)
                }
                consumed += UInt64(newline - start + 1)
                start = newline + 1
            }
            if start < chunk.endIndex { carry.append(chunk[start...]) }
        }
        return consumed
    }
}

// MARK: - Разбор времени

enum ISO {
    /// Оба провайдера пишут UTC вида 2026-09-06T22:25:45.040Z.
    /// DateFormatter на десятках тысяч строк слишком дорог, считаем руками.
    static func epoch(_ text: String) -> Int? {
        let u = Array(text.utf8)
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58
        else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                let digit = Int(u[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        // Гражданская дата → дни от эпохи (алгоритм Хиннанта).
        let shifted = year - (month <= 2 ? 1 : 0)
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468

        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }
}

// MARK: - Множество уже учтённых записей

/// Храним 64-битные хэши id вместо строк: 40k записей — это 320 КБ вместо мегабайтов.
struct IDSet {
    private var hashes: Set<UInt64>

    init(packed: Data) {
        var set = Set<UInt64>()
        set.reserveCapacity(packed.count / 8)
        packed.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: UInt64.self) { set.insert(UInt64(littleEndian: value)) }
        }
        hashes = set
    }

    /// false — такой id уже встречался.
    mutating func insert(_ id: String) -> Bool {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hashes.insert(hash).inserted
    }

    var packed: Data {
        var out = Data(capacity: hashes.count * 8)
        for hash in hashes { withUnsafeBytes(of: hash.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }
}

// MARK: - Кэш на диске

struct FileState: Codable {
    var offset: UInt64 = 0
    var size: UInt64 = 0
    /// Codex: берём token_usage_record (true) или приросты total_token_usage (false).
    var usesRecords: Bool?
    /// Codex: последнее накопительное значение для расчёта прироста.
    var carry: Int = 0
}

struct CodexWindowState: Codable {
    var percent: Double
    var resetsAt: Double?
    var epoch: Int
}

struct Cache: Codable {
    var version = 4
    var files: [String: FileState] = [:]
    var claude = HourBuckets()
    var codex = HourBuckets()
    /// epoch/60 → токены. Держим только последние 72 часа: этого хватает,
    /// чтобы цепочка 5-часовых блоков успела переякориться на паузе в работе.
    var claudeMinutes: [Int: Int] = [:]
    var ids = Data()
    /// Codex ведёт несколько независимых наборов лимитов и различает их по
    /// limit_id: общий, отдельный на Codex-Spark и так далее. Внутри набора
    /// окна ещё и разной длины, поэтому ключ — пара limit_id и длины окна.
    /// По одной длине наборы затирали бы друг друга.
    var codexWindows: [String: CodexWindowState] = [:]

    var result: ScanResult {
        var out = ScanResult()
        out.claude = claude
        out.codex = codex
        out.claudeMinutes = claudeMinutes
        // Показываем самый жёсткий из действующих лимитов — упрётся он первым.
        // Окна, чьё время сброса уже прошло, в расчёт не берём.
        let now = Date().timeIntervalSince1970
        if let worst = codexWindows.values
            .filter({ ($0.resetsAt ?? .greatestFiniteMagnitude) > now })
            .max(by: { $0.percent < $1.percent }) {
            out.codexLimit = CodexLimit(
                usedPercent: worst.percent,
                resetsAt: worst.resetsAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return out
    }

    /// Свежее состояние каждого окна храним отдельно, а не одно последнее.
    mutating func noteCodexLimit(_ limits: [String: Any], at epoch: Int) {
        let limitID = limits["limit_id"] as? String ?? "default"
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let minutes = (window["window_minutes"] as? NSNumber)?.intValue,
                  let percent = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let id = "\(limitID)|\(minutes)"
            if let known = codexWindows[id], known.epoch > epoch { continue }
            codexWindows[id] = CodexWindowState(
                percent: percent,
                resetsAt: (window["resets_at"] as? NSNumber)?.doubleValue,
                epoch: epoch
            )
        }
    }

    /// Файл усох или исчез — значит логи переписали, инкремент больше не сходится.
    func needsRebuild(against present: [String]) -> Bool {
        if version != 4 { return true }
        let existing = Set(present)
        for (path, state) in files {
            guard existing.contains(path) else { return true }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.uint64Value
            if let size, size < state.size { return true }
        }
        return false
    }

    // MARK: Персистентность

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage-cache.json")
    }

    static func load() -> Cache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return Cache() }
        return cache
    }

    mutating func pruneMinutes(now: Date = Date()) {
        let cutoff = Int(now.timeIntervalSince1970) / 60 - 72 * 60
        claudeMinutes = claudeMinutes.filter { $0.key >= cutoff }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

extension HourBuckets {
    mutating func merge(_ other: HourBuckets) {
        for (hour, tokens) in other.hours { hours[hour, default: 0] += tokens }
        grandTotal += other.grandTotal
    }
}
