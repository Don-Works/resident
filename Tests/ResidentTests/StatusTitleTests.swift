import XCTest
@testable import Resident

final class StatusTitleTests: XCTestCase {
    private let memory = Sample.MemorySnapshot(total: 128 << 30, available: 64 << 30, wired: 0, compressed: 0,
                                               swapUsed: 0, swapTotal: 0, swapoutRate: 0)

    private func model(_ name: String, remote: RemoteInfo? = nil, quant: String? = nil, rate: Double? = nil,
                       inFlight: Int = 0, activity: LoadedModel.Activity = .generating, size: Int = 0) -> LoadedModel {
        var model = LoadedModel(runtime: remote == nil ? "lmstudio" : "vllm@box", identifier: name, displayName: name,
                                sizeBytes: size, quantisation: quant, parameters: nil, architecture: nil, kind: nil,
                                contextLength: nil, maxContextLength: nil, activity: activity, timeToLive: nil,
                                tokensPerSecond: rate, measuredAt: rate == nil ? nil : Date().timeIntervalSince1970,
                                inFlight: inFlight)
        model.remote = remote
        return model
    }

    private func sample(_ models: [LoadedModel], gpu: Double = 0) -> Sample {
        Sample(ts: Date().timeIntervalSince1970, gauges: [], models: models, memory: memory, gpuUtilisation: gpu,
               gpuResidentBytes: 0, pressure: 1, runtimesSeen: [])
    }

    private func render(_ sample: Sample) -> StatusTitle.Rendering {
        StatusTitle.render(sample: sample, verdict: Verdict.evaluate(sample: sample))
    }

    func testRemoteBoxReadsProviderModelQuantShareAndItsOwnGPU() {
        let box = model("qwen3.8-27b", remote: RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1",
                                                          gpu: "H100 SXM", gpuUtilisation: 1.0),
                        quant: "bf16", rate: 52, inFlight: 2)
        let local = model("Qwen3.8 27B", quant: "Q4_K_M", activity: .loaded, size: 27 << 30)
        let rendering = render(sample([box, local], gpu: 0.04))
        XCTAssertEqual(rendering.text, "vast.ai · qwen3.8-27b · bf16 · 26 tok/s ×2 · gpu 100%")
        XCTAssertTrue(rendering.legend.contains { $0.hasPrefix("this mac: gpu 4%") }, "\(rendering.legend)")
    }

    func testLocalModelReadsLocalAndThisMacsGPU() {
        let rendering = render(sample([model("Qwen3.8 27B", quant: "Q4_K_M", rate: 25, size: 27 << 30)], gpu: 0.54))
        XCTAssertEqual(rendering.text, "local · Qwen3.8 27B · Q4_K_M · 25 tok/s · gpu 54%")
    }

    func testFieldsWithoutAReadingAreLeftOutNotDashed() {
        let rendering = render(sample([model("Qwen3.8 27B", size: 27 << 30)], gpu: 0.1))
        XCTAssertEqual(rendering.text, "local · Qwen3.8 27B · gpu 10%")
    }

    func testThrashingIsAWordInFront() {
        var info = RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1", gpuUtilisation: 0.97)
        info.thrashing = true
        let rendering = render(sample([model("qwen3.8-27b", remote: info, rate: 9, inFlight: 1)]))
        XCTAssertEqual(rendering.text, "vast-box thrashing · vast.ai · qwen3.8-27b · 9.0 tok/s · gpu 97%")
    }

    func testIdleKeepsTheFastestModelsFiveFieldsAlone() {
        let box = model("qwen3.8-27b", remote: RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1",
                                                          gpuUtilisation: 0), quant: "fp8", activity: .loaded)
        var local = model("Qwen3.8 27B", quant: "8bit", rate: 26, activity: .idle, size: 27 << 30)
        local.measuredAt = Date().timeIntervalSince1970 - 600   // well past the working hold
        let rendering = render(sample([local, box], gpu: 0.04))
        XCTAssertEqual(rendering.text, "local · Qwen3.8 27B · 8bit · 26 tok/s · gpu 4%")
        XCTAssertEqual(rendering.legend.first, "the model with the highest rate on record keeps the title")
    }

    func testTheHighestRateOnRecordWinsEvenWhenAnotherModelIsGenerating() {
        let box = model("qwen3.8-27b", remote: RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1",
                                                          gpuUtilisation: 0.1), quant: "fp8", rate: 44, activity: .loaded)
        let local = model("Qwen3.8 27B", quant: "8bit", rate: 13, size: 27 << 30)   // generating right now
        XCTAssertEqual(render(sample([local, box], gpu: 0.99)).text, "vast.ai · qwen3.8-27b · fp8 · 44 tok/s · gpu 10%")
        // A box's total is shared per request before it is compared.
        let shared = model("qwen3.8-27b", remote: RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1",
                                                             gpuUtilisation: 1.0), quant: "fp8", rate: 52, inFlight: 4)
        XCTAssertEqual(render(sample([local, shared], gpu: 0.99)).text, "local · Qwen3.8 27B · 8bit · 13 tok/s · gpu 99%")
    }

    func testIdleWithNoRateYetNamesTheLargestLocalModel() {
        let embed = model("Nomic Embed", activity: .idle, size: 80 << 20)
        var big = model("Qwen3.8 27B", quant: "8bit", activity: .loaded, size: 27 << 30)
        big.kind = "llm"
        var small = model("Tiny", activity: .loaded, size: 1 << 30)
        small.kind = "llm"
        XCTAssertEqual(render(sample([embed, small, big], gpu: 0.02)).text, "local · Qwen3.8 27B · 8bit · gpu 2%")
    }

    func testLocalRateIsPerPredictionAndNeverDividedByInFlight() {
        let rendering = render(sample([model("Qwen3.8 27B", quant: "8bit", rate: 20, inFlight: 2, size: 27 << 30)], gpu: 0.9))
        XCTAssertEqual(rendering.text, "local · Qwen3.8 27B · 8bit · 20 tok/s · gpu 90%")
    }

    func testNothingLoadedIsIdle() {
        XCTAssertEqual(render(sample([])).text, "idle")
    }

    func testNoGlyphsAnywhere() {
        let box = model("qwen3.8-27b", remote: RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1",
                                                          gpuUtilisation: 1.0), rate: 70, inFlight: 1)
        let text = render(sample([box])).text
        for glyph in ["▶", "☁", "⚠", "≤"] { XCTAssertFalse(text.contains(glyph), glyph) }
    }
}
