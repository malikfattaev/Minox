import AppKit
import ServiceManagement
import SwiftUI

@main
enum Minox {
    /// NSApplication.delegate — weak, поэтому держим сильную ссылку здесь.
    @MainActor private static let delegate = AppDelegate()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - Status item + panel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PopoverPanel!
    private var hosting: NSHostingView<UsagePopover>!
    private var outsideClickMonitor: Any?
    private var isClosing = false
    private let store = UsageStore()
    private var footer: NSHostingView<FooterCard>!
    private var container: NSView!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.refresh()
        registerLoginItem()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Размер по умолчанию у sparkle мелковат рядом с иконками других
        // приложений, поэтому задаём его явно.
        // isTemplate: меню-бар сам перекрасит под светлую/тёмную тему.
        let icon = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Minox")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        hosting = makeCard(UsagePopover(store: store))
        footer = makeCard(FooterCard(
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        ))
        container = NSView()
        container.addSubview(hosting)
        container.addSubview(footer)

        panel = PopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.popoverWidth, height: Metrics.popoverWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Автозапуск включаем сам, но не навязываемся.
    /// .notFound — нас в системе ещё/уже нет (первый запуск или переустановка
    /// бандла), тут регистрируемся всегда. .notRegistered — либо первый запуск,
    /// либо пользователь снял галку сам: во втором случае не лезем.
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        let key = "didRegisterLoginItem"

        switch service.status {
        case .enabled:
            return
        case .notRegistered where UserDefaults.standard.bool(forKey: key):
            return
        default:
            break
        }

        UserDefaults.standard.set(true, forKey: key)
        do {
            try service.register()
        } catch {
            NSLog("Minox: не удалось включить автозапуск — \(error.localizedDescription)")
        }
    }

    @objc private func togglePanel() {
        (panel.isVisible && !isClosing) ? closePanel() : openPanel()
    }

    /// NSGlassEffectView под контентом прямоугольный по bounds, поэтому каждую
    /// карточку скругляем на уровне слоя — SwiftUI-шейп его не обрезает.
    private func makeCard<V: View>(_ view: V) -> NSHostingView<V> {
        let card = NSHostingView(rootView: view)
        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        return card
    }

    /// Раскладываем карточки снизу вверх: у AppKit начало координат внизу.
    private func layoutCards() -> NSSize {
        let top = hosting.fittingSize
        let bottom = footer.fittingSize
        let width = max(top.width, bottom.width)
        let total = NSSize(width: width, height: top.height + Metrics.cardGap + bottom.height)

        container.frame = NSRect(origin: .zero, size: total)
        footer.frame = NSRect(x: 0, y: 0, width: width, height: bottom.height)
        hosting.frame = NSRect(x: 0, y: bottom.height + Metrics.cardGap, width: width, height: top.height)
        return total
    }

    private func showSettings() {
        closePanel()

        if settingsWindow == nil {
            let size = NSSize(width: 720, height: 460)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Minox"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false

            // window.center() ставит окно выше середины — центрируем сами.
            if let screen = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: (screen.midX - size.width / 2).rounded(),
                    y: (screen.midY - size.height / 2).rounded()
                ))
            }
            settingsWindow = window
        }

        // Политика .accessory не даёт окну фокус сама по себе.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        store.refreshIfStale()

        let size = layoutCards()
        panel.setContentSize(size)

        // Центрируем панель ровно по центру кнопки в меню-баре.
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - size.width / 2
        let y = buttonFrame.minY - size.height - Metrics.panelGap

        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }

        // Выезжает из-под меню-бара: стартуем чуть выше и гасим прозрачностью.
        isClosing = false
        store.setPopoverVisible(true)
        let finalFrame = NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
        var startFrame = finalFrame
        startFrame.origin.y += Metrics.appearOffset

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        statusItem.button?.highlight(true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        store.setPopoverVisible(false)

        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        statusItem.button?.highlight(false)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isClosing else { return }
                self.panel.orderOut(nil)
                self.isClosing = false
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }
}

final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Metrics

private enum Metrics {
    static let popoverWidth: CGFloat = 238
    static let cornerRadius: CGFloat = 16
    static let cardGap: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let panelGap: CGFloat = 8
    static let appearOffset: CGFloat = 8
    static let appearDuration: TimeInterval = 0.17
    static let dismissDuration: TimeInterval = 0.11

    static let ringDiameter: CGFloat = 78
    static let ringLineWidth: CGFloat = 7
    static let ringLogo: CGFloat = 34
    static let ringGap: CGFloat = 40
    static let ringSectionTop: CGFloat = 26
    static let ringSectionBottom: CGFloat = 26
}

// MARK: - Popover

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    /// Пересчитывает «resets in …», пока панель открыта.
    @State private var now = Date()

    private var usages: [ProviderUsage] {
        [
            ProviderUsage(provider: .codex, stats: store.codex, now: now),
            ProviderUsage(provider: .claude, stats: store.claude, now: now)
        ]
    }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.ringGap) {
                ForEach(usages) { usage in
                    UsageRing(usage: usage)
                }
            }
            .padding(.top, Metrics.ringSectionTop)
            .padding(.bottom, Metrics.ringSectionBottom)

            SectionDivider()

            VStack(spacing: 0) {
                ForEach(usages) { usage in
                    UsageRow(usage: usage)
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 8)
        }
        .frame(width: Metrics.popoverWidth)
        .modifier(GlassSurface(shape: shape))
        .clipShape(shape)
        .onChange(of: store.isPopoverVisible) { visible in
            if visible { now = Date() }
        }
        .task(id: store.isPopoverVisible) {
            guard store.isPopoverVisible else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, store.isPopoverVisible else { return }
                now = Date()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Нижняя карточка

struct FooterCard: View {
    let onSettings: () -> Void
    let onQuit: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            FooterButton(title: "Settings", action: onSettings)
            Spacer(minLength: 8)
            FooterButton(title: "Quit", action: onQuit)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 13)
        .frame(width: Metrics.popoverWidth)
        .modifier(GlassSurface(shape: shape))
        .clipShape(shape)
        .preferredColorScheme(.dark)
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { self.hovering = hovering }
        }
    }
}

// MARK: - Настройки

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var section: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section ?? .general {
                    case .general: GeneralPane()
                    case .claude: ClaudePane(stats: store.claude)
                    case .codex: CodexPane(stats: store.codex)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(section?.title ?? "General")
    }
}

// MARK: Разделы настроек

private struct GeneralPane: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                HStack {
                    Text("Open at Login").font(.system(size: 13))
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { openAtLogin },
                        // Показываем то, что реально ответила система, а не желаемое.
                        set: { wanted in
                            setLoginItem(wanted)
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            NSLog("Minox: не удалось переключить автозапуск — \(error.localizedDescription)")
        }
    }
}

private struct ClaudePane: View {
    let stats: ProviderStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SourceRow(
                    title: "Лимит",
                    value: stats.limitIsReported ? "Точный, из API аккаунта" : "Оценка по логам этого мака",
                    ok: stats.limitIsReported
                )
            }
            SettingsCard {
                SourceRow(title: "Токены", value: "~/.claude/projects", ok: stats.allTime > 0)
            }
        }
    }
}

private struct CodexPane: View {
    let stats: ProviderStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SourceRow(
                    title: "Лимит",
                    value: stats.limitIsReported ? "Точный, из логов Codex" : "Нет данных",
                    ok: stats.limitIsReported
                )
            }
            SettingsCard {
                SourceRow(title: "Токены", value: "~/.codex/sessions", ok: stats.allTime > 0)
            }
        }
    }
}

// MARK: Мелочи настроек

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SourceRow: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Palette.ok : Palette.warn)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 13))
    }
}

// MARK: - Ring

private struct UsageRing: View {
    let usage: ProviderUsage
    @State private var showsPercent = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: Metrics.ringLineWidth)
            Circle()
                .trim(from: 0, to: usage.limit)
                .stroke(usage.tint, style: StrokeStyle(lineWidth: Metrics.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Логотип и процент меняются местами перекрёстным затуханием.
            BrandMark(provider: usage.provider)
                .frame(width: Metrics.ringLogo, height: Metrics.ringLogo)
                .opacity(showsPercent ? 0 : 1)
                .scaleEffect(showsPercent ? 0.88 : 1)

            Text(usage.percentLabel)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(usage.tint)
                .opacity(showsPercent ? 1 : 0)
                .scaleEffect(showsPercent ? 1 : 0.88)
        }
        .frame(width: Metrics.ringDiameter, height: Metrics.ringDiameter)
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) { showsPercent = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(usage.provider.title) \(usage.percentLabel) of limit")
    }
}

// MARK: - Row

private struct UsageRow: View {
    let usage: ProviderUsage

    var body: some View {
        HStack(spacing: 11) {
            BrandMark(provider: usage.provider)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.provider.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(usage.reset)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(usage.today)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(usage.lifetime)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.vertical, 15)
    }
}

// MARK: - Chrome

/// Нативное стекло: Liquid Glass на macOS 26+, материал — на более старых.
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // У Liquid Glass своя кромка — свою не рисуем, иначе двойная обводка.
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
    }
}

private struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
    }
}

private struct BrandMark: View {
    let provider: Provider

    var body: some View {
        if let image = provider.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}

private enum Palette {
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.39)        // запас есть
    static let warn = Color(red: 1.00, green: 0.72, blue: 0.16)      // больше половины съедено
    static let critical = Color(red: 1.00, green: 0.31, blue: 0.27)  // почти всё
}

// MARK: - Model

private struct ProviderUsage: Identifiable {
    let provider: Provider
    let stats: ProviderStats
    let now: Date

    var id: Provider { provider }
    var limit: Double { stats.limit }
    var today: String { TokenFormat.short(stats.today) }
    var lifetime: String { TokenFormat.short(stats.allTime) }
    var percentLabel: String { "\(Int((stats.limit * 100).rounded()))%" }

    var reset: String {
        guard let resetsAt = stats.resetsAt else { return "no limit data" }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return "limit reset" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    var tint: Color {
        switch stats.limit {
        case ..<0.60: return Palette.ok
        case ..<0.85: return Palette.warn
        default: return Palette.critical
        }
    }
}

enum TokenFormat {
    static func short(_ tokens: Int) -> String {
        let value: Double, suffix: String
        switch tokens {
        case 1_000_000_000...: (value, suffix) = (Double(tokens) / 1e9, "B")
        case 1_000_000...:     (value, suffix) = (Double(tokens) / 1e6, "M")
        case 1_000...:         (value, suffix) = (Double(tokens) / 1e3, "K")
        default:               return "\(tokens)"
        }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f%@", value, suffix)
    }
}

private enum Provider: Hashable {
    case codex
    case claude

    var title: String { self == .codex ? "Codex" : "Claude" }
    var assetName: String { self == .codex ? "codex-mark" : "claude-mark" }

    /// body вызывается часто — декодировать PNG каждый раз нельзя.
    private static let images: [Provider: NSImage] = {
        var loaded: [Provider: NSImage] = [:]
        for provider in [Provider.codex, .claude] {
            if let url = Bundle.module.url(forResource: provider.assetName, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                loaded[provider] = image
            }
        }
        return loaded
    }()

    var image: NSImage? { Self.images[self] }
}
