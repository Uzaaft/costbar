const std = @import("std");
const http = @import("../http.zig");
const model = @import("../model.zig");
const money = @import("../money.zig");

pub const Credentials = struct {
    endpoint: []const u8,
    application_key: []const u8,
    application_secret: []const u8,
    consumer_key: []const u8,
    project_id: []const u8,

    fn validate(self: Credentials) !void {
        _ = try endpointBaseURL(self.endpoint);
        if (self.application_key.len == 0 or self.application_secret.len == 0 or
            self.consumer_key.len == 0 or self.project_id.len == 0)
        {
            return error.InvalidCredentials;
        }
        if (self.project_id.len > 128) return error.InvalidProjectId;
        for (self.project_id) |character| {
            if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_') continue;
            return error.InvalidProjectId;
        }
    }
};

const UsageLine = struct {
    id: []const u8,
    label: []const u8,
    amount_micros: i64,
    count: u64,
};

const Usage = struct {
    currency: []const u8,
    current_micros: i64,
    projected_micros: ?i64,
    updated_at_unix: i64,
    lines: []const UsageLine,
};

const OwnedUsage = struct {
    arena: std.heap.ArenaAllocator,
    usage: Usage,

    fn deinit(self: *OwnedUsage) void {
        self.arena.deinit();
    }
};

pub const OVHcloud = struct {
    owned: ?OwnedUsage = null,

    pub fn init() OVHcloud {
        return .{};
    }

    pub fn deinit(self: *OVHcloud) void {
        if (self.owned) |*owned| owned.deinit();
        self.owned = null;
    }

    pub fn metadata(_: *const OVHcloud) model.ProviderMetadata {
        return .{ .id = "ovh", .display_name = "OVHcloud", .kind = .cloud };
    }

    pub fn fetch(
        self: *OVHcloud,
        allocator: std.mem.Allocator,
        client: anytype,
        credentials: Credentials,
        received_at_unix: i64,
    ) !void {
        try credentials.validate();
        const base_url = try endpointBaseURL(credentials.endpoint);

        const time_url = try std.fmt.allocPrint(allocator, "{s}/auth/time", .{base_url});
        defer allocator.free(time_url);
        const time_response = try client.get(allocator, .{ .url = time_url });
        defer time_response.deinit(allocator);
        try time_response.requireSuccess();
        const timestamp = try std.fmt.parseInt(
            i64,
            std.mem.trim(u8, time_response.body, " \r\n\t"),
            10,
        );

        const current_url = try usageURL(allocator, base_url, credentials.project_id, "current");
        defer allocator.free(current_url);
        const current = try signedGet(allocator, client, credentials, current_url, timestamp);
        defer allocator.free(current);

        const forecast_url = try usageURL(allocator, base_url, credentials.project_id, "forecast");
        defer allocator.free(forecast_url);
        const forecast = signedGet(
            allocator,
            client,
            credentials,
            forecast_url,
            timestamp,
        ) catch null;
        defer if (forecast) |body| allocator.free(body);

        var replacement = try parseUsage(allocator, current, forecast, received_at_unix);
        errdefer replacement.deinit();
        if (self.owned) |*owned| owned.deinit();
        self.owned = replacement;
    }

    pub fn ingest(
        self: *OVHcloud,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "current")) return error.UnsupportedDocument;
        var replacement = try parseUsage(allocator, payload, null, received_at_unix);
        errdefer replacement.deinit();
        if (self.owned) |*owned| owned.deinit();
        self.owned = replacement;
    }

    pub fn collect(
        self: *OVHcloud,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const usage = if (self.owned) |owned| owned.usage else return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, usage.lines.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, usage.lines.len);
        errdefer allocator.free(line_items);

        for (usage.lines, 0..) |line, index| {
            resources[index] = .{
                .id = line.id,
                .name = line.label,
                .kind = "billed service",
                .status = .active,
                .quantity = @max(line.count, 1),
            };
            line_items[index] = .{
                .id = line.id,
                .description = line.label,
                .service = line.label,
                .amount_micros = line.amount_micros,
                .detail = "OVHcloud current usage",
            };
        }

        return .{
            .summary = .{
                .id = "ovh",
                .display_name = "OVHcloud",
                .kind = .cloud,
                .currency = usage.currency,
                .current_cost_micros = usage.current_micros,
                .projected_cost_micros = usage.projected_micros,
                .updated_at_unix = usage.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
        };
    }
};

fn endpointBaseURL(endpoint: []const u8) ![]const u8 {
    if (std.mem.eql(u8, endpoint, "ovh-eu")) return "https://eu.api.ovh.com/1.0";
    if (std.mem.eql(u8, endpoint, "ovh-ca")) return "https://ca.api.ovh.com/1.0";
    if (std.mem.eql(u8, endpoint, "ovh-us")) return "https://api.us.ovhcloud.com/1.0";
    return error.InvalidEndpoint;
}

fn usageURL(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    project_id: []const u8,
    kind: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/cloud/project/{s}/usage/{s}",
        .{ base_url, project_id, kind },
    );
}

fn signedGet(
    allocator: std.mem.Allocator,
    client: anytype,
    credentials: Credentials,
    url: []const u8,
    timestamp: i64,
) ![]u8 {
    const timestamp_text = try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
    defer allocator.free(timestamp_text);
    const signature_input = try std.fmt.allocPrint(
        allocator,
        "{s}+{s}+GET+{s}++{s}",
        .{ credentials.application_secret, credentials.consumer_key, url, timestamp_text },
    );
    defer allocator.free(signature_input);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(signature_input, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const signature = try std.fmt.allocPrint(allocator, "$1${s}", .{hex});
    defer allocator.free(signature);

    const headers = [_]std.http.Header{
        .{ .name = "X-Ovh-Application", .value = credentials.application_key },
        .{ .name = "X-Ovh-Consumer", .value = credentials.consumer_key },
        .{ .name = "X-Ovh-Timestamp", .value = timestamp_text },
        .{ .name = "X-Ovh-Signature", .value = signature },
    };
    const response = try client.get(allocator, .{
        .url = url,
        .privileged_headers = &headers,
    });
    defer response.deinit(allocator);
    try response.requireSuccess();
    return allocator.dupe(u8, response.body);
}

fn parseUsage(
    allocator: std.mem.Allocator,
    current_payload: []const u8,
    forecast_payload: ?[]const u8,
    received_at_unix: i64,
) !OwnedUsage {
    var owned = OwnedUsage{
        .arena = .init(allocator),
        .usage = undefined,
    };
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    const current = try std.json.parseFromSliceLeaky(std.json.Value, arena, current_payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    if (current != .object) return error.InvalidResponse;
    const current_price = try parsePrice(current.object.get("totalPrice") orelse
        return error.InvalidResponse);

    var lines: std.ArrayList(UsageLine) = .empty;
    try appendLegacyGroups(arena, &lines, current.object.get("hourlyUsage"), "hourly");
    try appendLegacyGroups(arena, &lines, current.object.get("monthlyUsage"), "monthly");
    try appendTypedResources(arena, &lines, current.object.get("resourcesUsage"));

    var attributed: i64 = 0;
    for (lines.items) |line| {
        attributed = std.math.add(i64, attributed, line.amount_micros) catch
            return error.AmountOverflow;
    }
    if (attributed != current_price.micros) {
        try lines.append(arena, .{
            .id = "ovh-other-usage",
            .label = "Other usage",
            .amount_micros = std.math.sub(i64, current_price.micros, attributed) catch
                return error.AmountOverflow,
            .count = 1,
        });
    }

    const projected = if (forecast_payload) |payload| forecast: {
        const forecast_value = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        }) catch break :forecast null;
        if (forecast_value != .object) break :forecast null;
        const price = parsePrice(forecast_value.object.get("totalPrice") orelse
            break :forecast null) catch break :forecast null;
        break :forecast price.micros;
    } else null;

    owned.usage = .{
        .currency = try arena.dupe(u8, current_price.currency),
        .current_micros = current_price.micros,
        .projected_micros = projected,
        .updated_at_unix = received_at_unix,
        .lines = try lines.toOwnedSlice(arena),
    };
    return owned;
}

const ParsedPrice = struct { currency: []const u8, micros: i64 };

fn parsePrice(value: std.json.Value) !ParsedPrice {
    if (value != .object) return error.InvalidResponse;
    const currency_value = value.object.get("currencyCode") orelse return error.InvalidResponse;
    if (currency_value != .string or currency_value.string.len == 0) return error.InvalidResponse;
    const amount = value.object.get("value") orelse return error.InvalidResponse;
    return .{
        .currency = currency_value.string,
        .micros = try parseNumberMicros(amount),
    };
}

fn parseNumberMicros(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string, .string => |text| money.parseRoundedMicros(text),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidResponse,
    };
}

fn appendLegacyGroups(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(UsageLine),
    maybe_value: ?std.json.Value,
    cadence: []const u8,
) !void {
    const value = maybe_value orelse return;
    if (value == .null) return;
    if (value != .object) return error.InvalidResponse;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const group = entry.value_ptr.*;
        var total: i64 = 0;
        var count: u64 = 0;
        if (group == .array) {
            for (group.array.items) |item| {
                const amount = try immediateTotalPrice(item);
                total = std.math.add(i64, total, amount) catch return error.AmountOverflow;
                count += 1;
            }
        } else if (group == .object) {
            total = try immediateTotalPrice(group);
            count = 1;
        } else continue;
        if (total == 0 and count == 0) continue;
        const label = try displayLabel(arena, entry.key_ptr.*);
        try lines.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "ovh-{s}-{s}", .{ cadence, entry.key_ptr.* }),
            .label = label,
            .amount_micros = total,
            .count = count,
        });
    }
}

fn appendTypedResources(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(UsageLine),
    maybe_value: ?std.json.Value,
) !void {
    const value = maybe_value orelse return;
    if (value == .null) return;
    if (value != .array) return error.InvalidResponse;
    for (value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidResponse;
        const kind_value = item.object.get("type") orelse return error.InvalidResponse;
        if (kind_value != .string) return error.InvalidResponse;
        const amount = try immediateTotalPrice(item);
        const resources = item.object.get("resources");
        const count: u64 = if (resources != null and resources.? == .array)
            @intCast(resources.?.array.items.len)
        else
            1;
        try lines.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "ovh-resource-{s}-{d}", .{ kind_value.string, index }),
            .label = try displayLabel(arena, kind_value.string),
            .amount_micros = amount,
            .count = count,
        });
    }
}

fn immediateTotalPrice(value: std.json.Value) !i64 {
    if (value != .object) return error.InvalidResponse;
    const price = value.object.get("totalPrice") orelse return 0;
    return switch (price) {
        .object => (try parsePrice(price)).micros,
        else => parseNumberMicros(price),
    };
}

fn displayLabel(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (raw, 0..) |character, index| {
        if (index > 0 and std.ascii.isUpper(character)) try output.append(arena, ' ');
        try output.append(arena, if (index == 0) std.ascii.toUpper(character) else character);
    }
    return output.toOwnedSlice(arena);
}

test "OVHcloud maps current usage groups and forecast" {
    var provider = OVHcloud.init();
    defer provider.deinit();
    const payload =
        \\{"totalPrice":{"currencyCode":"EUR","value":12.5},"hourlyUsage":{"instance":[{"totalPrice":7.5}],"volume":[{"totalPrice":2.0}]},"monthlyUsage":{"instance":[{"totalPrice":1.0}]},"resourcesUsage":[{"type":"object-storage","resources":[],"totalPrice":2.0}]}
    ;
    const owned = try parseUsage(std.testing.allocator, payload,
        \\{"totalPrice":{"currencyCode":"EUR","value":20.0}}
    , 100);
    provider.owned = owned;

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 12_500_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 20_000_000), report.summary.projected_cost_micros);
    try std.testing.expectEqual(@as(usize, 4), report.line_items.len);
}

test "OVHcloud signs current and forecast requests" {
    const Backend = struct {
        next: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            defer self.next += 1;
            return switch (self.next) {
                0 => .{ .status = 200, .body = try allocator.dupe(u8, "1700000000") },
                1, 2 => response: {
                    try std.testing.expectEqual(@as(usize, 4), request.privileged_headers.len);
                    try std.testing.expect(std.mem.startsWith(
                        u8,
                        request.privileged_headers[3].value,
                        "$1$",
                    ));
                    break :response .{
                        .status = 200,
                        .body = try allocator.dupe(u8,
                            \\{"totalPrice":{"currencyCode":"EUR","value":1.0}}
                        ),
                    };
                },
                else => return error.UnexpectedRequest,
            };
        }
    };
    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    var provider = OVHcloud.init();
    defer provider.deinit();
    try provider.fetch(std.testing.allocator, &client, .{
        .endpoint = "ovh-eu",
        .application_key = "app",
        .application_secret = "secret",
        .consumer_key = "consumer",
        .project_id = "project-1",
    }, 100);
    try std.testing.expectEqual(@as(usize, 3), backend.next);
}
