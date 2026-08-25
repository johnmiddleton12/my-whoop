import XCTest
import WhoopProtocol
@testable import OpenWhoop

final class SleepDetectionTests: XCTestCase {

    private let t0 = 1_700_000_000

    private func stillGravity(start: Int, minutes: Int, hz: Int = 1) -> [GravitySample] {
        let n = minutes * 60 * hz
        let step = 1.0 / Double(hz)
        return (0..<n).map { i in
            GravitySample(ts: start + Int(Double(i) * step), x: 0, y: 0, z: 1)
        }
    }

    private func stillHR(start: Int, minutes: Int, bpm: Int = 55, hz: Int = 1) -> [HRSample] {
        let n = minutes * 60 * hz
        let step = 1.0 / Double(hz)
        return (0..<n).map { i in
            HRSample(ts: start + Int(Double(i) * step), bpm: bpm)
        }
    }

    private func activeGravity(start: Int, minutes: Int) -> [GravitySample] {
        let n = minutes * 60
        return (0..<n).map { i in
            let v = i % 2 == 0 ? 1.0 : -1.0
            return GravitySample(ts: start + i, x: v, y: 0, z: 0)
        }
    }

    func testGravityDeltasFirstIsZeroAndL2() {
        let rows = [
            GravitySample(ts: 0, x: 0, y: 0, z: 0),
            GravitySample(ts: 1, x: 3, y: 4, z: 0),
        ]
        let d = SleepDetection.gravityDeltas(rows)
        XCTAssertEqual(d[0], 0, accuracy: 1e-12)
        XCTAssertEqual(d[1], 5, accuracy: 1e-12)
    }

    func testStillRunProducesOneSession() {
        let minutes = 90
        let grav = stillGravity(start: t0, minutes: minutes)
        let hr = stillHR(start: t0, minutes: minutes, bpm: 54)
        let sessions = SleepDetection.detect(gravity: grav, hr: hr)

        XCTAssertEqual(sessions.count, 1, "a long still gravity run must yield one sleep session")
        let s = sessions[0]
        XCTAssertGreaterThan(s.end - s.start, Double(SleepDetection.minSleepMin * 60))
        XCTAssertGreaterThan(s.efficiency, 0.9)
        XCTAssertFalse(s.stages.isEmpty)
        XCTAssertTrue(s.stages.contains { $0.stage == "light" },
                      "binary hypnogram maps sleep to light")
        XCTAssertNotNil(s.restingHR)
        XCTAssertEqual(s.restingHR ?? 0, 54, accuracy: 1.0)
    }

    func testJitteringGravityProducesNoSession() {
        let grav = activeGravity(start: t0, minutes: 90)
        let hr = stillHR(start: t0, minutes: 90, bpm: 95)
        let sessions = SleepDetection.detect(gravity: grav, hr: hr)
        XCTAssertTrue(sessions.isEmpty, "active gravity must not be classified as sleep")
    }

    func testShortStillRunIsRejected() {
        let grav = stillGravity(start: t0, minutes: 20)
        let hr = stillHR(start: t0, minutes: 20, bpm: 54)
        let sessions = SleepDetection.detect(gravity: grav, hr: hr)
        XCTAssertTrue(sessions.isEmpty, "runs shorter than MIN_SLEEP_MIN must be dropped")
    }

    func testHRFallbackDetectsOvernightLowHR() {
        let hr = stillHR(start: t0, minutes: 90, bpm: 52)
        let sessions = SleepDetection.detect(gravity: [], hr: hr)
        XCTAssertEqual(sessions.count, 1, "low stable HR with no gravity should still detect a night")
    }
}

final class HRVTests: XCTestCase {

    func testRMSSDKnownSeries() throws {
        // rr=[800, 820, 810, 830]; sq_diffs=[400,100,400]; mean=300; sqrt≈17.320508
        let result = try XCTUnwrap(HRV.rmssd([800, 820, 810, 830]))
        XCTAssertEqual(result, 17.320508, accuracy: 1e-5)
    }

    func testRMSSDFiltersOutOfRange() throws {
        // 100 and 5000 dropped; remaining [800, 820] → diff 20 → RMSSD 20
        let result = try XCTUnwrap(HRV.rmssd([100, 800, 820, 5000]))
        XCTAssertEqual(result, 20, accuracy: 1e-9)
    }

    func testRMSSDNilWhenFewerThanTwoPlausible() {
        XCTAssertNil(HRV.rmssd([800]))
        XCTAssertNil(HRV.rmssd([100, 250, 2500]))
        XCTAssertNil(HRV.rmssd([]))
    }

    func testRMSSDIncludesBoundaries() {
        let result = HRV.rmssd([300, 2000])
        XCTAssertNotNil(result)
        XCTAssertEqual(result ?? 0, 1700, accuracy: 1e-9)
    }
}
