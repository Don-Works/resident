import Foundation

extension CLI {
    // MARK: - Unload

    static func unload(identifier: String?, idleOnly: Bool) {
        let runtimes: [ModelRuntime] = [LMStudio(), Ollama(), LlamaServer(), UnmanagedRuntime()]
        let present = runtimes.filter { $0.isPresent() }
        let loaded = present.flatMap { runtime in runtime.loadedModels().map { (runtime, $0) } }

        let targets = loaded.filter { _, model in
            if idleOnly { return model.activity != .generating }
            guard let identifier else { return false }
            return model.identifier == identifier || model.displayName == identifier
        }

        guard !targets.isEmpty else {
            print(idleOnly ? "No idle models to release." : "No model matched.")
            if !loaded.isEmpty {
                print("Loaded: " + loaded.map { $0.1.identifier }.joined(separator: ", "))
            }
            return
        }

        var freed = 0
        for (runtime, model) in targets {
            if let reason = runtime.unload(model) {
                print("✗ \(model.displayName): \(reason)")
            } else {
                freed += model.sizeBytes
                print("✓ released \(model.displayName) (\(Format.bytes(model.sizeBytes)))")
            }
        }
        if freed > 0 { print("Freed about \(Format.bytes(freed)).") }
    }
}
