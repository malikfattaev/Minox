import Foundation

// MARK: - Публичная модель

struct ProviderStats {
    var today: Int = 0
    var allTime: Int = 0
    /// Доля израсходованного лимита, 0…1.
    var limit: Double = 0
    /// Когда лимит обнулится. nil — неизвестно.
    var resetsAt: Date?
    /// true — процент пришёл от самого провайдера, а не посчитан нами.
    var limitIsReported = false
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codex = ProviderStats()
    @Published private(set) var claude = ProviderStats()
    @Published private(set) var isScanning = false
    @Published private(set) var isPopoverVisible = false

    /// Claude не публикует лимиты локально (cachedUsageUtilization в ~/.claude.json
    /// заморожен). Считаем сами и калибруем по /status: 132.7M токенов в блоке = 20%.
    static let claudeWindowBudget = 660_000_000
    static let claudeWindowLength: TimeInterval = 5 * 3600

    /// Лимит Claude живёт фиксированными блоками: окно открывается первым запросом
    /// и держится 5 часов, следующий блок начинается со следующего запроса после конца.
    /// Именно так считает /status, поэтому скользящее окно тут не подходит.
    static func currentBlock(minutes: [Int: Int], length: TimeInterval, now: Date) -> (start: Date, tokens: Int)? {
        let ordered = minutes.keys.sorted()
        guard let first = ordered.first else { return nil }

        let span = Int(length) / 60
        var blockStart = first
        var tokens = 0
        for minute in ordered {
            if minute >= blockStart + span {
                blockStart = minute
                tokens = 0
            }
            tokens += minutes[minute] ?? 0
        }

        let start = Date(timeIntervalSince1970: TimeInterval(blockStart * 60))
        guard now.timeIntervalSince(start) < length else { return nil }
        return (start, tokens)
    }

    private var lastScan: Date?
    private let scanner = UsageScanner()

    func refreshIfStale(maxAge: TimeInterval = 30) {
        if let last = lastScan, Date().timeIntervalSince(last) < maxAge { return }
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        Task.detached(priority: .utility) { [scanner] in
            let result = scanner.scan()
            let codexUsage = CodexAccountUsageClient().read()
            let limits = await ClaudeUsageAPI.fetch()
            await MainActor.run { [weak self] in
                self?.apply(result, codexUsage: codexUsage, limits: limits)
            }
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
    }

    private func apply(
        _ result: ScanResult,
        codexUsage: CodexAccountUsage?,
        limits: ClaudeUsageAPI.Limits?
    ) {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)

        codex = ProviderStats(
            today: codexUsage?.tokensToday(now: now) ?? result.codex.total(since: dayStart),
            allTime: codexUsage?.lifetimeTokens ?? result.codex.grandTotal,
            limit: result.codexLimit?.usedFraction ?? 0,
            resetsAt: result.codexLimit?.resetsAt,
            limitIsReported: result.codexLimit != nil
        )

        var claudeStats = ProviderStats(
            today: result.claude.total(since: dayStart),
            allTime: result.claude.grandTotal
        )
        if let limits {
            // Настоящие цифры по всему аккаунту.
            claudeStats.limit = min(1, max(0, limits.sessionPercent / 100))
            claudeStats.resetsAt = limits.sessionResetsAt
            claudeStats.limitIsReported = true
        } else {
            // Запасной путь: оценка по логам этой машины. Занижает, если работал
            // с другого устройства, — зато не врёт про недоступность.
            let block = Self.currentBlock(minutes: result.claudeMinutes, length: Self.claudeWindowLength, now: now)
            claudeStats.limit = min(1, Double(block?.tokens ?? 0) / Double(Self.claudeWindowBudget))
            claudeStats.resetsAt = block?.start.addingTimeInterval(Self.claudeWindowLength)
        }
        claude = claudeStats
        NSLog("Minox: Claude \(Int(claudeStats.limit * 100))% "
            + (claudeStats.limitIsReported ? "(из API)" : "(оценка по логам)"))

        isScanning = false
        lastScan = Date()
    }
}

// MARK: - Результат скана

/// Токены разложены по часовым корзинам: этого хватает и для «сегодня»,
/// и для скользящего окна, и хранить компактно.
struct HourBuckets: Codable {
    var hours: [Int: Int] = [:]
    var grandTotal: Int = 0

    mutating func add(_ tokens: Int, at epoch: Int) {
        hours[epoch / 3600, default: 0] += tokens
        grandTotal += tokens
    }

    func total(since date: Date) -> Int {
        let from = Int(date.timeIntervalSince1970) / 3600
        return hours.reduce(0) { $1.key >= from ? $0 + $1.value : $0 }
    }
}

struct CodexLimit {
    let usedPercent: Double
    let resetsAt: Date?
    var usedFraction: Double { min(1, max(0, usedPercent / 100)) }
}

struct ScanResult {
    var claude = HourBuckets()
    var codex = HourBuckets()
    /// Поминутная разбивка последних суток — нужна, чтобы точно найти границу блока.
    var claudeMinutes: [Int: Int] = [:]
    var codexLimit: CodexLimit?
}
