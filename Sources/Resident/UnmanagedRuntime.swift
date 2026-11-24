import Darwin
import Foundation

/// Everything with no model manager to ask: `mlx_lm.server`, a bare Python script, a
/// vLLM process. These are found by looking for a process whose command line names an
/// inference runtime and whose resident memory is large enough to be holding weights.
///
/// The size reported here is resident process memory, not weight bytes: it includes the
/// KV cache, the framework and the interpreter. Every model this finds is therefore
/// marked approximate, and the decode-ceiling estimate derived from it is a floor.
final class UnmanagedRuntime: ModelRuntime {
    let name = "unmanaged"

    /// Below this a process is a client, a tokeniser or a launcher — not weights.
    private let residentFloor = 900 * 1024 * 1024

    private static let signatures = [
        "omlx_elision.server", "cuda_elision.server", "vllm_elision.server",
        "mlx_lm", "mlx-lm", "mlx_vlm", "mlx_parallm",
        "vllm", "sglang", "koboldcpp", "text-generation-launcher",
        "exllama", "tabbyapi",
    ]

    func isPresent() -> Bool { !candidates().isEmpty }

    func loadedModels() -> [LoadedModel] {
        candidates().map { candidate in
            LoadedModel(
                runtime: name,
                identifier: String(candidate.pid),
                displayName: candidate.label,
                sizeBytes: candidate.resident,
                quantisation: nil,
                parameters: nil,
                architecture: nil,
                kind: nil,
                contextLength: nil,
                maxContextLength: nil,
                activity: .loaded,
                timeToLive: nil,
                pid: candidate.pid,
                sizeIsApproximate: true
            )
        }
    }

    /// Killing somebody's inference server is not a menu-bar-sized decision.
    func unload(_ model: LoadedModel) -> String? {
        "Resident does not stop unmanaged processes; quit it yourself (pid \(model.identifier))"
    }

    private struct Candidate {
        var pid: pid_t
        var label: String
        var resident: Int
    }

    private func candidates() -> [Candidate] {
        ProcessList.all().compactMap { pid in
            guard let arguments = ProcessList.arguments(of: pid),
                  let label = Self.modelName(arguments: arguments) else { return nil }
            guard let resident = ProcessList.residentBytes(of: pid), resident >= residentFloor
            else { return nil }
            return Candidate(pid: pid, label: label, resident: resident)
        }
    }

    static func modelName(arguments: [String]) -> String? {
        let command = arguments.joined(separator: " ").lowercased()
        guard let signature = signatures.first(where: { command.contains($0) }) else { return nil }
        for flag in ["--model-id", "--model", "--model-path", "--model_path"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                let value = arguments[index + 1]
                if !value.isEmpty && !value.hasPrefix("-") {
                    return URL(fileURLWithPath: value).lastPathComponent
                }
            }
            if let argument = arguments.first(where: { $0.hasPrefix(flag + "=") }) {
                let value = String(argument.dropFirst(flag.count + 1))
                if !value.isEmpty { return URL(fileURLWithPath: value).lastPathComponent }
            }
        }
        return signature
    }
}

/// Just enough of `libproc` to list processes and read their resident size.
enum ProcessList {
    static func all() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        return Array(pids.prefix(min(Int(found), pids.count))).filter { $0 > 0 }
    }

    static func residentBytes(of pid: pid_t) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard read == size else { return nil }
        return Int(info.pti_resident_size)
    }

    /// The full argument vector, which is where a Python inference server names itself.
    static func command(of pid: pid_t) -> String? {
        arguments(of: pid)?.joined(separator: " ")
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var size = Int(argumentMax)
        var buffer = [CChar](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }

        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        return decodeArguments(bytes)
    }

    static func decodeArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc <= 4096 else { return nil }
        let body = bytes.dropFirst(MemoryLayout<Int32>.size)
        guard let separator = body.firstIndex(of: 0) else { return nil }
        let argv = body.suffix(from: body.index(after: separator)).drop(while: { $0 == 0 })
        let parts = argv.split(separator: 0, omittingEmptySubsequences: false).prefix(Int(argc))
        guard parts.count == argc else { return nil }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    private static var argumentMax: Int32 = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0 else { return 4096 }
        return value
    }()
}
