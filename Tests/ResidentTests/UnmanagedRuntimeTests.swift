import XCTest
@testable import Resident

final class UnmanagedRuntimeTests: XCTestCase {
    func testPiElisionModelIsNamedFromItsDirectory() {
        XCTAssertEqual(UnmanagedRuntime.modelName(arguments: [
            "python", "-m", "omlx_elision.server", "--model", "/models/qwen38-pi27b-8bit"
        ]), "qwen38-pi27b-8bit")
    }

    func testFlashElisionUsesItsExplicitModelIdentity() {
        XCTAssertEqual(UnmanagedRuntime.modelName(arguments: [
            "python", "-m", "cuda_elision.server", "--model", "/weights/first-shard.gguf",
            "--model-id", "Qwen3.8-Flash-Next"
        ]), "Qwen3.8-Flash-Next")
    }

    func testStandardMLXModelAndEqualsSyntaxRemainSupported() {
        XCTAssertEqual(UnmanagedRuntime.modelName(arguments: [
            "python", "-m", "mlx_lm.server", "--model=mlx-community/Qwen3.5-2B-MLX-4bit"
        ]), "Qwen3.5-2B-MLX-4bit")
    }

    func testAnUnrelatedProcessIsNotARecognizedRuntime() {
        XCTAssertNil(UnmanagedRuntime.modelName(arguments: ["python", "ordinary.py", "--model", "data"]))
    }

    func testKernelArgumentsPreserveEmptyValuesAndExcludeEnvironment() {
        let arguments = ["python", "-m", "omlx_elision.server", "--model", "", "--port", "8193"]
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/usr/bin/python".utf8) + [0, 0, 0]
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        bytes += Array("ENV_ONLY=mlx_lm.server".utf8) + [0]
        XCTAssertEqual(ProcessList.decodeArguments(bytes), arguments)
        XCTAssertEqual(UnmanagedRuntime.modelName(arguments: ProcessList.decodeArguments(bytes)!), "omlx_elision.server")
    }

    func testInvalidKernelArgumentFramesAreRejected() {
        XCTAssertNil(ProcessList.decodeArguments([]))
        XCTAssertNil(ProcessList.decodeArguments([0, 0, 0, 0, 1, 0]))
    }

    func testProcessListIncludesBothLaunchdAndTheCurrentProcess() {
        let processes = ProcessList.all()
        XCTAssertTrue(processes.contains(1))
        XCTAssertTrue(processes.contains(ProcessInfo.processInfo.processIdentifier))
    }

    func testFootprintCountsTheMemoryThisProcessAllocated() {
        let before = ProcessList.footprintBytes(of: getpid()) ?? 0
        let block = UnsafeMutableRawPointer.allocate(byteCount: 256 << 20, alignment: 16)
        defer { block.deallocate() }
        memset(block, 1, 256 << 20)
        XCTAssertGreaterThan((ProcessList.footprintBytes(of: getpid()) ?? 0) - before, 200 << 20)
    }

    func testListeningPortsFindsThisProcessesOwnListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard Darwin.bind(fd, pointer, length) == 0, Darwin.listen(fd, 1) == 0 else { return -1 }
                return getsockname(fd, pointer, &length)
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(ProcessList.listeningPorts(of: getpid()).contains(Int(UInt16(bigEndian: address.sin_port))))
    }

    func testMTPLXAndMLXAudioServersAreRecognised() {
        XCTAssertEqual(UnmanagedRuntime.modelName(arguments: [
            "/venv/bin/mtplx", "serve", "--model", "/models/Qwen3.8-27B-MTPLX", "--port", "8002"
        ]), "Qwen3.8-27B-MTPLX")
        XCTAssertEqual(UnmanagedRuntime.modelName(arguments: ["python", "-m", "mlx_audio.server"]), "mlx_audio")
    }
}
