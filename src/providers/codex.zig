const std = @import("std");
const local_ai = @import("local_ai.zig");

pub const Codex = local_ai.LocalAI("codex", "Codex");

test "Codex reports local tokens and subscription allowance without adding cost" {
    var provider = Codex.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "usage",
        \\{
        \\  "period":{"start_unix":1,"end_exclusive_unix":200},
        \\  "token_usage":{"input_tokens":100,"output_tokens":20,"reasoning_tokens":5},
        \\  "allowance_windows":[{"id":"primary","label":"5 hour","used_percent":40,"resets_at_unix":150}],
        \\  "models":["gpt-codex"],
        \\  "source":"local Codex sessions"
        \\}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.summary.contributes_to_totals);
    try std.testing.expectEqual(@as(u64, 125), report.token_usage.?.total());
    try std.testing.expectEqual(@as(usize, 1), report.allowance_windows.len);
}
