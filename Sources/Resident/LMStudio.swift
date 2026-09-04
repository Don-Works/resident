import Foundation

/// LM Studio, read the cheap way.
///
/// `lms ps --json` reports everything but takes three to eight seconds — it spawns a
/// 65 MB Node binary to open a websocket. That cannot sit in a five-second sample loop.
/// So the loop uses the REST endpoint (about 8 ms) for which models are loaded, and the
/// on-disk model index for their sizes. Activity and TTL, which only `lms` knows, are
/// refreshed on a slow background cadence and merged in.
final class LMStudio: ModelRuntime {
    let name = "LM Studio"
    private let base = "http://localhost:1234"
    private let index = ModelIndex()
    private let enrichment = Enrichment()
    private let stream: LMStudioStream
    /// Whether to hold the `lms log stream` process open. Long-running modes only.
    private let live: Bool

    init(live: Bool = false) {
        self.live = live
        stream = LMStudioStream(live: live)
    }

    func isPresent() -> Bool { Probe.get(base + "/api/v0/models", timeout: 0.4) != nil }

    func loadedModels() -> [LoadedModel] {
        guard let root = Probe.json(base + "/api/v0/models") as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [] }

        let loaded = entries.filter { ($0["state"] as? String) == "loaded" }
        enrichment.refreshIfNeeded(identifiers: loaded.compactMap { $0["id"] as? String })
        if live { stream.ensureRunning() }
        reconcile(stream.snapshot())
        let activity = stream.snapshot()
        let streaming = stream.isConnected
        // While the stream is open it is the authority on what is generating: it sees
        // every start and finish, and `lms ps` is polled once a minute. The exception
        // is a prediction already running when the stream connected — no start event,
        // and only `lms ps` knows. Believe it when it was asked after the last finish
        // the stream saw on that model.
        let polled = enrichment.refreshedAt?.timeIntervalSince1970 ?? 0

        return loaded.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let detail = enrichment.detail(for: id)
            let reading = activity.latest[id]
            var inFlight = activity.inFlight(id)
            if inFlight == 0, detail?.activity == .generating,
               polled > (activity.finished[id] ?? 0) {
                inFlight = 1
            }

            return LoadedModel(
                runtime: name,
                identifier: id,
                displayName: detail?.displayName ?? index.displayName(for: id) ?? id,
                sizeBytes: detail?.sizeBytes ?? index.size(for: id) ?? 0,
                quantisation: entry["quantization"] as? String,
                parameters: detail?.parameters ?? index.parameters(for: id),
                architecture: entry["arch"] as? String,
                kind: entry["type"] as? String,
                contextLength: entry["loaded_context_length"] as? Int,
                maxContextLength: entry["max_context_length"] as? Int,
                activity: inFlight > 0 ? .generating
                    : (streaming ? .idle : (detail?.activity ?? .loaded)),
                timeToLive: detail?.timeToLive,
                tokensPerSecond: reading?.tokensPerSecond,
                measuredAt: reading?.at,
                promptTokens: reading?.promptTokens,
                timeToFirstToken: reading?.timeToFirstToken,
                inFlight: inFlight
            )
        }
    }

    /// Fetches the slow detail synchronously. One-shot commands use this when they are
    /// asked for exact per-model activity rather than whatever the cache holds.
    func refreshDetail() { enrichment.refreshBlocking() }

    func stop() { stream.stop() }

    /// A start the stream saw with no finish — a request cancelled while queued, or an
    /// event this does not know — would show the model generating for an hour. `lms ps`
    /// polled after the start and reporting idle settles it.
    private func reconcile(_ activity: LMStudioStream.State) {
        guard let polled = enrichment.refreshedAt?.timeIntervalSince1970 else { return }
        for (id, starts) in activity.started {
            guard let oldest = starts.min(), polled > oldest + 30,
                  enrichment.detail(for: id)?.activity == .idle else { continue }
            stream.clearInFlight(id)
        }
    }

    func unload(_ model: LoadedModel) -> String? {
        guard let lms = Probe.locate([
            NSHomeDirectory() + "/.lmstudio/bin/lms",
            "/usr/local/bin/lms",
            "/opt/homebrew/bin/lms",
        ]) else { return "the lms CLI was not found" }

        guard Probe.run(lms, ["unload", model.identifier], timeout: 30) != nil else {
            return "lms unload exited non-zero"
        }
        enrichment.invalidate()
        return nil
    }
}

/// LM Studio's own model catalogue, which carries exact weight sizes. Re-read only when
/// the file changes, so a steady state costs one `stat` per sample.
private final class ModelIndex {
    private struct Entry {
        var sizeBytes: Int
        var displayName: String?
        var parameters: String?
    }

    private let path = NSHomeDirectory() + "/.lmstudio/.internal/model-index-cache.json"
    private var entries: [String: Entry] = [:]
    private var mtime: Date?
    private let lock = NSLock()

    func size(for id: String) -> Int? { lookup(id)?.sizeBytes }
    func displayName(for id: String) -> String? { lookup(id)?.displayName }
    func parameters(for id: String) -> String? { lookup(id)?.parameters }

    private func lookup(_ id: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChanged()
        return entries[id.lowercased()]
    }

    private func reloadIfChanged() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date
        guard modified != mtime else { return }
        mtime = modified

        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return }

        entries.removeAll(keepingCapacity: true)
        for model in models {
            guard let size = model["sizeBytes"] as? Int else { continue }
            let entry = Entry(
                sizeBytes: size,
                displayName: model["displayName"] as? String,
                parameters: model["params"] as? String
            )
            // One model answers to several names: the indexed path, the short default,
            // and every alias LM Studio generated. The REST API may return any of them.
            var keys = [model["indexedModelIdentifier"], model["defaultIdentifier"]]
                .compactMap { $0 as? String }
            keys += (model["autoIdentifiers"] as? [String]) ?? []
            for key in keys { entries[key.lowercased()] = entry }
        }
    }
}

/// The slow `lms ps --json` call, kept off the sampling path.
///
/// Activity and TTL are the only facts `lms` knows and the REST API does not, and it
/// costs three to eight seconds to ask because it spawns Node to open a websocket. So
/// it is fetched in the background, and the answer is written to a cache file that
/// every Resident process shares — a `resident status` run gets the menu bar app's
/// most recent answer instantly instead of paying for its own.
private final class Enrichment {
    struct Detail: Codable {
        var displayName: String?
        var sizeBytes: Int?
        var parameters: String?
        var activity: LoadedModel.Activity
        var timeToLive: TimeInterval?
    }

    private struct Cache: Codable {
        var ts: Double
        var details: [String: Detail]
    }

    private var details: [String: Detail] = [:]
    private var lastRefresh: Date?
    private var lastIdentifiers: Set<String> = []
    private var refreshing = false
    private var loadedFromDisk = false
    private let lock = NSLock()
    private let interval: TimeInterval = 60
    /// Beyond this the cached activity is too old to be worth showing.
    private let cacheLifetime: TimeInterval = 300

    private static let cachePath: String = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("co.revitt.resident", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("lmstudio-ps.json").path
    }()

    func detail(for id: String) -> Detail? {
        lock.lock()
        defer { lock.unlock() }
        if !loadedFromDisk { loadedFromDisk = true; loadCache() }
        return details[id]
    }

    /// When `lms ps` last answered, so a caller can tell whether its word postdates
    /// something the stream saw. A failed fetch does not count.
    var refreshedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastSuccess
    }
    private var lastSuccess: Date?

    func invalidate() {
        lock.lock()
        lastRefresh = nil
        lock.unlock()
    }

    /// Fetches now and waits. Used by one-shot CLI commands asked for exact state.
    func refreshBlocking() {
        let asked = Date()
        guard let parsed = fetch() else { return }
        lock.lock()
        details = parsed
        lastRefresh = Date()
        lastSuccess = asked
        loadedFromDisk = true
        lock.unlock()
        saveCache(parsed)
    }

    /// Refreshes when a minute has passed or the set of loaded models changed — a load
    /// or unload is exactly when stale activity data would be most wrong.
    func refreshIfNeeded(identifiers: [String]) {
        lock.lock()
        let set = Set(identifiers)
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > interval } ?? true
        let changed = set != lastIdentifiers
        guard !refreshing, stale || changed else { lock.unlock(); return }
        refreshing = true
        lastIdentifiers = set
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            // The answer describes the moment it was asked, not the moment the slow
            // call returned; that is the time a caller compares against.
            let asked = Date()
            let parsed = fetch()
            lock.lock()
            if let parsed { details = parsed; loadedFromDisk = true; lastSuccess = asked }
            lastRefresh = Date()
            refreshing = false
            lock.unlock()
            if let parsed { saveCache(parsed) }
        }
    }

    private func loadCache() {
        guard let data = FileManager.default.contents(atPath: Self.cachePath),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              Date().timeIntervalSince1970 - cache.ts <= cacheLifetime else { return }
        details = cache.details
    }

    private func saveCache(_ details: [String: Detail]) {
        let cache = Cache(ts: Date().timeIntervalSince1970, details: details)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.cachePath), options: .atomic)
    }

    private func fetch() -> [String: Detail]? {
        guard let lms = Probe.locate([
            NSHomeDirectory() + "/.lmstudio/bin/lms",
            "/usr/local/bin/lms",
            "/opt/homebrew/bin/lms",
        ]), let output = Probe.run(lms, ["ps", "--json"], timeout: 25),
            let data = output.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        var result: [String: Detail] = [:]
        for row in rows {
            guard let id = row["identifier"] as? String else { continue }
            let status = (row["status"] as? String) ?? ""
            result[id] = Detail(
                displayName: row["displayName"] as? String,
                sizeBytes: row["sizeBytes"] as? Int,
                parameters: row["paramsString"] as? String,
                activity: status == "generating" ? .generating : .idle,
                timeToLive: (row["ttlMs"] as? Int).map { TimeInterval($0) / 1000 }
            )
        }
        return result
    }
}
