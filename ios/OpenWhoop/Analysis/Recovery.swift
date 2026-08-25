import Foundation
import WhoopStore

// MARK: - Recovery
//
// Port of server/ingest/app/analysis/recovery.py `recovery_score` (z-score + logistic).
// Returns a 0–100 score, or nil when the HRV baseline is not yet usable (< 4 nights).
// Callers store DailyMetric.recovery as a 0–1 fraction (score / 100).

enum Recovery {
    static let minNightsSeed = 4
    static let wHRV: Double = 0.60
    static let wRHR: Double = 0.20
    static let wResp: Double = 0.05
    static let wSleep: Double = 0.15
    static let logisticK: Double = 1.6
    static let logisticZ0: Double = -0.20
    static let sleepPerfCenter: Double = 0.85
    static let sleepPerfScale: Double = 0.12
    /// σ_floor for HRV (ms) — baselines.py METRIC_CFG["hrv"].floor_spread
    static let hrvFloorSpread: Double = 5.0
    /// σ_floor for resting HR (bpm)
    static let rhrFloorSpread: Double = 2.0

    struct Baselines {
        var hrvMean: Double?
        var hrvSpread: Double
        var rhrMean: Double?
        var rhrSpread: Double
        /// False until ≥ minNightsSeed valid HRV nights exist.
        var hrvUsable: Bool
    }

    /// Build simple mean baselines from prior daily rows (oldest → newest).
    static func baselines(fromPrior prior: [DailyMetric]) -> Baselines {
        let hrvVals = prior.compactMap(\.avgHrv)
        let rhrVals = prior.compactMap { $0.restingHr.map(Double.init) }
        return Baselines(
            hrvMean: mean(hrvVals),
            hrvSpread: hrvFloorSpread,
            rhrMean: mean(rhrVals),
            rhrSpread: rhrFloorSpread,
            hrvUsable: hrvVals.count >= minNightsSeed)
    }

    /// Z-score + logistic recovery in [0, 100], or nil on cold-start / no terms.
    static func score(hrv: Double,
                      rhr: Double,
                      resp: Double? = nil,
                      baselines: Baselines,
                      sleepPerf: Double? = nil) -> Double? {
        guard baselines.hrvUsable else { return nil }

        var terms: [(z: Double, w: Double)] = []
        if let mean = baselines.hrvMean {
            terms.append((zScore(hrv, mean: mean, spread: baselines.hrvSpread), wHRV))
        }
        if let mean = baselines.rhrMean {
            // Lower RHR is better → (μ − x) / σ
            terms.append((zScore(mean, mean: rhr, spread: baselines.rhrSpread), wRHR))
        }
        if let sleepPerf {
            terms.append(((sleepPerf - sleepPerfCenter) / sleepPerfScale, wSleep))
        }
        // Resp omitted unless a calibrated baseline exists (we don't persist nightly resp).
        _ = resp

        guard !terms.isEmpty else { return nil }
        let totalW = terms.reduce(0.0) { $0 + $1.w }
        guard totalW > 0 else { return nil }
        let z = terms.reduce(0.0) { $0 + $1.z * $1.w } / totalW
        let raw = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0, min(100, raw))
    }

    private static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    private static func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}
