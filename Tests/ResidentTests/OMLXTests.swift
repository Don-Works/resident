import XCTest
@testable import Resident

final class OMLXTests: XCTestCase {
    private let rows: [String: Any] = ["models": [
        ["id": "Qwen2B", "model_alias": "admin", "loaded": true, "actual_size": 100,
         "model_type": "llm", "max_context_window": 16384],
        ["id": "Qwen35B", "model_alias": "dev", "loaded": true, "actual_size": 900,
         "model_type": "llm"],
        ["id": "flint", "loaded": false, "is_loading": true, "estimated_size": 500],
        ["id": "unloaded", "loaded": false, "estimated_size": 1000]
    ]]

    func testOnlyLoadedOrLoadingModelsAreResidentAndSizesAreNotDuplicated() {
        let models = OMLX.parse(status: ["active_requests": 0], models: rows, runtime: "oMLX:8001")
        XCTAssertEqual(models.map(\.identifier), ["Qwen2B", "Qwen35B", "flint"])
        XCTAssertEqual(models.totalBytes, 1500)
        XCTAssertEqual(models[0].displayName, "admin")
        XCTAssertEqual(models[0].contextLength, 16384)
        XCTAssertEqual(models[2].activity, .loading)
        XCTAssertEqual(models.idleModels.map(\.identifier), ["Qwen2B", "Qwen35B"])
    }

    func testAggregateActivityNeverPretendsToIdentifyTheGeneratingModel() {
        let models = OMLX.parse(status: ["active_requests": 2], models: rows, runtime: "oMLX:8001")
        XCTAssertEqual(models[0].activity, .loaded)
        XCTAssertEqual(models[1].activity, .loaded)
        XCTAssertEqual(models[0].runtimeInFlight, 2)
        XCTAssertTrue(models.idleModels.isEmpty)
        XCTAssertTrue(models.allSatisfy { $0.currentTokensPerSecond == nil })
    }

    func testMissingActivityNeverBecomesIdle() {
        let models = OMLX.parse(status: [:], models: rows, runtime: "oMLX:8001")
        XCTAssertTrue(models.idleModels.isEmpty)
    }
}
