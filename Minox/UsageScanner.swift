import Foundation

/// Читает логи Claude Code и Codex, считает токены по часовым корзинам.
///
/// Логи append-only, поэтому храним для каждого файла байтовый offset и при
/// следующем скане дочитываем только хвост. Если файл усох или пропал —
/// полный пересбор (это дешевле, чем пытаться вычесть уже учтённое).
final class UsageScanner: @unchecked Sendable {
    private let claudeRoot = NSString(string: "~/.claude/projects").expandingTildeInPath
    private let codexRoot = NSString(string: "~/.codex/sessions").expandingTildeInPath

    func scan() -> ScanResult {
        var cache = Cache.load()

        let claudeFiles = jsonlFiles(in: claudeRoot)
        let codexFiles = jsonlFiles(in: codexRoot)
        let all = claudeFiles + codexFiles

        if cache.needsRebuild(against: all) { cache = Cache() }
        var ids = IDSet(packed: cache.ids)

        for path in claudeFiles {
            scanClaude(path: path, cache: &cache, ids: &ids)
        }
        for path in codexFiles {
            scanCodex(path: path, cache: &cache, ids: &ids)
        }

        cache.ids = ids.packed
        cache.pruneMinutes()
        cache.save()
        return cache.result
    }

    // MARK: - Claude

    private func scanClaude(path: String, cache: inout Cache, ids: inout IDSet) {
        guard let size = fileSize(path) else { return }
        var state = cache.files[path] ?? FileState()
        guard size != state.size else { return }
        if size < state.offset { state = FileState() }

        state.offset = LineReader.forEachLine(path: path, from: state.offset) { line in
            guard line.range(of: Self.usageKey) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let epoch = ISO.epoch(stamp)
            else { return }

            // 48% записей — дубликаты из форкнутых сессий, дедуп обязателен.
            if let request = obj["requestId"] as? String, !ids.insert(request) { return }

            let tokens = int(usage["input_tokens"])
                + int(usage["cache_creation_input_tokens"])
                + int(usage["cache_read_input_tokens"])
                + int(usage["output_tokens"])
            guard tokens > 0 else { return }
            cache.claude.add(tokens, at: epoch)
            cache.claudeMinutes[epoch / 60, default: 0] += tokens
        }

        state.size = size
        cache.files[path] = state
    }

    // MARK: - Codex

    private func scanCodex(path: String, cache: inout Cache, ids: inout IDSet) {
        guard let size = fileSize(path) else { return }
        var state = cache.files[path] ?? FileState()
        guard size != state.size else { return }
        if size < state.offset { state = FileState() }

        // Свежие роллауты пишут token_usage_record на каждый ответ. Старые — только
        // накопительный total_token_usage, из него берём приросты. Какой из двух
        // источников у файла, выясняется на первом проходе.
        let mode = state.usesRecords
        var records = HourBuckets()
        var deltas = HourBuckets()
        var carry = state.carry

        state.offset = LineReader.forEachLine(path: path, from: state.offset) { line in
            let hasTokens = line.range(of: Self.totalTokensKey) != nil
            let hasLimits = line.range(of: Self.rateLimitsKey) != nil
            guard hasTokens || hasLimits,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { return }

            let epoch = (obj["timestamp"] as? String).flatMap(ISO.epoch)

            if obj["type"] as? String == "token_usage_record", mode != false {
                guard let epoch,
                      let usage = payload["usage"] as? [String: Any] else { return }
                if let response = payload["response_id"] as? String, !ids.insert(response) { return }
                let tokens = int(usage["total_tokens"])
                if tokens > 0 { records.add(tokens, at: epoch) }
                return
            }

            guard payload["type"] as? String == "token_count" else { return }

            if let limits = payload["rate_limits"] as? [String: Any], let epoch {
                cache.noteCodexLimit(limits, at: epoch)
            }

            if mode != true, let epoch,
               let info = payload["info"] as? [String: Any],
               let totals = info["total_token_usage"] as? [String: Any] {
                let total = int(totals["total_tokens"])
                // Счётчик сбрасывается при компакции — тогда берём значение как есть.
                let delta = total >= carry ? total - carry : total
                carry = total
                if delta > 0 { deltas.add(delta, at: epoch) }
            }
        }

        let usesRecords = mode ?? (records.grandTotal > 0)
        cache.codex.merge(usesRecords ? records : deltas)

        state.usesRecords = usesRecords
        state.carry = carry
        state.size = size
        cache.files[path] = state
    }

    // MARK: - Helpers

    private static let usageKey = Data("\"usage\"".utf8)
    private static let totalTokensKey = Data("\"total_tokens\"".utf8)
    private static let rateLimitsKey = Data("\"rate_limits\"".utf8)

    private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.uint64Value
    }

    private func jsonlFiles(in root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        for case let rel as String in walker where rel.hasSuffix(".jsonl") {
            found.append(root + "/" + rel)
        }
        return found.sorted()
    }
}
