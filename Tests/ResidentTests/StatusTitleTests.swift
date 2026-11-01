import XCTest
@testable import Resident

final class StatusTitleTests: XCTestCase {
    private let now: Double = 1000
    private let memory = Sample.MemorySnapshot(total: 128 << 30, available: 64 << 30, wired: 0,
        compressed: 0, swapUsed: 0, swapTotal: 0, swapoutRate: 0)

    private func model(_ name: String, activity: LoadedModel.Activity = .idle,
                       history: Double? = nil, current: Double? = nil) -> LoadedModel {
        LoadedModel(runtime: "LM Studio", identifier: name, displayName: name, sizeBytes: 1 << 30,
            quantisation: "8bit", parameters: nil, architecture: nil, kind: "llm", contextLength: nil,
            maxContextLength: nil, activity: activity, timeToLive: nil, tokensPerSecond: history,
            measuredAt: now, inFlight: activity == .generating ? 1 : 0, currentTokensPerSecond: current)
    }

    private func sample(_ models: [LoadedModel], ts: Double = 1000) -> Sample {
        Sample(ts: ts, gauges: [], models: models, memory: memory, gpuUtilisation: 0.08,
            gpuResidentBytes: 0, pressure: 1, runtimesSeen: [])
    }

    private func render(_ sample: Sample, at: Double = 1000) -> StatusTitle.Rendering {
        StatusTitle.render(sample: sample, verdict: Verdict.evaluate(sample: sample), now: at)
    }

    func testIdleModelsNeverShowHistoricalSpeedOrAnActiveModelName() {
        let s = sample([model("Qwen2B", history: 205), model("Qwen27B", history: 18)])
        XCTAssertEqual(render(s).text, "idle · 2 loaded · gpu 8%")
        XCTAssertNil(s.working)
    }

    func testCurrentRequestWinsOverFasterIdleModel() {
        let s = sample([model("Qwen2B", history: 205), model("Qwen27B", activity: .generating, history: 18)])
        XCTAssertEqual(render(s).text, "local · Qwen27B · 8bit · generating · gpu 8%")
        XCTAssertEqual(s.working?.identifier, "Qwen27B")
        XCTAssertFalse(Verdict.evaluate(sample: s).summary.contains { $0.contains("18 tok/s") })
    }

    func testFinishedRequestImmediatelyClearsActivityEvenWithFreshStats() {
        var m = model("Qwen", activity: .generating, history: 18)
        XCTAssertTrue(render(sample([m])).text.contains("generating"))
        m.activity = .idle
        m.inFlight = 0
        XCTAssertEqual(render(sample([m])).text, "idle · 1 loaded · gpu 8%")
    }

    func testUnknownActivityIsNotReportedAsIdleOrReclaimable() {
        let s = sample([model("Unmanaged", activity: .loaded)])
        XCTAssertEqual(render(s).text, "activity unknown · 1 loaded · gpu 8%")
        XCTAssertTrue(Verdict.evaluate(sample: s).reclaimCandidates.isEmpty)
    }

    func testCurrentRemoteRateUsesItsCardAndSharesAcrossRequests() {
        var m = model("remote", activity: .generating, history: 999, current: 52)
        m.remote = RemoteInfo(name: "box", provider: "vast.ai", host: "box", gpuUtilisation: 1)
        m.inFlight = 2
        XCTAssertEqual(render(sample([m])).text, "vast.ai · remote · 8bit · generating · 26 tok/s ×2 · gpu 100%")
    }

    func testStaleRateDoesNotSurviveIntoCurrentRequest() {
        var m = model("Qwen", activity: .generating, history: 200, current: 40)
        m.measuredAt = now - 4
        XCTAssertEqual(render(sample([m])).text, "local · Qwen · 8bit · generating · gpu 8%")
    }

    func testStaleSampleIsExplicitAndNeverLooksLive() {
        let s = sample([model("Qwen", activity: .generating, current: 40)])
        XCTAssertEqual(render(s, at: now + 4).text, "stale · updated 4s ago")
    }

    func testMultipleActiveModelsAreVisibleAndHistoricalRatesDoNotRankThem() {
        let s = sample([model("Qwen27B", activity: .generating, history: 200),
                        model("Qwen2B", activity: .generating, current: 40)])
        XCTAssertEqual(render(s).text, "local · Qwen2B · 8bit · generating · 40 tok/s · gpu 8% · +1 active")
    }

    func testAggregateRuntimeActivityNamesTheRuntimeWithoutInventingAModel() {
        var m = model("admin", activity: .loaded)
        m.runtime = "oMLX:8001"
        m.runtimeInFlight = 2
        let output = render(sample([m]))
        XCTAssertEqual(output.text, "oMLX:8001 · 2 in flight · gpu 8%")
        XCTAssertTrue(output.legend.contains { $0.contains("does not identify the active model") })
    }

    func testModelLoadingIsVisibleWithoutAPrediction() {
        let m = model("dev", activity: .loading)
        XCTAssertEqual(render(sample([m])).text, "local · dev · 8bit · loading · gpu 8%")
    }

    func testThrashingRemainsAnExplicitWord() {
        var m = model("dev", activity: .generating, current: 9)
        var remote = RemoteInfo(name: "box", provider: "vast.ai", host: "box", gpuUtilisation: 1)
        remote.thrashing = true
        m.remote = remote
        XCTAssertTrue(render(sample([m])).text.hasPrefix("box thrashing · vast.ai · dev"))
    }

    func testEmptySampleStillShowsCurrentGPU() {
        XCTAssertEqual(render(sample([])).text, "idle · 0 loaded · gpu 8%")
    }
}
