const std = @import("std");

pub const micros_per_unit: i64 = 1_000_000;

pub const ParseError = error{
    EmptyAmount,
    InvalidAmount,
    AmountOverflow,
    PrecisionLoss,
};

/// Parses a base-10 currency amount into fixed-point micros without passing
/// through floating point. More than six fractional digits are accepted only
/// when the excess digits are zero.
pub fn parseMicros(input: []const u8) ParseError!i64 {
    if (input.len == 0) return error.EmptyAmount;

    var negative = false;
    var cursor: usize = 0;
    if (input[0] == '-' or input[0] == '+') {
        negative = input[0] == '-';
        cursor = 1;
    }
    if (cursor == input.len) return error.InvalidAmount;

    const unsigned = input[cursor..];
    const dot = std.mem.indexOfScalar(u8, unsigned, '.');
    const whole_text = if (dot) |index| unsigned[0..index] else unsigned;
    const fraction_text = if (dot) |index| unsigned[index + 1 ..] else "";
    if (whole_text.len == 0 and fraction_text.len == 0) return error.InvalidAmount;
    if (std.mem.indexOfScalar(u8, fraction_text, '.') != null) return error.InvalidAmount;

    const whole = if (whole_text.len == 0)
        0
    else
        std.fmt.parseUnsigned(u64, whole_text, 10) catch return error.InvalidAmount;

    var fraction: u64 = 0;
    const retained = @min(fraction_text.len, 6);
    if (retained > 0) {
        fraction = std.fmt.parseUnsigned(u64, fraction_text[0..retained], 10) catch
            return error.InvalidAmount;
    }
    for (fraction_text[retained..]) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidAmount;
        if (digit != '0') return error.PrecisionLoss;
    }
    for (retained..6) |_| fraction *= 10;

    const magnitude = @as(i128, whole) * micros_per_unit + fraction;
    const signed = if (negative) -magnitude else magnitude;
    if (signed < std.math.minInt(i64) or signed > std.math.maxInt(i64)) {
        return error.AmountOverflow;
    }
    return @intCast(signed);
}

/// Parses provider-supplied decimals that may use exponent notation or more
/// than six fractional digits. The value is rounded once at the external
/// boundary; callers continue to use exact fixed-point micros internally.
pub fn parseRoundedMicros(input: []const u8) ParseError!i64 {
    return parseMicros(input) catch |err| switch (err) {
        error.PrecisionLoss, error.InvalidAmount => {
            const amount = std.fmt.parseFloat(f128, input) catch
                return error.InvalidAmount;
            if (!std.math.isFinite(amount)) return error.InvalidAmount;

            const rounded = @round(amount * micros_per_unit);
            if (rounded < std.math.minInt(i64) or rounded > std.math.maxInt(i64)) {
                return error.AmountOverflow;
            }
            return @intFromFloat(rounded);
        },
        else => return err,
    };
}

/// Renders fixed-point micros as a plain two-decimal amount ("60.00"), for
/// labels where the currency is already stated elsewhere.
pub const Decimal = struct {
    micros: i64,

    pub fn format(self: Decimal, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const signed: i128 = self.micros;
        const magnitude: u128 = @intCast(if (signed < 0) -signed else signed);
        const unit: u128 = micros_per_unit;
        if (signed < 0) try writer.writeByte('-');
        try writer.print("{d}.{d:0>2}", .{
            magnitude / unit,
            (magnitude % unit) / 10_000,
        });
    }
};

test "micros render as a two-decimal amount" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "60.00",
        try std.fmt.bufPrint(&buffer, "{f}", .{Decimal{ .micros = 60_000_000 }}),
    );
    try std.testing.expectEqualStrings(
        "-0.05",
        try std.fmt.bufPrint(&buffer, "{f}", .{Decimal{ .micros = -50_000 }}),
    );
}

test "decimal currency strings parse exactly to micros" {
    try std.testing.expectEqual(@as(i64, 12_340_000), try parseMicros("12.34"));
    try std.testing.expectEqual(@as(i64, -500_001), try parseMicros("-0.500001"));
    try std.testing.expectEqual(@as(i64, 2_000_000), try parseMicros("2"));
    try std.testing.expectEqual(@as(i64, 1_200_000), try parseMicros("1.2000000"));
    try std.testing.expectError(error.PrecisionLoss, parseMicros("0.0000001"));
    try std.testing.expectError(error.InvalidAmount, parseMicros("1.2.3"));
}

test "provider decimals round to micros" {
    try std.testing.expectEqual(@as(i64, 1), try parseRoundedMicros("6e-7"));
    try std.testing.expectEqual(@as(i64, 1_234_568), try parseRoundedMicros("1.2345678"));
    try std.testing.expectError(error.InvalidAmount, parseRoundedMicros("nan"));
}
