import XCTest
@testable import Resident

final class SamplerTests: XCTestCase {
    private final class Runtime: ModelRuntime {
        let name = "test"
        var readStarted: Double = 0
        func isPresent() -> Bool { true }
        func loadedModels() -> [LoadedModel] {
            readStarted = Date().timeIntervalSince1970
            return []
        }
        func unload(_ model: LoadedModel) -> String? { nil }
    }

    func testFreshnessIncludesTimeSpentCollectingTheSample() {
        let runtime = Runtime()
        let sample = Sampler(runtimes: [runtime]).take()
        XCTAssertLessThanOrEqual(sample.ts, runtime.readStarted)
    }
}
