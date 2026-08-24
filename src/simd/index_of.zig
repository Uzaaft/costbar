const std = @import("std");

/// Returns the first index of `needle` in `input`.
///
/// This is a pure-Zig port of Ghostty's `src/simd/index_of` algorithm: compare
/// a vector of bytes at a time, return the first matching lane, then scan the
/// tail scalarly. Ghostty's implementation uses Google Highway for runtime
/// dispatch; Costbar uses a 128-bit vector so the same Zig code lowers to NEON
/// on Apple Silicon and SSE on Intel Macs without adding a C++ dependency.
///
/// Ghostty is Copyright (c) 2024 Mitchell Hashimoto and contributors and is
/// distributed under the MIT License. See THIRD_PARTY_NOTICES.md.
pub fn indexOf(input: []const u8, needle: u8) ?usize {
    const lanes = 16;
    const Vector = @Vector(lanes, u8);
    const needle_vector: Vector = @splat(needle);

    var offset: usize = 0;
    while (offset + lanes <= input.len) : (offset += lanes) {
        const input_vector: Vector = input[offset..][0..lanes].*;
        const matches = input_vector == needle_vector;
        if (!@reduce(.Or, matches)) continue;

        const mask: u16 = @bitCast(matches);
        return offset + @ctz(mask);
    }

    const tail = std.mem.indexOfScalar(u8, input[offset..], needle) orelse return null;
    return offset + tail;
}

test "indexOf matches scalar search at every vector alignment" {
    var input: [160]u8 = undefined;
    for (0..input.len) |needle_offset| {
        @memset(&input, 'a');
        input[needle_offset] = '\n';

        try std.testing.expectEqual(
            std.mem.indexOfScalar(u8, &input, '\n'),
            indexOf(&input, '\n'),
        );
    }
}

test "indexOf handles empty, short, and missing inputs" {
    try std.testing.expectEqual(null, indexOf("", '\n'));
    try std.testing.expectEqual(@as(?usize, 2), indexOf("ab\nc", '\n'));
    try std.testing.expectEqual(null, indexOf("no newline", '\n'));
}
