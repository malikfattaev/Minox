import Foundation

/// Таймер рабочей сессии: задаёшь длительность и следишь за остатком.
/// Ничего не уведомляет — просто честно считает время.
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(until: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    /// Границы и шаги настройки длительности.
    private enum Length {
        static let minimum: TimeInterval = 5 * 60
        static let maximum: TimeInterval = 8 * 3600
        static let `default`: TimeInterval = 3600
        /// Шаг зависит от масштаба: внутри часа удобнее по пять минут,
        /// дальше — по пятнадцать, иначе до восьми часов сотня щелчков.
        static let fine: TimeInterval = 5 * 60
        static let coarse: TimeInterval = 15 * 60
        static let stepBoundary: TimeInterval = 3600
    }

    private enum Key {
        static let duration = "focusTimerDuration"
        static let deadline = "focusTimerDeadline"
        static let paused = "focusTimerPausedRemaining"
    }

    /// Отсчёт переживает перезапуск приложения: сессия идёт по стенным часам,
    /// и терять её из-за выхода из Minox было бы странно.
    @Published private(set) var phase: Phase = .idle { didSet { persist() } }
    @Published private(set) var duration: TimeInterval
    /// Тикает раз в секунду, пока идёт отсчёт: по нему вью пересчитывает остаток.
    @Published private(set) var now = Date()

    private let defaults: UserDefaults
    private var ticker: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Key.duration)
        duration = stored > 0 ? Self.clamped(stored) : Length.default
        // Присваивание в init не дёргает didSet — восстановленное состояние
        // не перезаписывает само себя.
        phase = Self.storedPhase(in: defaults, now: now)
        if isRunning { startTicking() }
    }

    private static func storedPhase(in defaults: UserDefaults, now: Date) -> Phase {
        if let remaining = defaults.object(forKey: Key.paused) as? Double, remaining > 0 {
            return .paused(remaining: remaining)
        }
        guard let deadline = defaults.object(forKey: Key.deadline) as? Double else { return .idle }
        let until = Date(timeIntervalSince1970: deadline)
        return until > now ? .running(until: until) : .finished
    }

    private func persist() {
        switch phase {
        case .running(let until):
            defaults.set(until.timeIntervalSince1970, forKey: Key.deadline)
            defaults.removeObject(forKey: Key.paused)
        case .paused(let remaining):
            defaults.set(remaining, forKey: Key.paused)
            defaults.removeObject(forKey: Key.deadline)
        case .idle, .finished:
            defaults.removeObject(forKey: Key.deadline)
            defaults.removeObject(forKey: Key.paused)
        }
    }

    // MARK: Состояние для вью

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Длительность меняем только до старта — на ходу это сбивало бы отсчёт.
    var canConfigure: Bool { phase == .idle || phase == .finished }
    var canIncrease: Bool { canConfigure && duration < Length.maximum }
    var canDecrease: Bool { canConfigure && duration > Length.minimum }

    var remaining: TimeInterval {
        switch phase {
        case .idle, .finished: return duration
        case .running(let until): return max(0, until.timeIntervalSince(now))
        case .paused(let remaining): return remaining
        }
    }

    /// Доля пройденного, 0…1.
    var progress: Double {
        switch phase {
        case .idle: return 0
        case .finished: return 1
        default: return duration > 0 ? min(1, max(0, 1 - remaining / duration)) : 0
        }
    }

    // MARK: Команды

    func adjust(up: Bool) {
        guard canConfigure else { return }
        let step = duration < Length.stepBoundary || (!up && duration <= Length.stepBoundary)
            ? Length.fine
            : Length.coarse

        phase = .idle
        duration = Self.clamped(duration + (up ? step : -step))
        defaults.set(duration, forKey: Key.duration)
    }

    func start() {
        now = Date()
        phase = .running(until: now.addingTimeInterval(duration))
        startTicking()
    }

    func pause() {
        guard case .running = phase else { return }
        phase = .paused(remaining: remaining)
        stopTicking()
    }

    func resume() {
        guard case .paused(let remaining) = phase else { return }
        now = Date()
        phase = .running(until: now.addingTimeInterval(remaining))
        startTicking()
    }

    func reset() {
        phase = .idle
        stopTicking()
    }

    // MARK: Отсчёт

    /// Остаток всегда считается от даты окончания, поэтому тик нужен только
    /// для того, чтобы вью перерисовалась — за точность он не отвечает.
    private func startTicking() {
        stopTicking()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 0.1
        // .common — иначе отсчёт замирает, пока курсор ведут по панели.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        guard case .running(let until) = phase, until <= now else { return }
        phase = .finished
        stopTicking()
    }

    private static func clamped(_ duration: TimeInterval) -> TimeInterval {
        min(max(duration, Length.minimum), Length.maximum)
    }
}
