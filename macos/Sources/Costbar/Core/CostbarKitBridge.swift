import CostbarKit
import Foundation

extension UnsafeRawBufferPointer {
    /// Borrows this buffer as the byte slice the Zig core expects. Valid only
    /// for the duration of the enclosing `withUnsafeBytes` call.
    var costbarBytes: costbar_bytes_t {
        .init(ptr: bindMemory(to: UInt8.self).baseAddress, len: count)
    }
}
