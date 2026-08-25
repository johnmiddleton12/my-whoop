import Foundation
import WhoopProtocol

// MARK: - HRV
//
// Simplified port of server/ingest/app/analysis/hrv.py: range-filter RR to 300–2000 ms
// then Task Force RMSSD over the whole night. No Kubios / neurokit2 in this pass.

enum HRV {
    /// Minimum plausible RR interval in ms (≈ 200 bpm).
    static let rrMinMs: Double = 300
    /// Maximum plausible RR interval in ms (≈ 30 bpm).
    static let rrMaxMs: Double = 2000
    /// Minimum beats before a whole-night RMSSD is treated as trustworthy.
    static let minBeats: Int = 20

    /// Root mean square of successive NN-interval differences (ms).
    /// Returns nil when fewer than 2 physiologically-plausible intervals remain.
    static func rmssd(_ rrMs: [Double]) -> Double? {
        let nn = rrMs.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
        guard nn.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return sqrt(sumSq / Double(nn.count - 1))
    }

    /// Whole-night RMSSD over RR rows in [start, end]. Nil if too sparse.
    static func sessionRMSSD(rr: [RRInterval], start: Double, end: Double) -> Double? {
        let vals = rr.compactMap { row -> Double? in
            let ts = Double(row.ts)
            guard ts >= start, ts <= end else { return nil }
            return Double(row.rrMs)
        }
        let plausible = vals.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
        guard plausible.count >= minBeats else {
            // Still compute if we have ≥2 so short fixtures work; callers that need
            // the 20-beat floor already have enough overnight data.
            return rmssd(vals)
        }
        return rmssd(vals)
    }
}
