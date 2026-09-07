import XCTest
@testable import Resident

/// The two real predictions below were captured from `lms log stream --stats --json`
/// on 2026-09-07: a 27B 8-bit model at 76K context, decoding at about 13 tok/s.
final class LMStudioReadingTests: XCTestCase {
    private func stats(predicted: Double, prompt: Double = 76_084, first: Double, total: Double,
                       reason: String = "eosFound") -> [String: Any] {
        ["predictedTokensCount": predicted, "promptTokensCount": prompt, "timeToFirstTokenSec": first,
         "totalTimeSec": total, "tokensPerSecond": predicted / total, "stopReason": reason]
    }

    func testDecodeRateIsTokensOverGenerationTimeNotTheWholeRequest() {
        let reading = LMStudioStream.Reading(stats: stats(predicted: 451, first: 4.803, total: 39.607), at: 1)
        XCTAssertEqual(reading?.tokensPerSecond ?? 0, 12.93, accuracy: 0.01)   // LM Studio itself says 11.39
        XCTAssertEqual(reading?.promptTokens, 76_084)
        XCTAssertEqual(reading?.timeToFirstToken ?? 0, 4.803, accuracy: 0.0001)
        let second = LMStudioStream.Reading(stats: stats(predicted: 532, prompt: 76_630, first: 7.45, total: 47.778), at: 2)
        XCTAssertEqual(second?.tokensPerSecond ?? 0, 13.17, accuracy: 0.01)
    }

    func testAPredictionStoppedAFewTokensInDoesNotBecomeAnAbsurdRate() {
        // Eight tokens over a 60 ms window used to read as 117 tok/s.
        XCTAssertNil(LMStudioStream.Reading(stats: stats(predicted: 8, first: 30.0, total: 30.06, reason: "userStopped"), at: 1))
        XCTAssertNil(LMStudioStream.Reading(stats: stats(predicted: 8, first: 30.0, total: 30.06), at: 1), "too short even when it ended normally")
        XCTAssertNil(LMStudioStream.Reading(stats: stats(predicted: 40, first: 30.0, total: 30.9), at: 1), "window under a second")
    }

    func testStoppedPredictionsLeaveThePreviousReadingStanding() {
        for reason in ["userStopped", "modelUnloaded", "failed"] {
            XCTAssertNil(LMStudioStream.Reading(stats: stats(predicted: 400, first: 2, total: 30, reason: reason), at: 1), reason)
        }
        XCTAssertNotNil(LMStudioStream.Reading(stats: stats(predicted: 400, first: 2, total: 30, reason: "toolCalls"), at: 1))
    }
}
