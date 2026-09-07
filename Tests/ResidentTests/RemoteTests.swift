import XCTest
@testable import Resident

final class PrometheusTests: XCTestCase {
    let page = """
    # HELP vllm:num_requests_running Number of requests in model execution batches.
    # TYPE vllm:num_requests_running gauge
    vllm:num_requests_running{engine="0",model_name="qwen3.8-27b"} 3.0
    vllm:num_requests_waiting{engine="0",model_name="qwen3.8-27b"} 1.0
    vllm:kv_cache_usage_perc{engine="0",model_name="qwen3.8-27b"} 0.2185929648241206
    vllm:prompt_tokens_total{engine="0",model_name="qwen3.8-27b"} 462839.0
    vllm:generation_tokens_total{engine="0",model_name="qwen3.8-27b"} 13938.0
    vllm:generation_tokens_total{engine="0",model_name="other-7b"} 12.0
    vllm:request_success_total{engine="0",finished_reason="stop",model_name="qwen3.8-27b"} 40.0
    process_cpu_seconds_total 1234.5
    """

    func testLabelledSamplesParse() {
        let metrics = Prometheus.parse(page)
        XCTAssertEqual(metrics.value("vllm:num_requests_running", model: "qwen3.8-27b"), 3.0)
        XCTAssertEqual(metrics.value("vllm:generation_tokens_total", model: "qwen3.8-27b"), 13938.0)
        XCTAssertEqual(metrics.value("vllm:kv_cache_usage_perc", model: "qwen3.8-27b") ?? 0, 0.2186, accuracy: 0.001)
        XCTAssertNil(metrics.value("vllm:num_requests_running", model: "other-7b"))
    }

    func testModelNamesComeFromLabelsInOrder() {
        XCTAssertEqual(Prometheus.parse(page).modelNames, ["qwen3.8-27b", "other-7b"])
    }

    func testUnlabelledAndCommentLinesSurvive() {
        let metrics = Prometheus.parse(page)
        XCTAssertEqual(metrics.samples.first { $0.name == "process_cpu_seconds_total" }?.value, 1234.5)
        XCTAssertFalse(metrics.samples.contains { $0.name.hasPrefix("#") })
    }
}

final class RemoteTests: XCTestCase {
    func testProviderIsTheRegistrableDomainOfTheFirstRealHostname() {
        XCTAssertEqual(Remote.inferProvider(from: ["http://203.0.113.10:20066/v1", "ssh2.vast.ai:11354"]), "vast.ai")
        XCTAssertEqual(Remote.inferProvider(from: ["https://gpu-7.eu-west.lambda.cloud:8000/v1"]), "lambda.cloud")
        XCTAssertEqual(Remote.inferProvider(from: ["http://box.rental.co.uk:8000/v1"]), "rental.co.uk")
        XCTAssertNil(Remote.inferProvider(from: ["http://10.0.0.5:8000/v1", "http://localhost:8000"]))
        XCTAssertNil(Remote.inferProvider(from: ["http://[fd00::1]:8000/v1"]))
    }

    func testEntryDecodesWithProvisionerKeysAndDefaultsTheMetricsURL() {
        let json = """
        [{"name":"vast-box","base_url":"http://203.0.113.10:20066/v1","ctl_url":"http://203.0.113.10:19983",
          "token":"t","gpu":"H100 SXM","context":262144,"ssh":"ssh2.vast.ai:11354"}]
        """
        let remotes = Remotes.decode(Data(json.utf8))
        XCTAssertEqual(remotes.count, 1)
        let box = remotes[0]
        XCTAssertEqual(box.metrics, "http://203.0.113.10:20066/metrics")
        XCTAssertEqual(box.host, "203.0.113.10:20066")
        XCTAssertEqual(box.providerName, "vast.ai")
        XCTAssertEqual(box.contextLength, 262144)
    }

    func testExplicitProviderWinsAndMalformedFileIsNoRemotes() {
        let remotes = Remotes.decode(Data(#"[{"name":"lab","base_url":"http://10.0.0.5:8000/v1","provider":"homelab"}]"#.utf8))
        XCTAssertEqual(remotes.first?.providerName, "homelab")
        XCTAssertEqual(Remotes.decode(Data("not json".utf8)), [])
    }

    func testRemoteModelsStayOutOfMemoryArithmetic() {
        let local = LoadedModel(runtime: "lmstudio", identifier: "a", displayName: "A", sizeBytes: 10 << 30,
                                quantisation: nil, parameters: nil, architecture: nil, kind: nil,
                                contextLength: nil, maxContextLength: nil, activity: .loaded, timeToLive: nil)
        var remote = LoadedModel(runtime: "vllm@box", identifier: "b", displayName: "B", sizeBytes: 0,
                                 quantisation: nil, parameters: nil, architecture: nil, kind: nil,
                                 contextLength: nil, maxContextLength: nil, activity: .loaded, timeToLive: nil)
        remote.remote = RemoteInfo(name: "box", provider: "vast.ai", host: "box:1")
        let models = [local, remote]
        XCTAssertEqual(models.totalBytes, 10 << 30)
        XCTAssertEqual(models.idleModels.map(\.identifier), ["a"])
        XCTAssertEqual(models.remotes.map(\.identifier), ["b"])
    }

    func testVerdictHeadlineNamesTheRemoteWhenNothingIsLocal() {
        var remote = LoadedModel(runtime: "vllm@box", identifier: "qwen3.8-27b", displayName: "qwen3.8-27b",
                                 sizeBytes: 0, quantisation: nil, parameters: nil, architecture: nil, kind: nil,
                                 contextLength: 262_144, maxContextLength: nil, activity: .generating,
                                 timeToLive: nil, tokensPerSecond: 52, measuredAt: Date().timeIntervalSince1970,
                                 inFlight: 2)
        remote.remote = RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1", gpu: "H100 SXM",
                                   gpuUtilisation: 1.0, kvCacheUsage: 0.22, queued: 0, promptTokensPerSecond: 9000)
        let sample = Sample(ts: Date().timeIntervalSince1970, gauges: [], models: [remote],
                            memory: .init(total: 128 << 30, available: 64 << 30, wired: 0, compressed: 0,
                                          swapUsed: 0, swapTotal: 0, swapoutRate: 0),
                            gpuUtilisation: 0, gpuResidentBytes: 0, pressure: 1, runtimesSeen: ["vllm"])
        let verdict = Verdict.evaluate(sample: sample)
        XCTAssertEqual(verdict.level, .ok)
        XCTAssertEqual(verdict.headline, "Nothing loaded locally — a box on vast.ai serving")
        XCTAssertTrue(verdict.summary.contains {
            $0.hasPrefix("☁ qwen3.8-27b on vast.ai (H100 SXM) is decoding at 52 tok/s")
                && $0.contains("2 running") && $0.contains("26 tok/s each")
                && $0.contains("KV cache 22% full") && $0.contains("GPU 100% busy")
        })
        XCTAssertEqual(verdict.reclaimable, 0)
    }

    func testThrashRuleNeedsAPreemptionAndCachePressure() {
        XCTAssertTrue(RemoteVLLM.isThrashing(preemptions: 31, before: 29, waitingForCapacity: 2, kvCacheUsage: 0.7))
        XCTAssertTrue(RemoteVLLM.isThrashing(preemptions: 31, before: 30, waitingForCapacity: 0, kvCacheUsage: 0.9))
        XCTAssertFalse(RemoteVLLM.isThrashing(preemptions: 31, before: 31, waitingForCapacity: 2, kvCacheUsage: 0.9), "no new preemption")
        XCTAssertFalse(RemoteVLLM.isThrashing(preemptions: 31, before: 30, waitingForCapacity: 0, kvCacheUsage: 0.4), "one blip with room to spare")
        XCTAssertFalse(RemoteVLLM.isThrashing(preemptions: 31, before: nil, waitingForCapacity: 2, kvCacheUsage: 0.9), "first sample")
    }

    func testLabelledValueCanFilterOnMoreLabels() {
        let page = """
        vllm:num_requests_waiting_by_reason{engine="0",model_name="m",reason="capacity"} 2.0
        vllm:num_requests_waiting_by_reason{engine="0",model_name="m",reason="deferred"} 0.0
        """
        let metrics = Prometheus.parse(page)
        XCTAssertEqual(metrics.value("vllm:num_requests_waiting_by_reason", model: "m", where: ["reason": "capacity"]), 2.0)
        XCTAssertEqual(metrics.value("vllm:num_requests_waiting_by_reason", model: "m", where: ["reason": "deferred"]), 0.0)
    }

    func testHeadlineGoesToTheFastestGeneratingModelWhereverItRuns() {
        var local = LoadedModel(runtime: "lmstudio", identifier: "a", displayName: "Local", sizeBytes: 10 << 30,
                                quantisation: nil, parameters: nil, architecture: nil, kind: nil,
                                contextLength: nil, maxContextLength: nil, activity: .generating, timeToLive: nil)
        local.tokensPerSecond = 14
        var remote = LoadedModel(runtime: "vllm@box", identifier: "b", displayName: "Box", sizeBytes: 0,
                                 quantisation: nil, parameters: nil, architecture: nil, kind: nil,
                                 contextLength: nil, maxContextLength: nil, activity: .generating, timeToLive: nil)
        remote.tokensPerSecond = 77
        remote.remote = RemoteInfo(name: "box", provider: "vast.ai", host: "box:1")
        let memory = Sample.MemorySnapshot(total: 1, available: 1, wired: 0, compressed: 0, swapUsed: 0, swapTotal: 0, swapoutRate: 0)
        let sample = Sample(ts: 0, gauges: [], models: [local, remote], memory: memory, gpuUtilisation: 0,
                            gpuResidentBytes: 0, pressure: 1, runtimesSeen: [])
        XCTAssertEqual(sample.working?.identifier, "b")
    }

    func testThrashingBoxMakesTheVerdictCritical() {
        var remote = LoadedModel(runtime: "vllm@box", identifier: "qwen3.8-27b", displayName: "qwen3.8-27b",
                                 sizeBytes: 0, quantisation: nil, parameters: nil, architecture: nil, kind: nil,
                                 contextLength: nil, maxContextLength: nil, activity: .generating, timeToLive: nil)
        remote.remote = RemoteInfo(name: "vast-box", provider: "vast.ai", host: "box:1", kvCacheUsage: 0.87,
                                   queued: 2, waitingForCapacity: 2, preemptions: 31, thrashing: true)
        let memory = Sample.MemorySnapshot(total: 128 << 30, available: 64 << 30, wired: 0, compressed: 0,
                                           swapUsed: 0, swapTotal: 0, swapoutRate: 0)
        let sample = Sample(ts: 0, gauges: [], models: [remote], memory: memory, gpuUtilisation: 0,
                            gpuResidentBytes: 0, pressure: 1, runtimesSeen: ["vllm"])
        let verdict = Verdict.evaluate(sample: sample)
        XCTAssertEqual(verdict.level, .critical)
        XCTAssertEqual(verdict.headline, "vast-box is thrashing — too much context for its cache")
        XCTAssertTrue(verdict.warnings.contains { $0.contains("2 request(s) waiting for cache") && $0.contains("31 preemptions") })
    }
}
