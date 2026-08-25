const std = @import("std");
const http = @import("../http.zig");
const model = @import("../model.zig");
const money = @import("../money.zig");

const api_base = "https://api.hetzner.cloud/v1";

pub const Credentials = struct {
    token: []const u8,

    fn validate(self: Credentials) !void {
        if (self.token.len == 0) return error.InvalidCredentials;
    }
};

const PriceAmount = struct {
    net: []const u8,
    gross: []const u8,
};

const LocationPrice = struct {
    location: []const u8,
    price_hourly: ?PriceAmount = null,
    price_monthly: ?PriceAmount = null,
};

const TypePricing = struct {
    id: u64 = 0,
    name: []const u8 = "",
    type: []const u8 = "",
    prices: []const LocationPrice,
};

const Pricing = struct {
    currency: []const u8,
    vat_rate: []const u8 = "0",
    primary_ips: []const TypePricing = &.{},
    floating_ips: []const TypePricing = &.{},
    image: struct { price_per_gb_month: PriceAmount },
    volume: struct { price_per_gb_month: PriceAmount },
    server_backup: struct { percentage: []const u8 },
    server_types: []const TypePricing = &.{},
    load_balancer_types: []const TypePricing = &.{},
};

const Location = struct { name: []const u8 };
const TypeRef = struct { id: u64 = 0, name: []const u8 = "" };

const Server = struct {
    id: u64,
    name: []const u8,
    status: []const u8,
    created: []const u8,
    location: Location,
    server_type: TypeRef,
    backup_window: ?[]const u8 = null,
};

const Volume = struct {
    id: u64,
    name: []const u8,
    status: []const u8,
    size: u64,
    created: []const u8,
    location: Location,
};

const LoadBalancer = struct {
    id: u64,
    name: []const u8,
    created: []const u8,
    location: Location,
    load_balancer_type: TypeRef,
};

const IP = struct {
    id: u64,
    name: ?[]const u8 = null,
    type: []const u8,
    created: []const u8,
    location: Location,
};

const Image = struct {
    id: u64,
    name: ?[]const u8 = null,
    type: []const u8,
    created: []const u8,
    image_size: ?f64 = null,
};

const Billable = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    status: model.ResourceStatus,
    quantity: u64 = 1,
    created_at_unix: i64,
    hourly_micros: ?i64 = null,
    monthly_micros: i64,
};

const Account = struct {
    currency: []const u8,
    vat_rate: []const u8,
    billables: []const Billable,
    updated_at_unix: i64,
};

const OwnedAccount = struct {
    arena: std.heap.ArenaAllocator,
    account: Account,

    fn deinit(self: *OwnedAccount) void {
        self.arena.deinit();
    }
};

pub const Hetzner = struct {
    owned: ?OwnedAccount = null,

    pub fn init() Hetzner {
        return .{};
    }

    pub fn deinit(self: *Hetzner) void {
        if (self.owned) |*owned| owned.deinit();
        self.owned = null;
    }

    pub fn metadata(_: *const Hetzner) model.ProviderMetadata {
        return .{ .id = "hetzner", .display_name = "Hetzner", .kind = .cloud };
    }

    pub fn fetch(
        self: *Hetzner,
        allocator: std.mem.Allocator,
        client: anytype,
        credentials: Credentials,
        received_at_unix: i64,
    ) !void {
        try credentials.validate();
        var replacement = OwnedAccount{ .arena = .init(allocator), .account = undefined };
        errdefer replacement.deinit();
        const arena = replacement.arena.allocator();

        const pricing_body = try fetchBody(allocator, client, credentials.token, api_base ++ "/pricing");
        defer allocator.free(pricing_body);
        const PricingResponse = struct { pricing: Pricing };
        const pricing_response = try std.json.parseFromSliceLeaky(
            PricingResponse,
            arena,
            pricing_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        );

        const servers = try fetchPages(Server, arena, allocator, client, credentials.token, "servers", "/servers");
        const volumes = try fetchPages(Volume, arena, allocator, client, credentials.token, "volumes", "/volumes");
        const load_balancers = try fetchPages(LoadBalancer, arena, allocator, client, credentials.token, "load_balancers", "/load_balancers");
        const primary_ips = try fetchPages(IP, arena, allocator, client, credentials.token, "primary_ips", "/primary_ips");
        const floating_ips = try fetchPages(IP, arena, allocator, client, credentials.token, "floating_ips", "/floating_ips");
        const images = try fetchPages(Image, arena, allocator, client, credentials.token, "images", "/images?type=snapshot");

        replacement.account = try buildAccount(
            arena,
            pricing_response.pricing,
            servers,
            volumes,
            load_balancers,
            primary_ips,
            floating_ips,
            images,
            received_at_unix,
        );
        if (self.owned) |*owned| owned.deinit();
        self.owned = replacement;
    }

    pub fn ingest(
        self: *Hetzner,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "snapshot")) return error.UnsupportedDocument;
        const Snapshot = struct {
            pricing: Pricing,
            servers: []const Server = &.{},
            volumes: []const Volume = &.{},
            load_balancers: []const LoadBalancer = &.{},
            primary_ips: []const IP = &.{},
            floating_ips: []const IP = &.{},
            images: []const Image = &.{},
        };
        var replacement = OwnedAccount{ .arena = .init(allocator), .account = undefined };
        errdefer replacement.deinit();
        const arena = replacement.arena.allocator();
        const snapshot = try std.json.parseFromSliceLeaky(Snapshot, arena, payload, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        replacement.account = try buildAccount(
            arena,
            snapshot.pricing,
            snapshot.servers,
            snapshot.volumes,
            snapshot.load_balancers,
            snapshot.primary_ips,
            snapshot.floating_ips,
            snapshot.images,
            received_at_unix,
        );
        if (self.owned) |*owned| owned.deinit();
        self.owned = replacement;
    }

    pub fn collect(
        self: *Hetzner,
        allocator: std.mem.Allocator,
        period: model.Period,
    ) !model.ProviderReport {
        try period.validate();
        const account = if (self.owned) |owned| owned.account else return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, account.billables.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, account.billables.len);
        errdefer allocator.free(line_items);

        var current_total: i64 = 0;
        var projected_total: i64 = 0;
        for (account.billables, 0..) |billable, index| {
            const current = try estimatedCost(billable, period, account.updated_at_unix);
            current_total = std.math.add(i64, current_total, current) catch
                return error.AmountOverflow;
            projected_total = std.math.add(i64, projected_total, billable.monthly_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = billable.id,
                .name = billable.name,
                .kind = billable.kind,
                .status = billable.status,
                .quantity = billable.quantity,
            };
            line_items[index] = .{
                .id = billable.id,
                .description = billable.name,
                .service = billable.kind,
                .amount_micros = current,
                .detail = "estimated from current inventory · gross incl. VAT",
            };
        }

        return .{
            .summary = .{
                .id = "hetzner",
                .display_name = "Hetzner",
                .kind = .cloud,
                .currency = account.currency,
                .current_cost_micros = current_total,
                .projected_cost_micros = projected_total,
                .updated_at_unix = account.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
        };
    }
};

fn fetchBody(
    allocator: std.mem.Allocator,
    client: anytype,
    token: []const u8,
    url: []const u8,
) ![]u8 {
    const response = try client.get(allocator, .{ .url = url, .bearer_token = token });
    defer response.deinit(allocator);
    try response.requireSuccess();
    return allocator.dupe(u8, response.body);
}

fn fetchPages(
    comptime Item: type,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    client: anytype,
    token: []const u8,
    field_name: []const u8,
    path: []const u8,
) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    var page: u64 = 1;
    while (true) : (page += 1) {
        if (page > 100) return error.TooManyPages;
        const separator: u8 = if (std.mem.indexOfScalar(u8, path, '?') == null) '?' else '&';
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{c}page={d}&per_page=50",
            .{ api_base, path, separator, page },
        );
        defer allocator.free(url);
        const body = try fetchBody(allocator, client, token, url);
        defer allocator.free(body);

        var page_arena: std.heap.ArenaAllocator = .init(allocator);
        defer page_arena.deinit();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, page_arena.allocator(), body, .{
            .allocate = .alloc_always,
        });
        if (root != .object) return error.InvalidResponse;
        const raw_items = root.object.get(field_name) orelse return error.InvalidResponse;
        if (raw_items != .array) return error.InvalidResponse;
        for (raw_items.array.items) |value| {
            try items.append(arena, try std.json.parseFromValueLeaky(Item, arena, value, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }));
        }

        const meta = root.object.get("meta") orelse break;
        if (meta != .object) break;
        const pagination = meta.object.get("pagination") orelse break;
        if (pagination != .object) break;
        const next_page = pagination.object.get("next_page") orelse break;
        if (next_page == .null) break;
        if (next_page != .integer or next_page.integer <= 0) return error.InvalidResponse;
        page = @intCast(next_page.integer - 1);
    }
    return items.toOwnedSlice(arena);
}

fn buildAccount(
    arena: std.mem.Allocator,
    pricing: Pricing,
    servers: []const Server,
    volumes: []const Volume,
    load_balancers: []const LoadBalancer,
    primary_ips: []const IP,
    floating_ips: []const IP,
    images: []const Image,
    updated_at_unix: i64,
) !Account {
    var billables: std.ArrayList(Billable) = .empty;
    const backup_percentage = std.fmt.parseFloat(f64, pricing.server_backup.percentage) catch
        return error.InvalidResponse;

    for (servers) |server| {
        const prices = try findTypePrice(
            pricing.server_types,
            server.server_type,
            server.location.name,
        );
        const monthly = try grossMicros(prices.price_monthly orelse return error.InvalidResponse);
        const hourly = try grossMicros(prices.price_hourly orelse return error.InvalidResponse);
        const id = try std.fmt.allocPrint(arena, "hetzner-server-{d}", .{server.id});
        try billables.append(arena, .{
            .id = id,
            .name = server.name,
            .kind = "Servers",
            .status = if (std.mem.eql(u8, server.status, "running")) .active else .inactive,
            .created_at_unix = parseIso8601(server.created) catch 0,
            .hourly_micros = hourly,
            .monthly_micros = monthly,
        });
        if (server.backup_window != null) {
            try billables.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "{s}-backup", .{id}),
                .name = try std.fmt.allocPrint(arena, "{s} backups", .{server.name}),
                .kind = "Backups",
                .status = .active,
                .created_at_unix = parseIso8601(server.created) catch 0,
                .hourly_micros = try percentageOf(hourly, backup_percentage),
                .monthly_micros = try percentageOf(monthly, backup_percentage),
            });
        }
    }

    const volume_per_gb = try grossMicros(pricing.volume.price_per_gb_month);
    for (volumes) |volume| {
        try billables.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "hetzner-volume-{d}", .{volume.id}),
            .name = volume.name,
            .kind = "Volumes",
            .status = if (std.mem.eql(u8, volume.status, "available") or
                std.mem.eql(u8, volume.status, "creating")) .active else .warning,
            .quantity = volume.size,
            .created_at_unix = parseIso8601(volume.created) catch 0,
            .monthly_micros = try multiplyMicros(volume_per_gb, volume.size),
        });
    }

    for (load_balancers) |load_balancer| {
        const prices = try findTypePrice(
            pricing.load_balancer_types,
            load_balancer.load_balancer_type,
            load_balancer.location.name,
        );
        try billables.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "hetzner-load-balancer-{d}", .{load_balancer.id}),
            .name = load_balancer.name,
            .kind = "Load Balancers",
            .status = .active,
            .created_at_unix = parseIso8601(load_balancer.created) catch 0,
            .hourly_micros = try grossMicros(prices.price_hourly orelse return error.InvalidResponse),
            .monthly_micros = try grossMicros(prices.price_monthly orelse return error.InvalidResponse),
        });
    }

    try appendIPs(arena, &billables, primary_ips, pricing.primary_ips, true);
    try appendIPs(arena, &billables, floating_ips, pricing.floating_ips, false);

    const image_per_gb = try grossMicros(pricing.image.price_per_gb_month);
    for (images) |snapshot| {
        if (!std.mem.eql(u8, snapshot.type, "snapshot")) continue;
        const size = snapshot.image_size orelse continue;
        const monthly_float = @as(f128, @floatFromInt(image_per_gb)) * size;
        if (monthly_float > std.math.maxInt(i64)) return error.AmountOverflow;
        try billables.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "hetzner-snapshot-{d}", .{snapshot.id}),
            .name = snapshot.name orelse "Snapshot",
            .kind = "Snapshots",
            .status = .active,
            .created_at_unix = parseIso8601(snapshot.created) catch 0,
            .monthly_micros = @intFromFloat(@round(monthly_float)),
        });
    }

    return .{
        .currency = pricing.currency,
        .vat_rate = pricing.vat_rate,
        .billables = try billables.toOwnedSlice(arena),
        .updated_at_unix = updated_at_unix,
    };
}

fn appendIPs(
    arena: std.mem.Allocator,
    billables: *std.ArrayList(Billable),
    ips: []const IP,
    pricing: []const TypePricing,
    hourly: bool,
) !void {
    for (ips) |ip| {
        const prices = try findIPPrice(pricing, ip.type, ip.location.name);
        try billables.append(arena, .{
            .id = try std.fmt.allocPrint(
                arena,
                "hetzner-{s}-ip-{d}",
                .{ if (hourly) "primary" else "floating", ip.id },
            ),
            .name = ip.name orelse if (hourly) "Primary IP" else "Floating IP",
            .kind = if (hourly) "Primary IPs" else "Floating IPs",
            .status = .active,
            .created_at_unix = parseIso8601(ip.created) catch 0,
            .hourly_micros = if (hourly)
                try grossMicros(prices.price_hourly orelse return error.InvalidResponse)
            else
                null,
            .monthly_micros = try grossMicros(prices.price_monthly orelse return error.InvalidResponse),
        });
    }
}

fn findTypePrice(
    types: []const TypePricing,
    reference: TypeRef,
    location: []const u8,
) !LocationPrice {
    for (types) |entry| {
        if ((reference.id != 0 and entry.id == reference.id) or
            (reference.name.len > 0 and std.mem.eql(u8, entry.name, reference.name)))
        {
            return findLocationPrice(entry.prices, location);
        }
    }
    return error.PriceNotFound;
}

fn findIPPrice(types: []const TypePricing, ip_type: []const u8, location: []const u8) !LocationPrice {
    for (types) |entry| {
        if (std.mem.eql(u8, entry.type, ip_type)) return findLocationPrice(entry.prices, location);
    }
    return error.PriceNotFound;
}

fn findLocationPrice(prices: []const LocationPrice, location: []const u8) !LocationPrice {
    for (prices) |price| {
        if (std.mem.eql(u8, price.location, location)) return price;
    }
    return error.PriceNotFound;
}

fn grossMicros(price: PriceAmount) !i64 {
    return money.parseRoundedMicros(price.gross);
}

fn multiplyMicros(value: i64, quantity: u64) !i64 {
    if (quantity > std.math.maxInt(i64)) return error.AmountOverflow;
    return std.math.mul(i64, value, @intCast(quantity)) catch error.AmountOverflow;
}

fn percentageOf(value: i64, percentage: f64) !i64 {
    const result = @as(f128, @floatFromInt(value)) * percentage / 100.0;
    if (result > std.math.maxInt(i64) or result < std.math.minInt(i64)) {
        return error.AmountOverflow;
    }
    return @intFromFloat(@round(result));
}

fn estimatedCost(billable: Billable, period: model.Period, now: i64) !i64 {
    const start = @max(period.start_unix, billable.created_at_unix);
    const end = @min(period.end_exclusive_unix, now);
    if (end <= start) return 0;
    if (billable.hourly_micros) |hourly| {
        const seconds = @as(u64, @intCast(end - start));
        const hours = (seconds + 3599) / 3600;
        const hourly_total = try multiplyMicros(hourly, hours);
        return @min(hourly_total, billable.monthly_micros);
    }
    const elapsed: i128 = end - start;
    const duration: i128 = period.end_exclusive_unix - period.start_unix;
    const numerator = @as(i128, billable.monthly_micros) * elapsed;
    const estimate = @divTrunc(numerator + @divTrunc(duration, 2), duration);
    if (estimate > std.math.maxInt(i64) or estimate < std.math.minInt(i64)) {
        return error.AmountOverflow;
    }
    return @intCast(estimate);
}

fn parseIso8601(text: []const u8) !i64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':') return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(i64, text[5..7], 10);
    const day = try std.fmt.parseInt(i64, text[8..10], 10);
    const hour = try std.fmt.parseInt(i64, text[11..13], 10);
    const minute = try std.fmt.parseInt(i64, text[14..16], 10);
    const second = try std.fmt.parseInt(i64, text[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) {
        return error.InvalidTimestamp;
    }
    return daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
}

fn daysFromCivil(input_year: i64, month: i64, day: i64) i64 {
    const year = input_year - @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

test "Hetzner estimates current inventory with hourly caps and gross prices" {
    var provider = Hetzner.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "snapshot",
        \\{"pricing":{"currency":"EUR","vat_rate":"19.00","primary_ips":[],"floating_ips":[],"image":{"price_per_gb_month":{"net":"0.01","gross":"0.012"}},"volume":{"price_per_gb_month":{"net":"0.04","gross":"0.048"}},"server_backup":{"percentage":"20.00"},"server_types":[{"id":1,"name":"cx22","prices":[{"location":"fsn1","price_hourly":{"net":"0.01","gross":"0.012"},"price_monthly":{"net":"4.00","gross":"4.76"}}]}],"load_balancer_types":[]},"servers":[{"id":1,"name":"api","status":"running","created":"2026-08-01T00:00:00Z","location":{"name":"fsn1"},"server_type":{"id":1,"name":"cx22"},"backup_window":"22-02"}],"volumes":[{"id":2,"name":"data","status":"available","size":10,"created":"2026-08-01T00:00:00Z","location":{"name":"fsn1"}}]}
    , try parseIso8601("2026-08-25T00:00:00Z"));
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = try parseIso8601("2026-08-01T00:00:00Z"),
        .end_exclusive_unix = try parseIso8601("2026-09-01T00:00:00Z"),
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("EUR", report.summary.currency);
    try std.testing.expectEqual(@as(usize, 3), report.resources.len);
    try std.testing.expect(report.summary.current_cost_micros > 0);
    try std.testing.expectEqual(@as(?i64, 6_192_000), report.summary.projected_cost_micros);
    try std.testing.expectEqualStrings("estimated from current inventory · gross incl. VAT", report.line_items[0].detail.?);
}

test "Hetzner follows JSON pagination through the comptime client" {
    const Backend = struct {
        next: usize = 0,
        pub fn get(self: *@This(), allocator: std.mem.Allocator, request: http.Request) !http.Response {
            try std.testing.expectEqualStrings("token", request.bearer_token.?);
            defer self.next += 1;
            return switch (self.next) {
                0 => .{ .status = 200, .body = try allocator.dupe(u8,
                    \\{"servers":[{"id":1,"name":"one","status":"running","created":"2026-08-01T00:00:00Z","location":{"name":"fsn1"},"server_type":{"id":1,"name":"cx22"}}],"meta":{"pagination":{"next_page":2}}}
                ) },
                1 => .{ .status = 200, .body = try allocator.dupe(u8,
                    \\{"servers":[],"meta":{"pagination":{"next_page":null}}}
                ) },
                else => return error.UnexpectedRequest,
            };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    const servers = try fetchPages(Server, arena.allocator(), std.testing.allocator, &client, "token", "servers", "/servers");
    try std.testing.expectEqual(@as(usize, 1), servers.len);
    try std.testing.expectEqual(@as(usize, 2), backend.next);
}
