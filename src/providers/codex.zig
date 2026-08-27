const std = @import("std");
const http = @import("../http.zig");
const local_usage = @import("../local_usage.zig");
const local_ai = @import("local_ai.zig");

pub const Codex = local_ai.LocalAI("codex", "Codex");

const auth_file_limit = 2 * 1024 * 1024;
const usage_url = "https://chatgpt.com/backend-api/wham/usage";

/// The signed-in Codex CLI owns this credential. Costbar only reads it and
/// never redeems the refresh token or writes `auth.json`.
pub const OAuthCredentials = struct {
    arena: std.heap.ArenaAllocator,
    access_token: []const u8,
    account_id: ?[]const u8,

    pub fn deinit(self: *OAuthCredentials) void {
        self.arena.deinit();
    }
};

const RawTokens = struct {
    access_token: ?[]const u8 = null,
    accessToken: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    accountId: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    idToken: ?[]const u8 = null,
};

const RawAuth = struct {
    tokens: ?RawTokens = null,
};

const RawUsageWindow = struct {
    used_percent: f64,
    reset_at: ?i64 = null,
    limit_window_seconds: ?i64 = null,
};

const RawUsage = struct {
    rate_limit: ?struct {
        primary_window: ?RawUsageWindow = null,
        secondary_window: ?RawUsageWindow = null,
    } = null,
};

pub fn loadOAuthCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_home: []const u8,
) !OAuthCredentials {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);
    const contents = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        allocator,
        .limited(auth_file_limit),
    ) catch |err| return switch (err) {
        error.FileNotFound => error.CodexAuthNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CodexAuthUnreadable,
    };
    defer allocator.free(contents);
    return parseOAuthCredentials(allocator, contents);
}

pub fn parseOAuthCredentials(
    allocator: std.mem.Allocator,
    contents: []const u8,
) !OAuthCredentials {
    var result = OAuthCredentials{
        .arena = .init(allocator),
        .access_token = undefined,
        .account_id = null,
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const raw = std.json.parseFromSliceLeaky(RawAuth, arena, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.CodexAuthInvalid;
    const tokens = raw.tokens orelse return error.CodexAuthMissingToken;
    result.access_token = nonEmpty(tokens.access_token) orelse
        nonEmpty(tokens.accessToken) orelse
        return error.CodexAuthMissingToken;
    result.account_id = nonEmpty(tokens.account_id) orelse
        nonEmpty(tokens.accountId) orelse
        accountIdFromJWT(arena, nonEmpty(tokens.id_token) orelse nonEmpty(tokens.idToken)) orelse
        accountIdFromJWT(arena, result.access_token);
    return result;
}

/// Fetches the same OAuth-backed quota document used by CodexBar. The account
/// header is privileged so the HTTP transport cannot forward it across an
/// origin-changing redirect.
pub fn fetchOAuthLimits(
    allocator: std.mem.Allocator,
    standard_client: *std.http.Client,
    credentials: OAuthCredentials,
    now: i64,
) !local_usage.Limits {
    var backend = http.StdBackend{ .client = standard_client };
    var client = http.Client(http.StdBackend).init(&backend);
    return fetchOAuthLimitsWithClient(allocator, &client, credentials, now);
}

pub fn fetchOAuthLimitsWithClient(
    allocator: std.mem.Allocator,
    client: anytype,
    credentials: OAuthCredentials,
    now: i64,
) !local_usage.Limits {
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "Costbar" },
    };
    const account_header = [_]std.http.Header{.{
        .name = "ChatGPT-Account-Id",
        .value = credentials.account_id orelse "",
    }};
    const response = try client.get(allocator, .{
        .url = usage_url,
        .bearer_token = credentials.access_token,
        .extra_headers = &headers,
        .privileged_headers = if (credentials.account_id != null) &account_header else &.{},
    });
    defer response.deinit(allocator);
    try response.requireSuccess();

    var parsed = std.json.parseFromSlice(RawUsage, allocator, response.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidCodexUsageResponse;
    defer parsed.deinit();
    const rate_limit = parsed.value.rate_limit orelse
        return error.CodexUsageMissingLimits;
    const primary = try usageWindow(rate_limit.primary_window);
    const secondary = try usageWindow(rate_limit.secondary_window);
    if (primary == null and secondary == null) return error.CodexUsageMissingLimits;
    return .{
        .timestamp = now,
        .primary = primary,
        .secondary = secondary,
    };
}

fn usageWindow(raw: ?RawUsageWindow) !?local_usage.Window {
    const value = raw orelse return null;
    if (!std.math.isFinite(value.used_percent) or
        value.used_percent < 0 or value.used_percent > 100)
    {
        return error.InvalidCodexUsageResponse;
    }
    const duration_minutes: ?i64 = if (value.limit_window_seconds) |seconds| blk: {
        if (seconds <= 0) return error.InvalidCodexUsageResponse;
        const minutes: i64 = @divFloor(seconds, @as(i64, std.time.s_per_min));
        break :blk @max(@as(i64, 1), minutes);
    } else null;
    return .{
        .used_percent = value.used_percent,
        .resets_at_unix = value.reset_at,
        .duration_minutes = duration_minutes,
    };
}

fn accountIdFromJWT(allocator: std.mem.Allocator, maybe_token: ?[]const u8) ?[]const u8 {
    const token = nonEmpty(maybe_token) orelse return null;
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const encoded_payload = parts.next() orelse return null;
    _ = parts.next() orelse return null;
    if (parts.next() != null) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_size = decoder.calcSizeForSlice(encoded_payload) catch return null;
    const payload = allocator.alloc(u8, decoded_size) catch return null;
    decoder.decode(payload, encoded_payload) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    }) catch return null;
    const root = switch (parsed) {
        .object => |object| object,
        else => return null,
    };
    if (jsonString(root.get("chatgpt_account_id"))) |account_id| return account_id;
    if (root.get("https://api.openai.com/auth")) |auth_value| {
        const auth = switch (auth_value) {
            .object => |object| object,
            else => null,
        };
        if (auth) |object| {
            if (jsonString(object.get("chatgpt_account_id"))) |account_id| return account_id;
        }
    }
    if (root.get("organizations")) |organizations_value| {
        const organizations = switch (organizations_value) {
            .array => |array| array,
            else => return null,
        };
        for (organizations.items) |organization_value| {
            const organization = switch (organization_value) {
                .object => |object| object,
                else => continue,
            };
            if (jsonString(organization.get("id"))) |account_id| return account_id;
        }
    }
    return null;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |string| nonEmpty(string),
        else => null,
    };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const found = value orelse return null;
    const trimmed = std.mem.trim(u8, found, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

test "Codex reports local tokens and subscription allowance without adding cost" {
    var provider = Codex.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "usage",
        \\{
        \\  "period":{"start_unix":1,"end_exclusive_unix":200},
        \\  "token_usage":{"input_tokens":100,"output_tokens":20,"reasoning_tokens":5},
        \\  "token_usage_windows":[{"id":"hour","label":"Last hour","period":{"start_unix":100,"end_exclusive_unix":200},"token_usage":{"input_tokens":40,"output_tokens":10}}],
        \\  "token_usage_series":[{"id":"hour","label":"Last hour","period":{"start_unix":100,"end_exclusive_unix":200},"buckets":[{"period":{"start_unix":100,"end_exclusive_unix":150},"token_usage":{"input_tokens":10}},{"period":{"start_unix":150,"end_exclusive_unix":200},"token_usage":{"output_tokens":5}}]}],
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
    try std.testing.expectEqual(@as(usize, 1), report.token_usage_windows.len);
    try std.testing.expectEqual(@as(u64, 50), report.token_usage_windows[0].total());
    try std.testing.expectEqual(@as(usize, 1), report.token_usage_series.len);
    try std.testing.expectEqual(@as(usize, 2), report.token_usage_series[0].buckets.len);
    try std.testing.expectEqual(@as(u64, 5), report.token_usage_series[0].buckets[1].total());
    try std.testing.expectEqual(@as(usize, 1), report.allowance_windows.len);
}

test "Codex reads OAuth credentials from auth.json and recovers an account from JWT" {
    var credentials = try parseOAuthCredentials(std.testing.allocator,
        \\{
        \\  "tokens": {
        \\    "accessToken": "access-token",
        \\    "idToken": "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0X2p3dCJ9.signature"
        \\  }
        \\}
    );
    defer credentials.deinit();

    try std.testing.expectEqualStrings("access-token", credentials.access_token);
    try std.testing.expectEqualStrings("acct_jwt", credentials.account_id.?);
}

test "Codex OAuth quota uses CodexBar authentication before local fallback" {
    const Backend = struct {
        pub fn get(
            _: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            try std.testing.expectEqualStrings(usage_url, request.url);
            try std.testing.expectEqualStrings("access-token", request.bearer_token.?);
            try std.testing.expectEqual(@as(usize, 1), request.privileged_headers.len);
            try std.testing.expectEqualStrings(
                "ChatGPT-Account-Id",
                request.privileged_headers[0].name,
            );
            try std.testing.expectEqualStrings("acct_123", request.privileged_headers[0].value);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8,
                    \\{"rate_limit":{"primary_window":{"used_percent":25,"reset_at":200,"limit_window_seconds":18000},"secondary_window":{"used_percent":50.5,"reset_at":300,"limit_window_seconds":604800}}}
                ),
            };
        }
    };

    var credentials = try parseOAuthCredentials(std.testing.allocator,
        \\{"tokens":{"access_token":"access-token","account_id":"acct_123"}}
    );
    defer credentials.deinit();
    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    const limits = try fetchOAuthLimitsWithClient(
        std.testing.allocator,
        &client,
        credentials,
        100,
    );

    try std.testing.expectEqual(@as(i64, 100), limits.timestamp);
    try std.testing.expectEqual(@as(f64, 25), limits.primary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 300), limits.primary.?.duration_minutes.?);
    try std.testing.expectEqual(@as(f64, 50.5), limits.secondary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 10_080), limits.secondary.?.duration_minutes.?);
}
