import XCTest
import WhoopStore
import WhoopProtocol
@testable import OpenWhoop

@MainActor
final class MetricsRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo(store: WhoopStore) -> MetricsRepository {
        MetricsRepository(store: store, serverSync: nil, deviceId: "test-device")
    }

    private func seedDaily(_ store: WhoopStore) async throws -> [DailyMetric] {
        // Days must fall inside load()'s trailing 14-day UTC window.
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let d1 = fmt.string(from: now.addingTimeInterval(-2 * 86_400))
        let d2 = fmt.string(from: now.addingTimeInterval(-1 * 86_400))
        let days = [
            DailyMetric(day: d1, totalSleepMin: 400, efficiency: 0.85,
                        deepMin: 80, remMin: 100, lightMin: 220, disturbances: 2,
                        restingHr: 55, avgHrv: 58, recovery: 0.62, strain: 10, exerciseCount: 1),
            DailyMetric(day: d2, totalSleepMin: 430, efficiency: 0.90,
                        deepMin: 90, remMin: 110, lightMin: 230, disturbances: 1,
                        restingHr: 52, avgHrv: 65, recovery: 0.75, strain: 12, exerciseCount: 0),
        ]
        try await store.upsertDailyMetrics(days, deviceId: "test-device")
        return days
    }

    private func seedSleep(_ store: WhoopStore) async throws -> [CachedSleepSession] {
        // Timestamps in "now − a few days" range so load()'s 14-day window catches them.
        let now = Int(Date().timeIntervalSince1970)
        let sessions = [
            CachedSleepSession(startTs: now - 4 * 86_400, endTs: now - 4 * 86_400 + 28_800,
                               efficiency: 0.80, restingHr: 56, avgHrv: 55, stagesJSON: nil),
            CachedSleepSession(startTs: now - 1 * 86_400, endTs: now - 1 * 86_400 + 27_000,
                               efficiency: 0.88, restingHr: 53, avgHrv: 62, stagesJSON: nil),
        ]
        try await store.upsertSleepSessions(sessions, deviceId: "test-device")
        return sessions
    }

    // MARK: - load() sets today / lastNight to most-recent rows

    func testLoadSetsTodayToMostRecentDailyRow() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        let days = try await seedDaily(store)

        await repo.load()

        XCTAssertEqual(repo.today, days.last, "today must be the most-recent (last) daily row")
    }

    func testLoadSetsLastNightToMostRecentSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        let sessions = try await seedSleep(store)

        await repo.load()

        XCTAssertEqual(repo.lastNight, sessions.last, "lastNight must be the most-recent sleep session")
    }

    func testLoadReturnsNilWhenCacheEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        await repo.load()

        XCTAssertNil(repo.today)
        XCTAssertNil(repo.lastNight)
    }

    // MARK: - daily(fromDay:toDay:) returns seeded range

    func testDailyRangeReturnsCorrectRows() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        let days = try await seedDaily(store)

        // Full window — should get both rows.
        let all = await repo.daily(fromDay: "2000-01-01", toDay: "2099-12-31")
        XCTAssertEqual(all, days)

        // Narrow window — should get only the later row.
        let narrow = await repo.daily(fromDay: days[1].day, toDay: "2099-12-31")
        XCTAssertEqual(narrow, [days[1]])
    }

    func testDailyRangeReturnsEmptyWhenNoMatch() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        _ = try await seedDaily(store)

        let result = await repo.daily(fromDay: "2010-01-01", toDay: "2010-01-31")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - sleepSessions(from:to:limit:) returns seeded range

    func testSleepSessionsRangeReturnsCorrectRows() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        let sessions = try await seedSleep(store)

        let now = Int(Date().timeIntervalSince1970)
        let all = await repo.sleepSessions(from: now - 10 * 86_400, to: now + 86_400, limit: 100)
        XCTAssertEqual(all, sessions)

        // Limit to 1 — should get only the earlier session (ASC order).
        let limited = await repo.sleepSessions(from: now - 10 * 86_400, to: now + 86_400, limit: 1)
        XCTAssertEqual(limited, [sessions[0]])
    }

    // MARK: - sleepDetail() pairs latest session with correct daily row

    func testSleepDetailReturnsLatestSessionWithMatchingDailyRow() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        // Seed two sessions; endTs of the latest falls on a deterministic UTC day.
        let now = Int(Date().timeIntervalSince1970)
        let s1 = CachedSleepSession(startTs: now - 4 * 86_400, endTs: now - 4 * 86_400 + 28_800,
                                    efficiency: 0.80, restingHr: 56, avgHrv: 55, stagesJSON: nil)
        // Latest session: ensure endTs lands on today's UTC date so the daily row matches.
        let s2 = CachedSleepSession(startTs: now - 1 * 86_400, endTs: now - 1 * 86_400 + 27_000,
                                    efficiency: 0.88, restingHr: 53, avgHrv: 62,
                                    stagesJSON: "[{\"start\":0,\"end\":1,\"stage\":\"deep\"}]")
        try await store.upsertSleepSessions([s1, s2], deviceId: "test-device")

        // Derive the UTC day of s2.endTs to build a matching daily row.
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let s2Day = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(s2.endTs)))

        let daily = DailyMetric(day: s2Day, totalSleepMin: 450, efficiency: 0.88,
                                deepMin: 95, remMin: 115, lightMin: 240, disturbances: 1,
                                restingHr: 53, avgHrv: 62, recovery: 0.78, strain: 9, exerciseCount: 0,
                                spo2Pct: 96.8, skinTempDevC: 0.2, respRateBpm: 14.5)
        // Seed a daily row for a different day too (should NOT be returned).
        let otherDaily = DailyMetric(day: "2026-01-01", totalSleepMin: 300, efficiency: 0.70,
                                     deepMin: 50, remMin: 60, lightMin: 190, disturbances: 5,
                                     restingHr: 60, avgHrv: 45, recovery: 0.50, strain: 15, exerciseCount: 2)
        try await store.upsertDailyMetrics([daily, otherDaily], deviceId: "test-device")

        let result = await repo.sleepDetail()

        XCTAssertNotNil(result, "sleepDetail must return a result when sessions exist")
        XCTAssertEqual(result?.session, s2, "sleepDetail must return the latest session")
        XCTAssertNotNil(result?.daily, "sleepDetail must pair the daily row for the session's endTs day")
        XCTAssertEqual(result?.daily?.day, s2Day)
        let pairedDaily = try XCTUnwrap(result?.daily)
        XCTAssertEqual(try XCTUnwrap(pairedDaily.spo2Pct), 96.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pairedDaily.skinTempDevC), 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pairedDaily.respRateBpm), 14.5, accuracy: 0.001)
    }

    func testSleepDetailReturnsNilWhenNoSessions() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        let result = await repo.sleepDetail()
        XCTAssertNil(result, "sleepDetail must return nil when the cache is empty")
    }

    func testSleepDetailDailyIsNilWhenNoDailyRowForThatDay() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        let now = Int(Date().timeIntervalSince1970)
        let session = CachedSleepSession(startTs: now - 86_400, endTs: now - 86_400 + 25_000,
                                         efficiency: 0.85, restingHr: 54, avgHrv: 60, stagesJSON: nil)
        try await store.upsertSleepSessions([session], deviceId: "test-device")
        // Intentionally do NOT seed any daily row.

        let result = await repo.sleepDetail()
        XCTAssertNotNil(result, "sleepDetail returns the session even without a daily row")
        XCTAssertEqual(result?.session, session)
        XCTAssertNil(result?.daily, "daily must be nil when no matching row exists")
    }

    // MARK: - sevenNightSleepWake() count + ordering

    func testSevenNightSleepWakeReturnsCorrectCountOldestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        // Seed 10 sessions spread over the last 12 days, 1 per day.
        let now = Int(Date().timeIntervalSince1970)
        var sessions: [CachedSleepSession] = []
        for i in 0..<10 {
            let start = now - (10 - i) * 86_400
            sessions.append(CachedSleepSession(startTs: start, endTs: start + 25_200,
                                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil))
        }
        try await store.upsertSleepSessions(sessions, deviceId: "test-device")

        let result = await repo.sevenNightSleepWake(nights: 7)

        XCTAssertEqual(result.count, 7, "sevenNightSleepWake must return exactly 7 sessions")
        // Verify oldest→newest ordering (startTs monotonically increasing).
        for i in 1..<result.count {
            XCTAssertLessThan(result[i - 1].startTs, result[i].startTs,
                              "sessions must be ordered oldest→newest")
        }
        // The 7 returned must be the 7 most-recent of the 10 seeded.
        XCTAssertEqual(result.map { $0.startTs }, sessions.suffix(7).map { $0.startTs })
    }

    func testSevenNightSleepWakeReturnsEmptyWhenNoSessions() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        let result = await repo.sevenNightSleepWake(nights: 7)
        XCTAssertTrue(result.isEmpty, "sevenNightSleepWake must return [] when no sessions cached")
    }

    func testSevenNightSleepWakeReturnsAllWhenFewerThanNights() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)

        let now = Int(Date().timeIntervalSince1970)
        let session = CachedSleepSession(startTs: now - 2 * 86_400, endTs: now - 2 * 86_400 + 28_000,
                                         efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        try await store.upsertSleepSessions([session], deviceId: "test-device")

        let result = await repo.sevenNightSleepWake(nights: 7)
        XCTAssertEqual(result.count, 1, "returns all available sessions when fewer than nights")
        XCTAssertEqual(result[0], session)
    }

    // MARK: - refresh() with nil serverSync does not crash; isRefreshing ends false

    func testRefreshWithNilServerSyncDoesNotCrashAndLoadsCache() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        _ = try await seedDaily(store)
        _ = try await seedSleep(store)

        await repo.refresh()

        XCTAssertFalse(repo.isRefreshing, "isRefreshing must be false after refresh completes")
        XCTAssertNotNil(repo.today, "refresh must still populate today from cache")
        XCTAssertNotNil(repo.lastNight, "refresh must still populate lastNight from cache")
    }

    // MARK: - refresh() with serverSync nil fills cache from local streams

    func testRefreshFillsCacheFromSyntheticStreamsWhenServerSyncNil() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "test-device", mac: nil, name: "test")
        let repo = makeRepo(store: store)

        // Plant a still night whose end falls on today's UTC date, inside the 30 h window.
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let todayStart = utc.startOfDay(for: Date())
        let sleepStart = Int(todayStart.timeIntervalSince1970) + 2 * 3600  // 02:00 UTC
        let minutes = 90
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        var rr: [RRInterval] = []
        for i in 0..<(minutes * 60) {
            let ts = sleepStart + i
            hr.append(HRSample(ts: ts, bpm: 54))
            grav.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
            rr.append(RRInterval(ts: ts, rrMs: 1050 + (i % 2 == 0 ? 12 : -12)))
        }
        _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: grav), deviceId: "test-device")

        XCTAssertNil(repo.today)
        XCTAssertNil(repo.lastNight)

        await repo.refresh()

        XCTAssertFalse(repo.isRefreshing)
        XCTAssertNotNil(repo.lastNight, "local recompute must write a sleepSession from still gravity")
        XCTAssertNotNil(repo.today, "local recompute must write a dailyMetric for the night's end day")
        XCTAssertGreaterThan(repo.lastNight?.endTs ?? 0, repo.lastNight?.startTs ?? 0)
        XCTAssertGreaterThan(repo.today?.totalSleepMin ?? 0, 50)
        XCTAssertNotNil(repo.today?.restingHr)
        XCTAssertNotNil(repo.today?.avgHrv)
        XCTAssertNil(repo.today?.recovery, "recovery stays nil until ≥4 local nights")
        XCTAssertNil(repo.today?.deepMin)
        XCTAssertNil(repo.today?.remMin)
        let stages = repo.lastNight?.stagesJSON ?? ""
        XCTAssertTrue(stages.contains("light"), "binary hypnogram should include light")
    }

    func testHRSeriesReadsLocalSamplesAndDownsamples() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = makeRepo(store: store)
        var hr: [HRSample] = []
        for i in 0..<1000 {
            hr.append(HRSample(ts: 1_700_000_000 + i, bpm: 60 + (i % 5)))
        }
        _ = try await store.insert(Streams(hr: hr), deviceId: "test-device")

        let points = await repo.hrSeries(fromEpoch: 1_700_000_000, toEpoch: 1_700_001_000,
                                         maxPoints: 50)
        XCTAssertEqual(points.count, 50)
        XCTAssertEqual(points.first?.value, 60)
        XCTAssertEqual(Int(points.last?.value ?? 0), 60 + (999 % 5))
    }
}
