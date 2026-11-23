import XCTest
@testable import Resident

final class LlamaServerTests: XCTestCase {
    private let props: [String: Any] = [
        "model_alias": "inkling-2-mini",
        "model_ftype": "IQ4_NL - 4.5 bpw",
        "model_path": "/models/Inkling-2-Mini-IQ4_NL.gguf",
        "default_generation_settings": ["n_ctx": 32768],
    ]
    private let idleSlots: [[String: Any]] = [["id": 0, "is_processing": false], ["id": 1, "is_processing": false]]

    func testCurrentServerReportsAliasQuantisationAndContextFromProps() {
        let model = LlamaServer.model(props: props, slots: idleSlots, port: 8900, size: 10, reading: nil)
        XCTAssertEqual(model.runtime, "llama.cpp:8900")
        XCTAssertEqual(model.displayName, "inkling-2-mini")
        XCTAssertEqual(model.quantisation, "IQ4_NL")
        XCTAssertEqual(model.contextLength, 32768)
    }

    func testSlotsThatAnswerAndAreAllFreeMeanIdle() {
        XCTAssertEqual(LlamaServer.model(props: props, slots: idleSlots, port: 1, size: 0, reading: nil).activity, .idle)
        var busy = idleSlots
        busy[1]["is_processing"] = true
        let generating = LlamaServer.model(props: props, slots: busy, port: 1, size: 0, reading: nil)
        XCTAssertEqual(generating.activity, .generating)
        XCTAssertEqual(generating.inFlight, 1)
    }

    func testNoSlotEndpointNeverBecomesIdle() {
        XCTAssertEqual(LlamaServer.model(props: props, slots: nil, port: 1, size: 0, reading: nil).activity, .loaded)
    }

    func testOlderServerFallsBackToFileNameQuantisation() {
        let old: [String: Any] = ["model_path": "/m/qwen2.5-7b-instruct.Q4_K_M.gguf", "n_ctx": 4096]
        let model = LlamaServer.model(props: old, slots: nil, port: 1, size: 0, reading: nil)
        XCTAssertEqual(model.displayName, "qwen2.5-7b-instruct.Q4_K_M.gguf")
        XCTAssertEqual(model.quantisation, "Q4_K_M")
        XCTAssertEqual(model.contextLength, 4096)
    }

    func testOnlyALlamaServerExecutableIsDiscovered() {
        XCTAssertTrue(LlamaServer.isLlamaServer(["/opt/llama/bin/llama-server", "-m", "x.gguf"]))
        XCTAssertFalse(LlamaServer.isLlamaServer(["/bin/zsh", "-c", "llama-server -m x.gguf"]))
    }
}
