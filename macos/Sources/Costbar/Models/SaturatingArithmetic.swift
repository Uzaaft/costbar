import Foundation

// Totals are summed from provider APIs and local session logs that Costbar does
// not validate, so every aggregate clamps instead of trapping on overflow.

extension Int64 {
    func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other >= 0 ? .max : .min
    }
}

extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

extension Sequence where Element == Int64 {
    var saturatingSum: Int64 { reduce(0) { $0.saturatingAdding($1) } }
}

extension Sequence where Element == UInt64 {
    var saturatingSum: UInt64 { reduce(0) { $0.saturatingAdding($1) } }
}
