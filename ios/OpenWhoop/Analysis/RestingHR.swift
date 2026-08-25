import Foundation
import WhoopProtocol

// MARK: - RestingHR
//
// Exact port of sleep.py `_session_resting_hr` / recovery.py `resting_hr`:
// lowest 5-minute tumbling-window mean HR during the sleep window.

enum RestingHR {
    /// Rolling-mean HR window (seconds).
    static let windowS: Double = 5 * 60

    /// Lowest 5-min tumbling-window mean HR (bpm) in [start, end], or nil if no samples.
    static func lowest(hr: [HRSample], start: Double, end: Double) -> Double? {
        let seg: [(Double, Double)] = hr.compactMap { row in
            let ts = Double(row.ts)
            guard ts >= start, ts <= end else { return nil }
            return (ts, Double(row.bpm))
        }
        guard !seg.isEmpty else { return nil }

        var means: [Double] = []
        var t = start
        while t < end {
            let winEnd = t + windowS
            let win = seg.compactMap { ts, bpm -> Double? in
                (ts >= t && ts < winEnd) ? bpm : nil
            }
            if !win.isEmpty {
                means.append(win.reduce(0, +) / Double(win.count))
            }
            t += windowS
        }
        if means.isEmpty {
            return seg.reduce(0.0) { $0 + $1.1 } / Double(seg.count)
        }
        return means.min()
    }
}
