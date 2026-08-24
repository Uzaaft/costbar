const std = @import("std");
const http = @import("../http.zig");
const model = @import("../model.zig");
const money = @import("../money.zig");

pub const balance_url = "https://api.digitalocean.com/v2/customers/my/balance";
pub const droplets_url = "https://api.digitalocean.com/v2/droplets?page=1&per_page=200";
pub const invoices_url = "https://api.digitalocean.com/v2/customers/my/invoices";

pub const Credentials = struct {
    token: []const u8,

    fn validate(self: Credentials) !void {
        if (self.token.len == 0) return error.InvalidCredentials;
    }
};

pub const Droplet = struct {
    id: []const u8,
    name: []const u8,
    active: bool,
    /// DigitalOcean's balance API does not attribute spend to individual
    /// Droplets. This is populated only when a richer source provides it.
    month_to_date_micros: ?i64 = null,
};

/// A single charge on the running invoice, e.g. one Droplet or one App.
pub const InvoiceItem = struct {
    id: []const u8,
    /// Billed product, used as the breakdown group ("Droplets").
    product: []const u8,
    label: []const u8,
    detail: ?[]const u8 = null,
    amount_micros: i64,
};

/// Per-product rollup of the running invoice: "2 Droplets", "1 App Platform".
pub const Product = struct {
    name: []const u8,
    count: u64,
    amount_micros: i64,
};

pub const Account = struct {
    currency: []const u8 = "USD",
    balance_micros: i64,
    month_to_date_micros: i64,
    projected_month_micros: ?i64,
    updated_at_unix: i64,
    droplets: []const Droplet,
};

const OwnedDroplets = struct {
    arena: std.heap.ArenaAllocator,
    items: []Droplet,

    fn deinit(self: *OwnedDroplets) void {
        self.arena.deinit();
    }
};

const OwnedInvoice = struct {
    arena: std.heap.ArenaAllocator,
    items: []InvoiceItem,
    products: []Product,
    total_micros: i64,

    fn deinit(self: *OwnedInvoice) void {
        self.arena.deinit();
    }
};

pub const DigitalOcean = struct {
    account: ?Account = null,
    owned_droplets: ?OwnedDroplets = null,
    /// Current month's unbilled invoice, when the token can read billing.
    owned_invoice: ?OwnedInvoice = null,

    pub fn init() DigitalOcean {
        return .{};
    }

    pub fn deinit(self: *DigitalOcean) void {
        if (self.owned_droplets) |*owned| owned.deinit();
        self.owned_droplets = null;
        if (self.owned_invoice) |*owned| owned.deinit();
        self.owned_invoice = null;
    }

    pub fn metadata(_: *const DigitalOcean) model.ProviderMetadata {
        return .{
            .id = "digitalocean",
            .display_name = "DigitalOcean",
            .kind = .cloud,
        };
    }

    /// Fetches all documents needed for a DigitalOcean report through the
    /// compile-time HTTP interface. State is replaced only after the balance
    /// and every Droplet page have been fetched and parsed successfully.
    pub fn fetch(
        self: *DigitalOcean,
        allocator: std.mem.Allocator,
        client: anytype,
        credentials: Credentials,
        received_at_unix: i64,
    ) !void {
        try credentials.validate();

        const balance_response = try client.get(allocator, .{
            .url = balance_url,
            .bearer_token = credentials.token,
        });
        defer balance_response.deinit(allocator);
        try balance_response.requireSuccess();

        var replacement_droplets = try fetchAllDroplets(
            allocator,
            client,
            credentials.token,
        );
        errdefer replacement_droplets.deinit();
        const replacement_account = try parseBalance(
            allocator,
            balance_response.body,
            received_at_unix,
            replacement_droplets.items,
        );

        // The running invoice is what attributes spend to products, but it
        // needs the billing scope: a token without it still reports a total.
        var replacement_invoice: ?OwnedInvoice = invoice: {
            const found = fetchInvoicePreviewUuid(
                allocator,
                client,
                credentials.token,
            ) catch break :invoice null;
            const uuid = found orelse break :invoice null;
            defer allocator.free(uuid);
            break :invoice fetchInvoiceItems(
                allocator,
                client,
                credentials.token,
                uuid,
            ) catch null;
        };
        errdefer if (replacement_invoice) |*owned| owned.deinit();

        if (self.owned_droplets) |*owned| owned.deinit();
        self.owned_droplets = replacement_droplets;
        self.account = replacement_account;
        if (replacement_invoice) |owned| {
            if (self.owned_invoice) |*existing| existing.deinit();
            self.owned_invoice = owned;
        }
    }

    pub fn ingest(
        self: *DigitalOcean,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (std.mem.eql(u8, document_id, "balance")) {
            return self.ingestBalance(allocator, payload, received_at_unix);
        }
        if (std.mem.eql(u8, document_id, "droplets")) {
            return self.ingestDroplets(allocator, payload);
        }
        if (std.mem.eql(u8, document_id, "invoice")) {
            return self.ingestInvoice(allocator, payload);
        }
        return error.UnsupportedDocument;
    }

    fn ingestBalance(
        self: *DigitalOcean,
        allocator: std.mem.Allocator,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        const droplets = if (self.owned_droplets) |owned| owned.items else &.{};
        self.account = try parseBalance(
            allocator,
            payload,
            received_at_unix,
            droplets,
        );
    }

    fn ingestDroplets(
        self: *DigitalOcean,
        allocator: std.mem.Allocator,
        payload: []const u8,
    ) !void {
        const RawDroplet = struct {
            id: u64,
            name: []const u8,
            status: []const u8,
        };
        const Response = struct { droplets: []const RawDroplet };

        var replacement = OwnedDroplets{
            .arena = .init(allocator),
            .items = undefined,
        };
        errdefer replacement.deinit();
        const arena = replacement.arena.allocator();
        const response = try std.json.parseFromSliceLeaky(Response, arena, payload, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        replacement.items = try arena.alloc(Droplet, response.droplets.len);
        for (response.droplets, 0..) |raw, index| {
            replacement.items[index] = .{
                .id = try std.fmt.allocPrint(arena, "{d}", .{raw.id}),
                .name = raw.name,
                .active = std.mem.eql(u8, raw.status, "active"),
            };
        }

        if (self.owned_droplets) |*owned| owned.deinit();
        self.owned_droplets = replacement;
        if (self.account) |*account| account.droplets = replacement.items;
    }

    fn ingestInvoice(
        self: *DigitalOcean,
        allocator: std.mem.Allocator,
        payload: []const u8,
    ) !void {
        var replacement = try parseInvoice(allocator, payload);
        errdefer replacement.deinit();
        if (self.owned_invoice) |*owned| owned.deinit();
        self.owned_invoice = replacement;
    }

    pub fn collect(
        self: *DigitalOcean,
        allocator: std.mem.Allocator,
        period: model.Period,
    ) !model.ProviderReport {
        const account = self.account orelse return error.NotFetched;
        const products: []const Product = if (self.owned_invoice) |invoice|
            invoice.products
        else
            &.{};

        const resources = try allocator.alloc(
            model.Resource,
            products.len + account.droplets.len,
        );
        errdefer allocator.free(resources);

        for (products, 0..) |product, index| {
            resources[index] = .{
                .id = product.name,
                .name = product.name,
                .kind = "product",
                .status = .active,
                .quantity = product.count,
            };
        }
        for (account.droplets, 0..) |droplet, index| {
            resources[products.len + index] = .{
                .id = droplet.id,
                .name = droplet.name,
                .kind = "droplet",
                .status = if (droplet.active) .active else .inactive,
            };
        }

        const line_items = if (self.owned_invoice) |invoice|
            try invoiceLineItems(allocator, invoice.items, invoice.total_micros, account)
        else
            try balanceLineItems(allocator, account);
        errdefer allocator.free(line_items);

        return .{
            .summary = .{
                .id = "digitalocean",
                .display_name = "DigitalOcean",
                .kind = .cloud,
                .currency = account.currency,
                .current_cost_micros = account.month_to_date_micros,
                .projected_cost_micros = self.projectedCost(period),
                .credit_remaining_micros = @max(-account.balance_micros, 0),
                .updated_at_unix = account.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
        };
    }

    fn projectedCost(self: *const DigitalOcean, period: model.Period) ?i64 {
        const account = self.account orelse return null;
        if (account.projected_month_micros) |value| return value;
        const elapsed = account.updated_at_unix - period.start_unix;
        const duration = period.end_exclusive_unix - period.start_unix;
        if (elapsed <= 0 or duration <= 0) return null;

        const projected = @divTrunc(
            @as(i128, account.month_to_date_micros) * duration,
            elapsed,
        );
        const at_least_current = @max(projected, account.month_to_date_micros);
        if (at_least_current > std.math.maxInt(i64)) return std.math.maxInt(i64);
        if (at_least_current < std.math.minInt(i64)) return std.math.minInt(i64);
        return @intCast(at_least_current);
    }
};

fn parseBalance(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
    droplets: []const Droplet,
) !Account {
    const Response = struct {
        account_balance: []const u8,
        month_to_date_usage: []const u8,
    };
    var parsed = try std.json.parseFromSlice(Response, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .balance_micros = try money.parseMicros(parsed.value.account_balance),
        .month_to_date_micros = try money.parseMicros(parsed.value.month_to_date_usage),
        .projected_month_micros = null,
        .updated_at_unix = received_at_unix,
        .droplets = droplets,
    };
}

/// Breakdown built from the running invoice: one row per billed resource,
/// plus whatever the balance API counts that the invoice has not picked up yet.
fn invoiceLineItems(
    allocator: std.mem.Allocator,
    items: []const InvoiceItem,
    invoiced_micros: i64,
    account: Account,
) ![]model.CostLineItem {
    const residual = std.math.sub(i64, account.month_to_date_micros, invoiced_micros) catch
        return error.AmountOverflow;
    const needs_residual = residual != 0;
    const line_items = try allocator.alloc(
        model.CostLineItem,
        items.len + @intFromBool(needs_residual),
    );
    errdefer allocator.free(line_items);

    for (items, 0..) |item, index| {
        line_items[index] = .{
            .id = item.id,
            .description = item.label,
            .service = item.product,
            .amount_micros = item.amount_micros,
            .detail = item.detail,
        };
    }
    if (needs_residual) {
        line_items[items.len] = .{
            .id = "digitalocean-invoice-residual",
            .description = if (residual > 0)
                "Usage not yet on the invoice"
            else
                "Invoice adjustments",
            .service = "Account usage",
            .amount_micros = residual,
        };
    }
    return line_items;
}

/// Fallback breakdown when the invoice is unavailable: the balance API only
/// reports one month-to-date figure, with no attribution to resources.
fn balanceLineItems(
    allocator: std.mem.Allocator,
    account: Account,
) ![]model.CostLineItem {
    var attributed_total: i64 = 0;
    var attributed_count: usize = 0;
    for (account.droplets) |droplet| {
        if (droplet.month_to_date_micros) |amount| {
            attributed_total += amount;
            attributed_count += 1;
        }
    }

    const needs_unattributed = attributed_total != account.month_to_date_micros;
    const line_items = try allocator.alloc(
        model.CostLineItem,
        attributed_count + @intFromBool(needs_unattributed),
    );
    errdefer allocator.free(line_items);

    var line_index: usize = 0;
    for (account.droplets) |droplet| {
        const amount = droplet.month_to_date_micros orelse continue;
        line_items[line_index] = .{
            .id = droplet.id,
            .description = droplet.name,
            .service = "Droplets",
            .amount_micros = amount,
        };
        line_index += 1;
    }
    if (needs_unattributed) {
        line_items[line_index] = .{
            .id = "digitalocean-account-usage",
            .description = "Usage not attributed by the balance API",
            .service = "Account usage",
            .amount_micros = account.month_to_date_micros - attributed_total,
        };
    }
    return line_items;
}

/// `GET /customers/my/invoices/{uuid}` — every charge on one invoice, which for
/// the preview invoice is the current month's running spend.
fn parseInvoice(allocator: std.mem.Allocator, payload: []const u8) !OwnedInvoice {
    var owned = OwnedInvoice{
        .arena = .init(allocator),
        .items = &.{},
        .products = &.{},
        .total_micros = 0,
    };
    errdefer owned.deinit();
    const arena = owned.arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    if (root != .object) return error.InvalidResponse;
    const raw_items = root.object.get("invoice_items") orelse return error.InvalidResponse;
    if (raw_items != .array) return error.InvalidResponse;

    const items = try arena.alloc(InvoiceItem, raw_items.array.items.len);
    const products = try arena.alloc(Product, raw_items.array.items.len);
    var product_count: usize = 0;

    for (raw_items.array.items, 0..) |raw_value, index| {
        if (raw_value != .object) return error.InvalidResponse;
        const raw = raw_value.object;
        const product = optionalText(raw, "product") orelse "Usage";
        const amount = if (raw.get("amount")) |value|
            try parseMoneyValue(value)
        else
            0;

        items[index] = .{
            .id = optionalText(raw, "resource_uuid") orelse
                optionalText(raw, "resource_id") orelse
                try std.fmt.allocPrint(arena, "invoice-item-{d}", .{index}),
            .product = product,
            .label = optionalText(raw, "group_description") orelse
                optionalText(raw, "description") orelse
                product,
            .detail = try invoiceItemDetail(arena, raw),
            .amount_micros = amount,
        };
        owned.total_micros = std.math.add(i64, owned.total_micros, amount) catch
            return error.AmountOverflow;

        const existing = for (products[0..product_count]) |*entry| {
            if (std.mem.eql(u8, entry.name, product)) break entry;
        } else null;
        if (existing) |entry| {
            entry.count += 1;
            entry.amount_micros = std.math.add(i64, entry.amount_micros, amount) catch
                return error.AmountOverflow;
        } else {
            products[product_count] = .{
                .name = product,
                .count = 1,
                .amount_micros = amount,
            };
            product_count += 1;
        }
    }

    std.mem.sort(InvoiceItem, items, {}, itemsByAmountDesc);
    std.mem.sort(Product, products[0..product_count], {}, productsByAmountDesc);
    owned.items = items;
    owned.products = products[0..product_count];
    return owned;
}

fn itemsByAmountDesc(_: void, left: InvoiceItem, right: InvoiceItem) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.label, right.label);
}

fn productsByAmountDesc(_: void, left: Product, right: Product) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

/// "744 Hours · production", from whichever of the two the invoice carries.
fn invoiceItemDetail(
    arena: std.mem.Allocator,
    raw: std.json.ObjectMap,
) !?[]const u8 {
    var parts: [2][]const u8 = undefined;
    var count: usize = 0;

    if (optionalText(raw, "duration")) |duration| {
        parts[count] = if (optionalText(raw, "duration_unit")) |unit|
            try std.fmt.allocPrint(arena, "{s} {s}", .{ duration, unit })
        else
            duration;
        count += 1;
    }
    if (optionalText(raw, "project_name")) |project| {
        parts[count] = project;
        count += 1;
    }

    return switch (count) {
        0 => null,
        1 => parts[0],
        else => try std.fmt.allocPrint(arena, "{s} · {s}", .{ parts[0], parts[1] }),
    };
}

fn optionalText(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    const text = switch (value) {
        .string, .number_string => |text| text,
        else => return null,
    };
    if (text.len == 0) return null;
    return text;
}

fn parseMoneyValue(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string, .string => |number| money.parseMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

/// The current month has no invoice yet, so DigitalOcean exposes it as the
/// `invoice_preview` of the invoice list.
fn fetchInvoicePreviewUuid(
    allocator: std.mem.Allocator,
    client: anytype,
    token: []const u8,
) !?[]u8 {
    const response = try client.get(allocator, .{
        .url = invoices_url ++ "?per_page=1",
        .bearer_token = token,
    });
    defer response.deinit(allocator);
    try response.requireSuccess();

    const Preview = struct { invoice_uuid: []const u8 = "" };
    const Response = struct { invoice_preview: ?Preview = null };
    var parsed = try std.json.parseFromSlice(Response, allocator, response.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const preview = parsed.value.invoice_preview orelse return null;
    if (preview.invoice_uuid.len == 0) return null;
    try validateInvoiceUuid(preview.invoice_uuid);
    return try allocator.dupe(u8, preview.invoice_uuid);
}

fn fetchInvoiceItems(
    allocator: std.mem.Allocator,
    client: anytype,
    token: []const u8,
    invoice_uuid: []const u8,
) !OwnedInvoice {
    try validateInvoiceUuid(invoice_uuid);
    // One page of 200 items covers a realistic month. The macOS transport that
    // drives the app follows the whole `links.pages.next` chain.
    const url = try std.fmt.allocPrint(
        allocator,
        invoices_url ++ "/{s}?page=1&per_page=200",
        .{invoice_uuid},
    );
    defer allocator.free(url);

    const response = try client.get(allocator, .{
        .url = url,
        .bearer_token = token,
    });
    defer response.deinit(allocator);
    try response.requireSuccess();
    return parseInvoice(allocator, response.body);
}

/// An invoice UUID is interpolated into a URL that carries the API token, so it
/// is never allowed to contain anything but UUID characters.
fn validateInvoiceUuid(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidInvoiceUuid;
    for (value) |character| {
        if (std.ascii.isHex(character) or character == '-') continue;
        return error.InvalidInvoiceUuid;
    }
}

fn fetchAllDroplets(
    allocator: std.mem.Allocator,
    client: anytype,
    token: []const u8,
) !OwnedDroplets {
    var owned = OwnedDroplets{
        .arena = .init(allocator),
        .items = undefined,
    };
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    var droplets: std.ArrayList(Droplet) = .empty;

    var next_owned: ?[]u8 = null;
    defer if (next_owned) |url| allocator.free(url);
    var current_url: []const u8 = droplets_url;
    var page_count: usize = 0;

    while (true) {
        page_count += 1;
        if (page_count > 100) return error.TooManyPages;

        const response = try client.get(allocator, .{
            .url = current_url,
            .bearer_token = token,
        });
        defer response.deinit(allocator);
        try response.requireSuccess();

        const RawDroplet = struct {
            id: u64,
            name: []const u8,
            status: []const u8,
        };
        const Pages = struct { next: ?[]const u8 = null };
        const Links = struct { pages: ?Pages = null };
        const Page = struct {
            droplets: []const RawDroplet,
            links: ?Links = null,
        };
        var parsed = try std.json.parseFromSlice(Page, allocator, response.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        for (parsed.value.droplets) |raw| {
            try droplets.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "{d}", .{raw.id}),
                .name = try arena.dupe(u8, raw.name),
                .active = std.mem.eql(u8, raw.status, "active"),
            });
        }

        const next = if (parsed.value.links) |links|
            if (links.pages) |pages| pages.next else null
        else
            null;
        if (next) |url| {
            try validateDropletsPageUrl(url);
            const replacement_url = try allocator.dupe(u8, url);
            if (next_owned) |old_url| allocator.free(old_url);
            next_owned = replacement_url;
            current_url = replacement_url;
        } else {
            break;
        }
    }

    owned.items = try droplets.toOwnedSlice(arena);
    return owned;
}

fn validateDropletsPageUrl(url: []const u8) !void {
    const prefix = "https://api.digitalocean.com/v2/droplets?";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidPaginationUrl;
}

test "DigitalOcean maps droplets, spend, and prepaid credit" {
    const droplets = [_]Droplet{
        .{ .id = "1", .name = "api", .active = true, .month_to_date_micros = 12_000_000 },
        .{ .id = "2", .name = "worker", .active = false, .month_to_date_micros = 8_000_000 },
    };
    var provider = DigitalOcean{ .account = .{
        .balance_micros = -24_780_000,
        .month_to_date_micros = 20_000_000,
        .projected_month_micros = 30_000_000,
        .updated_at_unix = 100,
        .droplets = &droplets,
    } };
    defer provider.deinit();

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), report.resources.len);
    try std.testing.expectEqual(model.ResourceStatus.inactive, report.resources[1].status);
    try std.testing.expectEqual(@as(?i64, 24_780_000), report.summary.credit_remaining_micros);
}

test "DigitalOcean ingests official balance and Droplet response shapes" {
    var provider = DigitalOcean{ .account = .{
        .balance_micros = 0,
        .month_to_date_micros = 0,
        .projected_month_micros = null,
        .updated_at_unix = 0,
        .droplets = &.{},
    } };
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "balance",
        \\{"account_balance":"-24.78","month_to_date_usage":"80.39","generated_at":"2026-08-24T12:00:00Z"}
    , 1_000);
    try provider.ingest(std.testing.allocator, "droplets",
        \\{"droplets":[{"id":3164494,"name":"api","status":"active","memory":1024},{"id":3164495,"name":"worker","status":"off"}]}
    , 1_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 0,
        .end_exclusive_unix = 2_000,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 80_390_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 24_780_000), report.summary.credit_remaining_micros);
    try std.testing.expectEqualStrings("3164494", report.resources[0].id);
    try std.testing.expectEqual(@as(usize, 1), report.line_items.len);
    try std.testing.expectEqualStrings("Account usage", report.line_items[0].service);
}

test "DigitalOcean fetches billing and every Droplet page through comptime client" {
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
            try std.testing.expectEqualStrings("digitalocean-token", request.bearer_token);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, step.body),
            };
        }
    };

    const second_page = "https://api.digitalocean.com/v2/droplets?page=2&per_page=200";
    const steps = [_]Backend.Step{
        .{
            .url = balance_url,
            .body =
            \\{"account_balance":"-7.50","month_to_date_usage":"12.25"}
            ,
        },
        .{
            .url = droplets_url,
            .body =
            \\{"droplets":[{"id":1,"name":"api","status":"active"}],"links":{"pages":{"next":"https://api.digitalocean.com/v2/droplets?page=2&per_page=200"}}}
            ,
        },
        .{
            .url = second_page,
            .body =
            \\{"droplets":[{"id":2,"name":"worker","status":"off"}],"links":{}}
            ,
        },
    };
    var backend = Backend{ .steps = &steps };
    var client = http.Client(Backend).init(&backend);
    var provider = DigitalOcean.init();
    defer provider.deinit();

    try provider.fetch(
        std.testing.allocator,
        &client,
        .{ .token = "digitalocean-token" },
        1_000,
    );
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2_000,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(steps.len, backend.next);
    try std.testing.expectEqual(@as(i64, 12_250_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 7_500_000), report.summary.credit_remaining_micros);
    try std.testing.expectEqual(@as(usize, 2), report.resources.len);
    try std.testing.expectEqual(model.ResourceStatus.inactive, report.resources[1].status);
}

test "DigitalOcean rejects pagination URLs that could receive its token" {
    try std.testing.expectError(
        error.InvalidPaginationUrl,
        validateDropletsPageUrl("https://attacker.test/v2/droplets?page=2"),
    );
}

const invoice_payload =
    \\{"invoice_items":[{"product":"Droplets","resource_uuid":"a","description":"api","amount":"24.00","duration":"744","duration_unit":"Hours","project_name":"prod"},{"product":"Droplets","resource_uuid":"b","description":"worker","amount":"12.00","duration":"744","duration_unit":"Hours"},{"product":"App Platform","resource_uuid":"c","group_description":"my-app","description":"basic","amount":"5.00"},{"product":"Taxes","description":"VAT","amount":"1.00"}],"meta":{"total":4}}
;

test "DigitalOcean groups the running invoice into billed products" {
    var provider = DigitalOcean.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "balance",
        \\{"account_balance":"-24.78","month_to_date_usage":"45.00"}
    , 1_000);
    try provider.ingest(std.testing.allocator, "invoice", invoice_payload, 1_000);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2_000,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), report.resources.len);
    try std.testing.expectEqualStrings("Droplets", report.resources[0].name);
    try std.testing.expectEqualStrings("product", report.resources[0].kind);
    try std.testing.expectEqual(@as(u64, 2), report.resources[0].quantity);
    try std.testing.expectEqualStrings("App Platform", report.resources[1].name);

    try std.testing.expectEqual(@as(usize, 5), report.line_items.len);
    try std.testing.expectEqualStrings("api", report.line_items[0].description);
    try std.testing.expectEqualStrings("Droplets", report.line_items[0].service);
    try std.testing.expectEqualStrings("744 Hours · prod", report.line_items[0].detail.?);
    try std.testing.expectEqualStrings("my-app", report.line_items[2].description);
    // The balance API is authoritative for the total, so anything the invoice
    // has not caught up with stays visible instead of being dropped.
    try std.testing.expectEqualStrings(
        "Usage not yet on the invoice",
        report.line_items[4].description,
    );
    try std.testing.expectEqual(@as(i64, 3_000_000), report.line_items[4].amount_micros);
}

test "DigitalOcean fetches the preview invoice through the comptime client" {
    const uuid = "fdabb512-6faf-443c-9fd4-fc046b4bd7bd";
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
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, step.body),
            };
        }
    };

    const steps = [_]Backend.Step{
        .{
            .url = balance_url,
            .body =
            \\{"account_balance":"0.00","month_to_date_usage":"42.00"}
            ,
        },
        .{
            .url = droplets_url,
            .body =
            \\{"droplets":[{"id":1,"name":"api","status":"active"}]}
            ,
        },
        .{
            .url = invoices_url ++ "?per_page=1",
            .body =
            \\{"invoices":[],"invoice_preview":{"invoice_uuid":"fdabb512-6faf-443c-9fd4-fc046b4bd7bd","amount":"42.00","invoice_period":"2026-08"}}
            ,
        },
        .{
            .url = invoices_url ++ "/" ++ uuid ++ "?page=1&per_page=200",
            .body = invoice_payload,
        },
    };

    var backend = Backend{ .steps = &steps };
    var client = http.Client(Backend).init(&backend);
    var provider = DigitalOcean.init();
    defer provider.deinit();

    try provider.fetch(
        std.testing.allocator,
        &client,
        .{ .token = "digitalocean-token" },
        1_000,
    );
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2_000,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(steps.len, backend.next);
    try std.testing.expectEqual(@as(i64, 42_000_000), report.summary.current_cost_micros);
    // Products first, then the individual Droplets from the Droplet feed.
    try std.testing.expectEqualStrings("Droplets", report.resources[0].name);
    try std.testing.expectEqualStrings("api", report.resources[3].name);
    try std.testing.expectEqual(@as(usize, 4), report.line_items.len);
}

test "DigitalOcean keeps reporting when the token cannot read invoices" {
    const Backend = struct {
        pub fn get(
            _: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            if (std.mem.startsWith(u8, request.url, invoices_url)) {
                return .{ .status = 403, .body = try allocator.dupe(u8, "{}") };
            }
            if (std.mem.eql(u8, request.url, balance_url)) {
                return .{
                    .status = 200,
                    .body = try allocator.dupe(u8,
                        \\{"account_balance":"0.00","month_to_date_usage":"9.00"}
                    ),
                };
            }
            return .{
                .status = 200,
                .body = try allocator.dupe(u8,
                    \\{"droplets":[{"id":1,"name":"api","status":"active"}]}
                ),
            };
        }
    };

    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    var provider = DigitalOcean.init();
    defer provider.deinit();

    try provider.fetch(
        std.testing.allocator,
        &client,
        .{ .token = "digitalocean-token" },
        1_000,
    );
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2_000,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 9_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqualStrings("Account usage", report.line_items[0].service);
}

test "DigitalOcean rejects invoice UUIDs that could rewrite the request URL" {
    try std.testing.expectError(
        error.InvalidInvoiceUuid,
        validateInvoiceUuid("../../../v2/account?leak="),
    );
}
