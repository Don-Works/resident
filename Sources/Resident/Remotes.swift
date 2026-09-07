import Foundation

/// A vLLM server somewhere else — a rented GPU box, a homelab machine — that Resident
/// reads the same way it reads a local runtime. Nothing about a remote touches this
/// Mac's memory maths: its weights live in someone else's VRAM.
///
/// Listed in `~/.config/resident/remotes.json`, one object per box. A provisioner
/// (vast-box does this) writes the entry when the box comes up and removes it when the
/// box is destroyed; a hand-written entry with just `name` and `base_url` also works.
struct Remote: Codable, Equatable, Sendable {
    var name: String
    /// OpenAI-compatible base, `http://host:port/v1`.
    var baseURL: String
    /// Prometheus page. Defaults to the base with `/v1` replaced by `/metrics`.
    var metricsURL: String?
    /// Optional sidecar that answers `GET /gpu` with the card's utilisation — the
    /// vast-box lane controller does. vLLM itself does not export it.
    var controlURL: String?
    /// Bearer for the sidecar. `/metrics` on vLLM needs none.
    var token: String?
    /// Who owns the metal. Inferred from any hostname in the entry when absent.
    var provider: String?
    var gpu: String?
    /// Weight precision the box is serving, e.g. `bf16` or `fp8`; vLLM does not report
    /// it, so the entry says.
    var quant: String?
    var contextLength: Int?
    /// Another hostname that identifies the provider, e.g. the SSH endpoint.
    var sshHost: String?

    enum CodingKeys: String, CodingKey {
        case name, token, provider, gpu, quant
        case baseURL = "base_url"
        case metricsURL = "metrics_url"
        case controlURL = "ctl_url"
        case contextLength = "context"
        case sshHost = "ssh"
    }

    var metrics: String {
        if let metricsURL { return metricsURL }
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return base + "/metrics"
    }

    var host: String {
        guard let url = URL(string: baseURL), let host = url.host else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The explicit provider, else the registrable domain of the first real hostname
    /// in the entry. An IP literal says nothing, so a box reached by IP with an SSH
    /// jump host at `ssh2.vast.ai` reports `vast.ai`. Nothing here is a vendor list.
    var providerName: String? {
        provider ?? Remote.inferProvider(from: [baseURL, controlURL, metricsURL, sshHost].compactMap { $0 })
    }

    static func inferProvider(from candidates: [String]) -> String? {
        for candidate in candidates {
            guard let host = hostname(in: candidate), !isAddressLiteral(host),
                  host != "localhost" else { continue }
            let labels = host.lowercased().split(separator: ".").map(String.init)
            guard labels.count >= 2 else { continue }
            // co.uk, com.au and friends: the registrable name is three labels long.
            let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
            let take = labels.count >= 3 && labels[labels.count - 1].count == 2
                && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
            return labels.suffix(take).joined(separator: ".")
        }
        return nil
    }

    private static func hostname(in text: String) -> String? {
        if let url = URL(string: text), let host = url.host, text.contains("://") { return host }
        let bare = text.split(separator: "/").first.map(String.init) ?? text
        // `host:port` — but not an IPv6 literal, which has several colons.
        let parts = bare.split(separator: ":")
        return parts.count <= 2 ? parts.first.map(String.init) : bare
    }

    private static func isAddressLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

enum Remotes {
    static let path = NSHomeDirectory() + "/.config/resident/remotes.json"

    /// Reads the file on every call; it is a few hundred bytes and the sampling loop
    /// is the only caller. A missing or malformed file is simply no remotes.
    static func load(path: String = Remotes.path) -> [Remote] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return decode(data)
    }

    static func decode(_ data: Data) -> [Remote] {
        (try? JSONDecoder().decode([Remote].self, from: data)) ?? []
    }
}
