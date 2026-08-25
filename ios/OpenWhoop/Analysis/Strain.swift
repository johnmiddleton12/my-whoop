import Foundation
import WhoopProtocol

// MARK: - Strain
//
// Port of server/ingest/app/analysis/strain.py: Edwards TRIMP → 0–21 log map.
// HRmax from observed p99.5, Tanaka (if age known), or 220 − default age.

enum Strain {
    static let minReadings = 600
    static let maxStrain: Double = 21.0
    /// D such that 24 h in zone 5 (TRIMP 7200) maps to 21.
    static let strainDenominator: Double = 7201.0
    static let fallbackSampleMin: Double = 1.0 / 60.0
    static let defaultAge = 30
    static let defaultRestingHR: Double = 60
    static let hrmaxMinSamples = 600
    static let hrmaxPercentile: Double = 99.5

    private static let edwardsZones: [(Double, Int)] = [
        (90, 5), (80, 4), (70, 3), (60, 2), (50, 1),
    ]

    static func tanakaHRMax(age: Double) -> Double {
        208.0 - 0.7 * age
    }

    static func defaultMaxHR(age: Int = defaultAge) -> Double {
        Double(220 - age)
    }

    /// Estimate personalized HRmax. Returns (bpm, source).
    static func estimateHRMax(_ history: [Double], age: Double?) -> (Double, String) {
        let n = history.count
        let tanaka = age.map { tanakaHRMax(age: $0) }
        if n >= hrmaxMinSamples {
            let observed = percentile(history.sorted(), hrmaxPercentile)
            if let tanaka {
                return observed >= tanaka ? (observed, "observed") : (tanaka, "tanaka")
            }
            return (observed, "observed")
        }
        if let tanaka { return (tanaka, "tanaka") }
        return (0, "unknown")
    }

    /// Edwards TRIMP strain over the given HR window. Nil if too few samples or invalid HRR.
    static func strain(hr: [HRSample],
                       maxHR: Double?,
                       restingHR: Double = defaultRestingHR) -> Double? {
        let maxHR = maxHR ?? defaultMaxHR()
        guard hr.count >= minReadings, maxHR > restingHR else { return nil }
        let sampleMin = sampleDurationMinutes(hr)
        let reserve = maxHR - restingHR
        var weighted = 0
        for sample in hr {
            weighted += zoneWeight(Double(sample.bpm), restingHR: restingHR, reserve: reserve)
        }
        let trimp = Double(weighted) * sampleMin
        return trimpToStrain(trimp)
    }

    // MARK: Internals

    private static func percentile(_ sorted: [Double], _ pct: Double) -> Double {
        let n = sorted.count
        if n == 1 { return sorted[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sorted[lower] + frac * (sorted[upper] - sorted[lower])
    }

    private static func zoneWeight(_ bpm: Double, restingHR: Double, reserve: Double) -> Int {
        let pct = (bpm - restingHR) / reserve * 100.0
        for (threshold, weight) in edwardsZones {
            if pct >= threshold { return weight }
        }
        return 0
    }

    private static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let delta = abs(Double(hr[1].ts) - Double(hr[0].ts))
        return delta > 0 ? delta / 60.0 : fallbackSampleMin
    }

    private static func trimpToStrain(_ trimp: Double) -> Double {
        guard trimp > 0 else { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(strainDenominator)
        return (value * 100).rounded() / 100   // 2 decimal places
    }
}
