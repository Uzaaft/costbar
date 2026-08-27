const std = @import("std");
const http = @import("../http.zig");
const model = @import("../model.zig");
const money = @import("../money.zig");

const api_prefix = "https://api.cloudflare.com/client/v4/";

pub const Credentials = struct {
    token: []const u8,
    account_id: []const u8,

    fn validate(self: Credentials) !void {
        if (self.token.len == 0) return error.InvalidCredentials;
        if (self.account_id.len != 32) return error.InvalidAccountId;
        for (self.account_id) |character| {
            if (!std.ascii.isHex(character)) return error.InvalidAccountId;
        }
    }
};

pub const Scope = enum {
    account,
    zone,

    /// Breakdown group the services of this scope are listed under.
    pub fn group(self: Scope) []const u8 {
        return switch (self) {
            .account => "Subscriptions",
            .zone => "Zone plans",
        };
    }

    pub fn resourceKind(self: Scope) []const u8 {
        return switch (self) {
            .account => "subscription",
            .zone => "zone",
        };
    }
};

pub const Service = struct {
    id: []const u8,
    name: []const u8,
    usage_label: []const u8,
    /// Monthly-equivalent price. Cloudflare quotes every subscription at its own
    /// billing cadence, so a yearly plan only contributes a twelfth per month.
    amount_micros: i64,
    enabled: bool,
    scope: Scope = .account,
    /// Set when the service is billed against a specific zone, so the same plan
    /// arriving from both the account and the zone feed is only counted once.
    zone_id: ?[]const u8 = null,
};

/// One usage-priced Cloudflare SKU for the current billing period. The
/// billable-usage API returns one row per charge period, so parsing keeps only
/// the newest cumulative values for each SKU/subscription/zone combination.
const BillableUsageItem = struct {
    id: []const u8,
    name: []const u8,
    service_name: []const u8,
    family: []const u8,
    detail: []const u8,
    amount_micros: i64,
    subscription_id: ?[]const u8,
    zone_id: ?[]const u8,
    zone_name: ?[]const u8,
    charge_period_end: []const u8,
    cumulative_quantity: []const u8,
    pricing_unit: []const u8,
};

/// One parsed API document together with the arena holding its strings.
const Document = struct {
    arena: std.heap.ArenaAllocator,
    services: []const Service,
    currency: ?[]const u8,
    updated_at_unix: i64,

    fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

const BillableUsageDocument = struct {
    arena: std.heap.ArenaAllocator,
    items: []const BillableUsageItem,
    currency: ?[]const u8,
    updated_at_unix: i64,

    fn deinit(self: *BillableUsageDocument) void {
        self.arena.deinit();
    }
};

pub const Cloudflare = struct {
    /// Account-level subscriptions: Workers Paid, R2, Images, Access, …
    subscriptions: ?Document = null,
    /// Per-zone plan tiers, which the account subscriptions feed omits.
    zone_plans: ?Document = null,
    /// Metered product usage and invoice-facing overage cost for the current
    /// Cloudflare billing period.
    billable_usage: ?BillableUsageDocument = null,

    pub fn init() Cloudflare {
        return .{};
    }

    pub fn deinit(self: *Cloudflare) void {
        if (self.subscriptions) |*document| document.deinit();
        if (self.zone_plans) |*document| document.deinit();
        if (self.billable_usage) |*document| document.deinit();
        self.subscriptions = null;
        self.zone_plans = null;
        self.billable_usage = null;
    }

    pub fn metadata(_: *const Cloudflare) model.ProviderMetadata {
        return .{
            .id = "cloudflare",
            .display_name = "Cloudflare",
            .kind = .cloud,
        };
    }

    /// Fetches the account's live subscriptions, billable usage, and zone plans
    /// through the compile-time HTTP interface. The usage and zone feeds are
    /// best effort: usage is available only to supported PayGo accounts and a
    /// token without Zone Read still produces an account-level report.
    pub fn fetch(
        self: *Cloudflare,
        allocator: std.mem.Allocator,
        client: anytype,
        credentials: Credentials,
        received_at_unix: i64,
    ) !void {
        try credentials.validate();

        const subscriptions_url = try std.fmt.allocPrint(
            allocator,
            api_prefix ++ "accounts/{s}/subscriptions",
            .{credentials.account_id},
        );
        defer allocator.free(subscriptions_url);

        var replacement_subscriptions = blk: {
            const response = try client.get(allocator, .{
                .url = subscriptions_url,
                .bearer_token = credentials.token,
            });
            defer response.deinit(allocator);
            try response.requireSuccess();
            break :blk try parseSubscriptions(allocator, response.body, received_at_unix);
        };
        errdefer replacement_subscriptions.deinit();

        var replacement_usage: ?BillableUsageDocument = usage: {
            const usage_url = try std.fmt.allocPrint(
                allocator,
                api_prefix ++ "accounts/{s}/billable-usage",
                .{credentials.account_id},
            );
            defer allocator.free(usage_url);
            const response = client.get(allocator, .{
                .url = usage_url,
                .bearer_token = credentials.token,
            }) catch break :usage null;
            defer response.deinit(allocator);
            response.requireSuccess() catch break :usage null;
            break :usage try parseBillableUsage(
                allocator,
                response.body,
                received_at_unix,
            );
        };
        errdefer if (replacement_usage) |*document| document.deinit();

        var replacement_zones: ?Document = fetchAllZones(
            allocator,
            client,
            credentials,
            received_at_unix,
        ) catch null;
        errdefer if (replacement_zones) |*document| document.deinit();

        replace(&self.subscriptions, replacement_subscriptions);
        if (replacement_usage) |document| replaceBillableUsage(&self.billable_usage, document);
        if (replacement_zones) |document| replace(&self.zone_plans, document);
    }

    pub fn ingest(
        self: *Cloudflare,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (std.mem.eql(u8, document_id, "subscriptions")) {
            replace(
                &self.subscriptions,
                try parseSubscriptions(allocator, payload, received_at_unix),
            );
            return;
        }
        if (std.mem.eql(u8, document_id, "zones")) {
            replace(
                &self.zone_plans,
                try parseZones(allocator, payload, received_at_unix),
            );
            return;
        }
        if (std.mem.eql(u8, document_id, "billable-usage")) {
            replaceBillableUsage(
                &self.billable_usage,
                try parseBillableUsage(allocator, payload, received_at_unix),
            );
            return;
        }
        return error.UnsupportedDocument;
    }

    fn replace(slot: *?Document, replacement: Document) void {
        if (slot.*) |*existing| existing.deinit();
        slot.* = replacement;
    }

    fn replaceBillableUsage(
        slot: *?BillableUsageDocument,
        replacement: BillableUsageDocument,
    ) void {
        if (slot.*) |*existing| existing.deinit();
        slot.* = replacement;
    }

    pub fn collect(
        self: *Cloudflare,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        if (self.subscriptions == null and
            self.zone_plans == null and
            self.billable_usage == null)
        {
            return error.NotFetched;
        }

        const merged = try self.mergedServices(allocator);
        defer allocator.free(merged);
        const usage_items = if (self.billable_usage) |document| document.items else &.{};

        const resources = try allocator.alloc(model.Resource, merged.len + usage_items.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, merged.len + usage_items.len);
        errdefer allocator.free(line_items);

        var total_micros: i64 = 0;
        for (merged, 0..) |service, index| {
            total_micros = std.math.add(i64, total_micros, service.amount_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = service.id,
                .name = service.name,
                .kind = service.scope.resourceKind(),
                .status = if (service.enabled) .active else .inactive,
            };
            line_items[index] = .{
                .id = service.id,
                .description = service.name,
                .service = service.scope.group(),
                .amount_micros = service.amount_micros,
                .detail = service.usage_label,
            };
        }
        for (usage_items, merged.len..) |item, index| {
            total_micros = std.math.add(i64, total_micros, item.amount_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = item.id,
                .name = item.name,
                .kind = "billable usage",
                .status = .active,
            };
            line_items[index] = .{
                .id = item.id,
                .description = item.name,
                .service = item.family,
                .amount_micros = item.amount_micros,
                .detail = item.detail,
            };
        }

        return .{
            .summary = .{
                .id = "cloudflare",
                .display_name = "Cloudflare",
                .kind = .cloud,
                .currency = try self.currency(),
                // Subscription prices and billable usage costs come from
                // disjoint Cloudflare feeds: the usage endpoint contains
                // overages only, not fixed recurring plan charges.
                .current_cost_micros = total_micros,
                // Cloudflare does not forecast future metered usage.
                .projected_cost_micros = if (usage_items.len == 0)
                    total_micros
                else
                    null,
                .updated_at_unix = self.updatedAtUnix(),
            },
            .resources = resources,
            .line_items = line_items,
        };
    }

    /// Both feeds, most expensive first, with zone plans already counted by an
    /// account subscription removed.
    fn mergedServices(
        self: *const Cloudflare,
        allocator: std.mem.Allocator,
    ) ![]Service {
        const subscriptions = if (self.subscriptions) |document|
            document.services
        else
            &.{};
        const zone_plans = if (self.zone_plans) |document|
            document.services
        else
            &.{};

        var merged = try allocator.alloc(Service, subscriptions.len + zone_plans.len);
        errdefer allocator.free(merged);

        var count: usize = 0;
        for (subscriptions) |service| {
            merged[count] = service;
            count += 1;
        }
        for (zone_plans) |plan| {
            if (isAlreadyBilled(plan, subscriptions)) continue;
            merged[count] = plan;
            count += 1;
        }

        std.mem.sort(Service, merged[0..count], {}, moreExpensiveFirst);
        if (count != merged.len) merged = try allocator.realloc(merged, count);
        return merged;
    }

    fn currency(self: *const Cloudflare) ![]const u8 {
        var found: ?[]const u8 = null;
        if (self.subscriptions) |document| {
            if (document.currency) |code| found = code;
        }
        if (self.zone_plans) |document| {
            if (document.currency) |code| {
                if (found) |existing| {
                    if (!std.mem.eql(u8, existing, code)) return error.MixedCurrencies;
                } else {
                    found = code;
                }
            }
        }
        if (self.billable_usage) |document| {
            if (document.currency) |code| {
                if (found) |existing| {
                    if (!std.mem.eql(u8, existing, code)) return error.MixedCurrencies;
                } else {
                    found = code;
                }
            }
        }
        return found orelse "USD";
    }

    fn updatedAtUnix(self: *const Cloudflare) i64 {
        var newest: i64 = std.math.minInt(i64);
        if (self.subscriptions) |document| newest = @max(newest, document.updated_at_unix);
        if (self.zone_plans) |document| newest = @max(newest, document.updated_at_unix);
        if (self.billable_usage) |document| newest = @max(newest, document.updated_at_unix);
        return newest;
    }
};

fn fetchAllZones(
    allocator: std.mem.Allocator,
    client: anytype,
    credentials: Credentials,
    received_at_unix: i64,
) !Document {
    const ResultInfo = struct {
        page: usize = 1,
        total_pages: usize = 1,
    };
    const PageMeta = struct { result_info: ?ResultInfo = null };
    var result = Document{
        .arena = .init(allocator),
        .services = &.{},
        .currency = null,
        .updated_at_unix = received_at_unix,
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var services: std.ArrayList(Service) = .empty;
    var page_number: usize = 1;
    while (page_number <= 20) : (page_number += 1) {
        const zones_url = try std.fmt.allocPrint(
            allocator,
            api_prefix ++ "zones?account.id={s}&per_page=50&page={d}",
            .{ credentials.account_id, page_number },
        );
        defer allocator.free(zones_url);
        const response = try client.get(allocator, .{
            .url = zones_url,
            .bearer_token = credentials.token,
        });
        defer response.deinit(allocator);
        try response.requireSuccess();

        var document = try parseZones(allocator, response.body, received_at_unix);
        defer document.deinit();
        if (result.currency == null and document.currency != null) {
            result.currency = try arena.dupe(u8, document.currency.?);
        }
        for (document.services) |service| {
            try services.append(arena, .{
                .id = try arena.dupe(u8, service.id),
                .name = try arena.dupe(u8, service.name),
                .usage_label = try arena.dupe(u8, service.usage_label),
                .amount_micros = service.amount_micros,
                .enabled = service.enabled,
                .scope = service.scope,
                .zone_id = if (service.zone_id) |id| try arena.dupe(u8, id) else null,
            });
        }

        var metadata = try std.json.parseFromSlice(PageMeta, allocator, response.body, .{
            .ignore_unknown_fields = true,
        });
        defer metadata.deinit();
        const total_pages = if (metadata.value.result_info) |info| info.total_pages else 1;
        if (page_number >= total_pages) break;
    }
    result.services = try services.toOwnedSlice(arena);
    return result;
}

fn isAlreadyBilled(plan: Service, subscriptions: []const Service) bool {
    const zone_id = plan.zone_id orelse return false;
    for (subscriptions) |service| {
        const billed_zone = service.zone_id orelse continue;
        if (std.mem.eql(u8, billed_zone, zone_id)) return true;
    }
    return false;
}

fn moreExpensiveFirst(_: void, left: Service, right: Service) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

/// `GET /accounts/{id}/subscriptions`
fn parseSubscriptions(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !Document {
    var document = Document{
        .arena = .init(allocator),
        .services = &.{},
        .currency = null,
        .updated_at_unix = received_at_unix,
    };
    errdefer document.deinit();
    const arena = document.arena.allocator();

    const results = try parseResultArray(arena, payload);
    const services = try arena.alloc(Service, results.len);
    var count: usize = 0;

    for (results, 0..) |subscription_value, index| {
        const subscription = try requireObject(subscription_value);
        const state = optionalString(subscription, "state") orelse "Provisioned";
        if (!isLiveState(state)) continue;

        const rate_plan = if (subscription.get("rate_plan")) |value|
            try requireObject(value)
        else
            null;
        const plan_id = if (rate_plan) |plan| optionalString(plan, "id") else null;
        const id = optionalString(subscription, "id") orelse plan_id orelse
            try std.fmt.allocPrint(arena, "subscription-{d}", .{index});
        const plan_name = if (rate_plan) |plan|
            optionalString(plan, "public_name") orelse plan_id
        else
            null;

        const zone = if (subscription.get("zone")) |value| switch (value) {
            .object => |object| object,
            else => null,
        } else null;
        const zone_id = if (zone) |object| optionalString(object, "id") else null;
        const zone_name = if (zone) |object| optionalString(object, "name") else null;

        const price = if (subscription.get("price")) |value|
            try parseMoneyValue(value)
        else
            0;
        const frequency = optionalString(subscription, "frequency") orelse "monthly";
        const monthly = try monthlyEquivalent(price, frequency);

        if (price != 0) {
            const item_currency = optionalString(subscription, "currency") orelse
                (if (rate_plan) |plan| optionalString(plan, "currency") else null) orelse
                "USD";
            if (document.currency) |existing| {
                if (!std.mem.eql(u8, existing, item_currency)) return error.MixedCurrencies;
            } else {
                document.currency = item_currency;
            }
        }

        services[count] = .{
            .id = id,
            // A zone-scoped subscription is far easier to recognise by the
            // domain it pays for than by the plan name alone.
            .name = if (zone_name) |name|
                if (plan_name) |plan|
                    try std.fmt.allocPrint(arena, "{s} · {s}", .{ name, plan })
                else
                    name
            else
                plan_name orelse id,
            .usage_label = try cadenceLabel(arena, price, frequency, state),
            .amount_micros = monthly,
            .enabled = true,
            .scope = if (zone_id != null) .zone else .account,
            .zone_id = zone_id,
        };
        count += 1;
    }

    document.services = services[0..count];
    return document;
}

/// `GET /zones?account.id={id}`
fn parseZones(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !Document {
    var document = Document{
        .arena = .init(allocator),
        .services = &.{},
        .currency = null,
        .updated_at_unix = received_at_unix,
    };
    errdefer document.deinit();
    const arena = document.arena.allocator();

    const results = try parseResultArray(arena, payload);
    const services = try arena.alloc(Service, results.len);
    var count: usize = 0;

    for (results, 0..) |zone_value, index| {
        const zone = try requireObject(zone_value);
        const id = optionalString(zone, "id") orelse
            try std.fmt.allocPrint(arena, "zone-{d}", .{index});
        const name = optionalString(zone, "name") orelse id;
        const plan = if (zone.get("plan")) |value|
            try requireObject(value)
        else
            continue;
        const plan_name = optionalString(plan, "name") orelse
            optionalString(plan, "legacy_id") orelse "Plan";

        const subscribed = switch (plan.get("is_subscribed") orelse std.json.Value{ .bool = false }) {
            .bool => |value| value,
            else => false,
        };
        const price = if (subscribed)
            if (plan.get("price")) |value| try parseMoneyValue(value) else 0
        else
            0;
        const frequency = optionalString(plan, "frequency") orelse "monthly";
        const monthly = try monthlyEquivalent(price, frequency);

        if (price != 0) {
            const item_currency = optionalString(plan, "currency") orelse "USD";
            if (document.currency) |existing| {
                if (!std.mem.eql(u8, existing, item_currency)) return error.MixedCurrencies;
            } else {
                document.currency = item_currency;
            }
        }

        const status = optionalString(zone, "status") orelse "active";
        services[count] = .{
            .id = id,
            .name = try std.fmt.allocPrint(arena, "{s} · {s}", .{ name, plan_name }),
            .usage_label = if (price == 0)
                try std.fmt.allocPrint(arena, "{s} · {s}", .{ plan_name, status })
            else
                try cadenceLabel(arena, price, frequency, status),
            .amount_micros = monthly,
            .enabled = std.mem.eql(u8, status, "active"),
            .scope = .zone,
            .zone_id = id,
        };
        count += 1;
    }

    document.services = services[0..count];
    return document;
}

/// `GET /accounts/{id}/billable-usage`
fn parseBillableUsage(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !BillableUsageDocument {
    var document = BillableUsageDocument{
        .arena = .init(allocator),
        .items = &.{},
        .currency = null,
        .updated_at_unix = received_at_unix,
    };
    errdefer document.deinit();
    const arena = document.arena.allocator();

    const results = try parseResultArray(arena, payload);
    var items: std.ArrayList(BillableUsageItem) = .empty;
    for (results) |usage_value| {
        const usage = try requireObject(usage_value);
        const service_name = optionalString(usage, "ServiceName") orelse
            return error.InvalidResponse;
        const family = optionalString(usage, "ServiceFamilyName") orelse
            "Billable usage";
        const subscription_id = optionalString(usage, "SubscriptionId");
        const zone_id = optionalString(usage, "ZoneId");
        const zone_name = optionalString(usage, "ZoneName");
        const charge_period_end = optionalString(usage, "ChargePeriodEnd") orelse
            return error.InvalidResponse;
        const pricing_unit = optionalString(usage, "PricingUnit") orelse
            optionalString(usage, "ConsumedUnit") orelse "units";
        const cumulative_quantity = try numberText(
            arena,
            usage.get("CumulatedPricingQuantity") orelse return error.InvalidResponse,
        );
        const amount_micros = try parseRoundedMoneyValue(
            usage.get("CumulatedContractedCost") orelse return error.InvalidResponse,
        );
        const billing_currency = optionalString(usage, "BillingCurrency") orelse
            return error.InvalidResponse;
        if (billing_currency.len != 3) return error.InvalidCurrency;
        if (document.currency) |existing| {
            if (!std.mem.eql(u8, existing, billing_currency)) {
                return error.MixedCurrencies;
            }
        } else {
            document.currency = billing_currency;
        }

        if (findUsageItem(
            items.items,
            service_name,
            family,
            subscription_id,
            zone_id,
            zone_name,
            pricing_unit,
        )) |index| {
            // ISO 8601 timestamps sort chronologically because Cloudflare emits
            // the canonical UTC representation documented by this endpoint.
            if (std.mem.order(u8, items.items[index].charge_period_end, charge_period_end) == .gt) {
                continue;
            }
            items.items[index].amount_micros = amount_micros;
            items.items[index].charge_period_end = charge_period_end;
            items.items[index].cumulative_quantity = cumulative_quantity;
            items.items[index].pricing_unit = pricing_unit;
            items.items[index].zone_name = zone_name;
            items.items[index].name = if (zone_name) |name|
                try std.fmt.allocPrint(arena, "{s} · {s}", .{ name, service_name })
            else
                service_name;
            continue;
        }

        const name = if (zone_name) |name|
            try std.fmt.allocPrint(arena, "{s} · {s}", .{ name, service_name })
        else
            service_name;
        try items.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "usage:{s}:{s}:{s}:{s}:{s}", .{
                family,
                service_name,
                subscription_id orelse "",
                zone_id orelse zone_name orelse "",
                pricing_unit,
            }),
            .name = name,
            .service_name = service_name,
            .family = family,
            .detail = "",
            .amount_micros = amount_micros,
            .subscription_id = subscription_id,
            .zone_id = zone_id,
            .zone_name = zone_name,
            .charge_period_end = charge_period_end,
            .cumulative_quantity = cumulative_quantity,
            .pricing_unit = pricing_unit,
        });
    }

    for (items.items) |*item| {
        item.detail = try std.fmt.allocPrint(arena, "{s} {s} · billable usage", .{
            item.cumulative_quantity,
            item.pricing_unit,
        });
    }
    std.mem.sort(BillableUsageItem, items.items, {}, moreExpensiveUsageFirst);
    document.items = try items.toOwnedSlice(arena);
    return document;
}

fn findUsageItem(
    items: []const BillableUsageItem,
    service_name: []const u8,
    family: []const u8,
    subscription_id: ?[]const u8,
    zone_id: ?[]const u8,
    zone_name: ?[]const u8,
    pricing_unit: []const u8,
) ?usize {
    for (items, 0..) |item, index| {
        if (!std.mem.eql(u8, item.service_name, service_name)) continue;
        if (!std.mem.eql(u8, item.family, family)) continue;
        if (!optionalStringsEqual(item.subscription_id, subscription_id)) continue;
        if (!sameUsageLocation(item.zone_id, item.zone_name, zone_id, zone_name)) continue;
        if (!std.mem.eql(u8, item.pricing_unit, pricing_unit)) continue;
        return index;
    }
    return null;
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn sameUsageLocation(
    left_id: ?[]const u8,
    left_name: ?[]const u8,
    right_id: ?[]const u8,
    right_name: ?[]const u8,
) bool {
    if (left_id != null or right_id != null) {
        return optionalStringsEqual(left_id, right_id);
    }
    return optionalStringsEqual(left_name, right_name);
}

fn moreExpensiveUsageFirst(
    _: void,
    left: BillableUsageItem,
    right: BillableUsageItem,
) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

fn parseResultArray(
    arena: std.mem.Allocator,
    payload: []const u8,
) ![]const std.json.Value {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    const root_object = try requireObject(root);
    const success = root_object.get("success") orelse return error.InvalidResponse;
    if (success != .bool or !success.bool) return error.ApiFailure;
    const result_value = root_object.get("result") orelse return error.InvalidResponse;
    if (result_value != .array) return error.InvalidResponse;
    return result_value.array.items;
}

fn isLiveState(state: []const u8) bool {
    return !std.mem.eql(u8, state, "Cancelled") and
        !std.mem.eql(u8, state, "Failed") and
        !std.mem.eql(u8, state, "Expired");
}

/// Cloudflare quotes each subscription at its billing cadence. Everything is
/// normalised to a month so the dashboard total is comparable across providers.
fn monthlyEquivalent(price_micros: i64, frequency: []const u8) !i64 {
    if (price_micros == 0) return 0;
    const scaled: i128 = price_micros;
    const monthly: i128 = if (matchesAny(frequency, &.{ "yearly", "annual", "annually" }))
        @divTrunc(scaled, 12)
    else if (matchesAny(frequency, &.{"quarterly"}))
        @divTrunc(scaled, 3)
    else if (matchesAny(frequency, &.{"weekly"}))
        @divTrunc(scaled * 52, 12)
    else if (matchesAny(frequency, &.{"daily"}))
        @divTrunc(scaled * 365, 12)
    else
        scaled;
    if (monthly > std.math.maxInt(i64) or monthly < std.math.minInt(i64)) {
        return error.AmountOverflow;
    }
    return @intCast(monthly);
}

fn matchesAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}

/// "monthly · Paid" for the common case, "60.00 yearly · Paid" when the quoted
/// price covers more than the month it is being spread across.
fn cadenceLabel(
    arena: std.mem.Allocator,
    price_micros: i64,
    frequency: []const u8,
    state: []const u8,
) ![]const u8 {
    // Cloudflare also answers "not-applicable" for plans it does not bill on a
    // cycle, which says nothing worth putting in front of the reader.
    const cadence = if (frequency.len == 0 or
        std.ascii.eqlIgnoreCase(frequency, "not-applicable"))
        "recurring"
    else
        frequency;

    const monthly = try monthlyEquivalent(price_micros, frequency);
    if (monthly == price_micros) {
        return std.fmt.allocPrint(arena, "{s} · {s}", .{ cadence, state });
    }
    return std.fmt.allocPrint(arena, "{f} {s} · {s}", .{
        money.Decimal{ .micros = price_micros },
        cadence,
        state,
    });
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    if (value.string.len == 0) return null;
    return value.string;
}

fn parseMoneyValue(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string => |number| money.parseMicros(number),
        .string => |number| money.parseMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

fn parseRoundedMoneyValue(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string => |number| money.parseRoundedMicros(number),
        .string => |number| money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

fn numberText(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const result = switch (value) {
        .number_string => |number| number,
        .string => |number| number,
        .integer => |integer| return std.fmt.allocPrint(arena, "{d}", .{integer}),
        .float => |number| return std.fmt.allocPrint(arena, "{d}", .{number}),
        else => return error.InvalidQuantity,
    };
    const parsed = std.fmt.parseFloat(f128, result) catch return error.InvalidQuantity;
    if (!std.math.isFinite(parsed)) return error.InvalidQuantity;
    return result;
}

test "Cloudflare reports account subscriptions with their plan names" {
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"success":true,"errors":[],"result":[{"id":"sub-workers","currency":"USD","frequency":"monthly","price":5.25,"rate_plan":{"id":"workers","currency":"USD","public_name":"Workers Paid"},"state":"Paid"},{"id":"free","currency":"USD","price":0,"rate_plan":{"public_name":"Cloudflare Free Plan"},"state":"Paid"},{"id":"old","currency":"USD","price":20,"rate_plan":{"public_name":"Cancelled Plan"},"state":"Cancelled"}]}
    , 1_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 5_250_000), report.summary.current_cost_micros);
    // Paid plans sort ahead of the free plan the account is also enrolled in.
    try std.testing.expectEqualStrings("Workers Paid", report.resources[0].name);
    try std.testing.expectEqualStrings("Cloudflare Free Plan", report.resources[1].name);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
    try std.testing.expectEqualStrings("monthly · Paid", report.line_items[0].detail.?);
    try std.testing.expectEqualStrings("Subscriptions", report.line_items[0].service);
}

test "Cloudflare spreads a yearly subscription across the year" {
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"success":true,"result":[{"id":"sub","currency":"USD","frequency":"yearly","price":60,"rate_plan":{"public_name":"Yearly Plan"},"state":"Paid"}]}
    , 1_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 5_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqualStrings("60.00 yearly · Paid", report.line_items[0].detail.?);
}

test "Cloudflare adds zone plan tiers the account feed leaves out" {
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"success":true,"result":[{"id":"sub-workers","currency":"USD","frequency":"monthly","price":5,"rate_plan":{"public_name":"Workers Paid"},"state":"Paid"}]}
    , 1_000);
    try provider.ingest(std.testing.allocator, "zones",
        \\{"success":true,"result":[{"id":"zone-a","name":"example.com","status":"active","plan":{"legacy_id":"pro","name":"Pro Website","price":20,"currency":"USD","frequency":"monthly","is_subscribed":true}},{"id":"zone-b","name":"free.test","status":"active","plan":{"legacy_id":"free","name":"Free Website","price":0,"currency":"USD","frequency":"","is_subscribed":false}}]}
    , 2_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 25_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqualStrings("example.com · Pro Website", report.resources[0].name);
    try std.testing.expectEqualStrings("Zone plans", report.line_items[0].service);
    try std.testing.expectEqualStrings("Workers Paid", report.resources[1].name);
    try std.testing.expectEqual(@as(i64, 0), report.line_items[2].amount_micros);
    try std.testing.expectEqual(@as(i64, 2_000), report.summary.updated_at_unix);
}

test "Cloudflare counts a zone plan once when both feeds report it" {
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"success":true,"result":[{"id":"sub-zone","currency":"USD","frequency":"monthly","price":20,"zone":{"id":"zone-a","name":"example.com"},"rate_plan":{"public_name":"Pro Website"},"state":"Paid"}]}
    , 1_000);
    try provider.ingest(std.testing.allocator, "zones",
        \\{"success":true,"result":[{"id":"zone-a","name":"example.com","status":"active","plan":{"legacy_id":"pro","name":"Pro Website","price":20,"currency":"USD","frequency":"monthly","is_subscribed":true}}]}
    , 1_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.resources.len);
    try std.testing.expectEqual(@as(i64, 20_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqualStrings("example.com · Pro Website", report.resources[0].name);
}

test "Cloudflare ignores a currency mismatch on unpriced plans" {
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"success":true,"result":[{"id":"free","currency":"EUR","price":0,"rate_plan":{"public_name":"Free"},"state":"Paid"},{"id":"paid","currency":"USD","frequency":"monthly","price":5,"rate_plan":{"public_name":"Workers Paid"},"state":"Paid"}]}
    , 1_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("USD", report.summary.currency);
}

test "Cloudflare includes every metered SKU at its billing-period cumulative cost" {
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"success":true,"result":[{"id":"workers","currency":"USD","frequency":"monthly","price":5,"rate_plan":{"public_name":"Workers Paid"},"state":"Paid"}]}
    , 1_000);
    try provider.ingest(std.testing.allocator, "billable-usage",
        \\{"success":true,"result":[
        \\  {"BillingCurrency":"USD","ChargePeriodEnd":"2026-08-02T00:00:00Z","ServiceName":"Container Memory","ServiceFamilyName":"Containers","ContractedCost":0.04,"CumulatedContractedCost":0.04,"PricingQuantity":16000,"CumulatedPricingQuantity":16000,"PricingUnit":"GiB-seconds"},
        \\  {"BillingCurrency":"USD","ChargePeriodEnd":"2026-08-03T00:00:00Z","ServiceName":"Container Memory","ServiceFamilyName":"Containers","ContractedCost":0.06,"CumulatedContractedCost":0.10,"PricingQuantity":24000,"CumulatedPricingQuantity":40000,"PricingUnit":"GiB-seconds"},
        \\  {"BillingCurrency":"USD","ChargePeriodEnd":"2026-08-03T00:00:00Z","ServiceName":"PlanetScale Storage","ServiceFamilyName":"PlanetScale","ContractedCost":0.03,"CumulatedContractedCost":0.03,"PricingQuantity":2,"CumulatedPricingQuantity":2,"PricingUnit":"GiB-months"},
        \\  {"BillingCurrency":"USD","ChargePeriodEnd":"2026-08-03T00:00:00Z","ServiceName":"Workers Requests","ServiceFamilyName":"Workers","ContractedCost":0,"CumulatedContractedCost":0,"PricingQuantity":900000,"CumulatedPricingQuantity":900000,"PricingUnit":"Requests"}
        \\]}
    , 2_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 5_130_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, null), report.summary.projected_cost_micros);
    try std.testing.expectEqual(@as(usize, 4), report.line_items.len);
    try std.testing.expectEqualStrings("Container Memory", report.line_items[1].description);
    try std.testing.expectEqualStrings("Containers", report.line_items[1].service);
    try std.testing.expectEqual(@as(i64, 100_000), report.line_items[1].amount_micros);
    try std.testing.expectEqualStrings(
        "40000 GiB-seconds · billable usage",
        report.line_items[1].detail.?,
    );
    try std.testing.expectEqualStrings("PlanetScale Storage", report.line_items[2].description);
    try std.testing.expectEqualStrings("Workers Requests", report.line_items[3].description);
    try std.testing.expectEqual(@as(i64, 0), report.line_items[3].amount_micros);
}

test "Cloudflare fetches subscriptions billable usage and zone plans through comptime client" {
    const Backend = struct {
        const Step = struct {
            url: []const u8,
            body: []const u8,
        };

        steps: []const Step,
        next: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            if (self.next >= self.steps.len) return error.UnexpectedRequest;
            const step = self.steps[self.next];
            self.next += 1;
            try std.testing.expectEqualStrings(step.url, request.url);
            try std.testing.expectEqualStrings("cloudflare-token", request.bearer_token.?);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, step.body),
            };
        }
    };

    const account_id = "0123456789abcdef0123456789abcdef";
    const steps = [_]Backend.Step{
        .{
            .url = api_prefix ++ "accounts/" ++ account_id ++ "/subscriptions",
            .body =
            \\{"success":true,"result":[{"id":"workers-subscription","currency":"USD","frequency":"monthly","price":5,"rate_plan":{"id":"workers","public_name":"Workers Paid"},"state":"Paid"}]}
            ,
        },
        .{
            .url = api_prefix ++ "accounts/" ++ account_id ++ "/billable-usage",
            .body =
            \\{"success":true,"result":[]}
            ,
        },
        .{
            .url = api_prefix ++ "zones?account.id=" ++ account_id ++ "&per_page=50&page=1",
            .body =
            \\{"success":true,"result":[{"id":"zone-a","name":"example.com","status":"active","plan":{"name":"Pro Website","price":20,"currency":"USD","frequency":"monthly","is_subscribed":true}}]}
            ,
        },
    };

    var backend = Backend{ .steps = &steps };
    var client = http.Client(Backend).init(&backend);
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.fetch(
        std.testing.allocator,
        &client,
        .{ .token = "cloudflare-token", .account_id = account_id },
        1_000,
    );
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(steps.len, backend.next);
    try std.testing.expectEqual(@as(i64, 25_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqualStrings("example.com · Pro Website", report.resources[0].name);
}

test "Cloudflare still reports subscriptions when optional feeds are forbidden" {
    const Backend = struct {
        calls: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            self.calls += 1;
            if (std.mem.indexOf(u8, request.url, "/zones") != null or
                std.mem.indexOf(u8, request.url, "/billable-usage") != null)
            {
                return .{ .status = 403, .body = try allocator.dupe(u8, "{}") };
            }
            return .{
                .status = 200,
                .body = try allocator.dupe(u8,
                    \\{"success":true,"result":[{"id":"sub","currency":"USD","frequency":"monthly","price":5,"rate_plan":{"public_name":"Workers Paid"},"state":"Paid"}]}
                ),
            };
        }
    };

    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    var provider = Cloudflare.init();
    defer provider.deinit();

    try provider.fetch(
        std.testing.allocator,
        &client,
        .{
            .token = "cloudflare-token",
            .account_id = "0123456789abcdef0123456789abcdef",
        },
        1_000,
    );
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), backend.calls);
    try std.testing.expectEqual(@as(i64, 5_000_000), report.summary.current_cost_micros);
}

test "Cloudflare follows every zone result page" {
    const Backend = struct {
        calls: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            const body = switch (self.calls) {
                0 => "{\"success\":true,\"result\":[]}",
                1 => "{\"success\":true,\"result\":[]}",
                2 => "{\"success\":true,\"result\":[{\"id\":\"zone-a\",\"name\":\"a.test\",\"status\":\"active\",\"plan\":{\"name\":\"Pro\",\"price\":20,\"currency\":\"USD\",\"frequency\":\"monthly\",\"is_subscribed\":true}}],\"result_info\":{\"page\":1,\"total_pages\":2}}",
                3 => "{\"success\":true,\"result\":[{\"id\":\"zone-b\",\"name\":\"b.test\",\"status\":\"active\",\"plan\":{\"name\":\"Business\",\"price\":25,\"currency\":\"USD\",\"frequency\":\"monthly\",\"is_subscribed\":true}}],\"result_info\":{\"page\":2,\"total_pages\":2}}",
                else => return error.UnexpectedRequest,
            };
            if (self.calls > 1) {
                const suffix = if (self.calls == 2) "&page=1" else "&page=2";
                try std.testing.expect(std.mem.endsWith(u8, request.url, suffix));
            }
            self.calls += 1;
            return .{ .status = 200, .body = try allocator.dupe(u8, body) };
        }
    };
    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    var provider = Cloudflare.init();
    defer provider.deinit();
    try provider.fetch(
        std.testing.allocator,
        &client,
        .{
            .token = "token",
            .account_id = "0123456789abcdef0123456789abcdef",
        },
        100,
    );
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), backend.calls);
    try std.testing.expectEqual(@as(usize, 2), report.resources.len);
    try std.testing.expectEqual(@as(i64, 45_000_000), report.summary.current_cost_micros);
}

test "Cloudflare validates account IDs before making a request" {
    try std.testing.expectError(
        error.InvalidAccountId,
        (Credentials{
            .token = "token",
            .account_id = "not-an-account-id",
        }).validate(),
    );
}
