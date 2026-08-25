import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - LocalMetricsEngine
//
// On-device port of a simplified `compute_day` (server/ingest/app/analysis/daily.py).
// Reads local strap streams, detects sleep, writes dailyMetric + sleepSession so the
// existing UI can render without a server. ServerSync.pullDerived() still overwrites
// these rows when configured (server wins).

struct LocalMetricsEngine {
    let store: WhoopStore
    let deviceId: String

    /// Generous per-stream cap for the 30 h window (1 Hz × 30 h ≈ 108k).
    static let streamLimit = 200_000
    /// Trailing HR history for HRmax p99.5 (matches daily.py _HRMAX_HISTORY_DAYS).
    static let hrmaxHistoryDays = 90
    static let hrmaxHistoryLimit = 2_000_000
    /// Trailing daily rows used to seed recovery baselines.
    static let baselineDays = 30

    /// Recompute the last `lastNDays` UTC calendar days (oldest → newest) and upsert cache.
    func recompute(lastNDays: Int, now: Date = Date()) async {
        guard lastNDays > 0 else { return }
        let todayStart = AnalysisUTC.startOfDay(now)
        var days: [Date] = []
        for offset in (0..<lastNDays).reversed() {
            if let d = AnalysisUTC.calendar.date(byAdding: .day, value: -offset, to: todayStart) {
                days.append(d)
            }
        }
        let histStart = AnalysisUTC.calendar.date(
            byAdding: .day, value: -Self.hrmaxHistoryDays, to: todayStart)
            ?? todayStart.addingTimeInterval(-Double(Self.hrmaxHistoryDays) * 86_400)
        let histEnd = Int(todayStart.addingTimeInterval(86_400).timeIntervalSince1970)
        let hrHistory = ((try? await store.hrSamples(
            deviceId: deviceId,
            from: Int(histStart.timeIntervalSince1970),
            to: histEnd,
            limit: Self.hrmaxHistoryLimit)) ?? []).map { Double($0.bpm) }
        let age = ProfileStorage.load()?.age.map(Double.init)
        let (hrmax, source) = Strain.estimateHRMax(hrHistory, age: age)
        let effMaxHR: Double? = (source != "unknown" && hrmax > 0) ? hrmax : nil

        for dayStart in days {
            await computeDay(dayStart: dayStart, maxHR: effMaxHR)
        }
    }

    /// Run the pipeline for one UTC calendar day and upsert cache. No-op on empty days.
    func computeDay(dayStart: Date, maxHR: Double?) async {
        let day = AnalysisUTC.yyyyMMdd(from: dayStart)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let winStart = dayStart.addingTimeInterval(-6 * 3600)   // previous 18:00 UTC
        let from = Int(winStart.timeIntervalSince1970)
        let to = Int(dayEnd.timeIntervalSince1970) - 1          // half-open [start, end)

        let hr = (try? await store.hrSamples(deviceId: deviceId, from: from, to: to,
                                             limit: Self.streamLimit)) ?? []
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: from, to: to,
                                                    limit: Self.streamLimit)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: from, to: to,
                                               limit: Self.streamLimit)) ?? []

        let sessions = SleepDetection.detect(gravity: grav, hr: hr, rr: rr)
        let summary = SleepDetection.dailySummary(sessions: sessions, day: day)
        let nightSessions = sessions.filter { SleepDetection.utcDayString(from: $0.end) == day }

        let dayStartTs = Int(dayStart.timeIntervalSince1970)
        let dayEndTs = Int(dayEnd.timeIntervalSince1970)
        let hasDayStreams = hr.contains { $0.ts >= dayStartTs && $0.ts < dayEndTs }
            || grav.contains { $0.ts >= dayStartTs && $0.ts < dayEndTs }
        if nightSessions.isEmpty && !hasDayStreams { return }

        let nightEnd = summary.sleepEnd

        // Strain: wake → next sleep onset (WHOOP sleep-to-sleep day), else calendar day.
        let strainLo: Double
        let strainHi: Double
        if let nightEnd {
            strainLo = nightEnd
            let later = sessions.map(\.start).filter { $0 > nightEnd }
            strainHi = later.min() ?? Double(dayEndTs)
        } else {
            strainLo = Double(dayStartTs)
            strainHi = Double(dayEndTs)
        }
        let strainHR = hr.filter { Double($0.ts) >= strainLo && Double($0.ts) < strainHi }
        let restingForStrain = summary.restingHR ?? Strain.defaultRestingHR
        let strainVal = Strain.strain(hr: strainHR, maxHR: maxHR, restingHR: restingForStrain)

        // Recovery: needs ≥4 prior local nights with HRV.
        var recoveryFrac: Double? = nil
        if let hrv = summary.avgHRV, let rhr = summary.restingHR {
            let priorFrom = AnalysisUTC.calendar.date(
                byAdding: .day, value: -Self.baselineDays, to: dayStart) ?? dayStart
            let priorTo = AnalysisUTC.calendar.date(
                byAdding: .day, value: -1, to: dayStart) ?? dayStart
            let prior = (try? await store.dailyMetrics(
                deviceId: deviceId,
                from: AnalysisUTC.yyyyMMdd(from: priorFrom),
                to: AnalysisUTC.yyyyMMdd(from: priorTo))) ?? []
            let baselines = Recovery.baselines(fromPrior: prior)
            if let score = Recovery.score(hrv: hrv, rhr: rhr, baselines: baselines,
                                          sleepPerf: summary.efficiency) {
                recoveryFrac = score / 100.0   // DailyMetric.recovery is a 0–1 fraction
            }
        }

        let metric = DailyMetric(
            day: day,
            totalSleepMin: summary.totalSleepMin,
            efficiency: summary.efficiency,
            deepMin: summary.deepMin,
            remMin: summary.remMin,
            lightMin: summary.lightMin,
            disturbances: summary.disturbances,
            restingHr: summary.restingHR.map { Int($0.rounded()) },
            avgHrv: summary.avgHRV,
            recovery: recoveryFrac,
            strain: strainVal,
            exerciseCount: 0,
            spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)

        let cached: [CachedSleepSession] = nightSessions.map { s in
            CachedSleepSession(
                startTs: Int(s.start.rounded()),
                endTs: Int(s.end.rounded()),
                efficiency: s.efficiency,
                restingHr: s.restingHR.map { Int($0.rounded()) },
                avgHrv: s.avgHRV,
                stagesJSON: SleepDetection.encodeStagesJSON(s.stages))
        }

        _ = try? await store.upsertDailyMetrics([metric], deviceId: deviceId)
        if !cached.isEmpty {
            _ = try? await store.upsertSleepSessions(cached, deviceId: deviceId)
        }
    }
}
