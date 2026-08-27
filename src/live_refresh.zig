const std = @import("std");
const http = @import("http.zig");
const model = @import("model.zig");
const digitalocean = @import("providers/digitalocean.zig");
const hetzner = @import("providers/hetzner.zig");
const cloudflare = @import("providers/cloudflare.zig");
const runpod = @import("providers/runpod.zig");
const vercel = @import("providers/vercel.zig");
const openrouter = @import("providers/openrouter.zig");
const openai_api = @import("providers/openai_api.zig");
const anthropic_api = @import("providers/anthropic_api.zig");
const xai_api = @import("providers/xai_api.zig");
const github = @import("providers/github.zig");
const cursor = @import("providers/cursor.zig");

pub const Kind = enum {
    digitalocean,
    hetzner,
    cloudflare,
    runpod,
    vercel,
    openrouter,
    openai_api,
    anthropic_api,
    xai_api,
    github,
    cursor,
};

pub const Credentials = struct {
    digitalocean_token: ?[]const u8 = null,
    hetzner_token: ?[]const u8 = null,
    cloudflare_token: ?[]const u8 = null,
    cloudflare_account_id: ?[]const u8 = null,
    runpod_api_key: ?[]const u8 = null,
    vercel_token: ?[]const u8 = null,
    vercel_team: ?[]const u8 = null,
    openrouter_api_key: ?[]const u8 = null,
    openrouter_management_key: ?[]const u8 = null,
    openai_admin_key: ?[]const u8 = null,
    anthropic_admin_key: ?[]const u8 = null,
    xai_management_key: ?[]const u8 = null,
    xai_team_id: ?[]const u8 = null,
    github_token: ?[]const u8 = null,
    github_organization: ?[]const u8 = null,
    github_use_cli: bool = false,
    cursor_admin_key: ?[]const u8 = null,

    pub fn isConfigured(self: Credentials, kind: Kind) bool {
        return switch (kind) {
            .digitalocean => nonEmpty(self.digitalocean_token),
            .hetzner => nonEmpty(self.hetzner_token),
            .cloudflare => nonEmpty(self.cloudflare_token) and nonEmpty(self.cloudflare_account_id),
            .runpod => nonEmpty(self.runpod_api_key),
            .vercel => nonEmpty(self.vercel_token),
            .openrouter => nonEmpty(self.openrouter_api_key),
            .openai_api => nonEmpty(self.openai_admin_key),
            .anthropic_api => nonEmpty(self.anthropic_admin_key),
            .xai_api => nonEmpty(self.xai_management_key) and nonEmpty(self.xai_team_id),
            .github => nonEmpty(self.github_organization) and
                (self.github_use_cli or nonEmpty(self.github_token)),
            .cursor => nonEmpty(self.cursor_admin_key),
        };
    }
};

pub const Providers = struct {
    digitalocean: *digitalocean.DigitalOcean,
    hetzner: *hetzner.Hetzner,
    cloudflare: *cloudflare.Cloudflare,
    runpod: *runpod.Runpod,
    vercel: *vercel.Vercel,
    openrouter: *openrouter.OpenRouter,
    openai_api: *openai_api.OpenAIAPI,
    anthropic_api: *anthropic_api.AnthropicAPI,
    xai_api: *xai_api.XAIAPI,
    github: *github.GitHub,
    cursor: *cursor.Cursor,
};

/// Performs one complete provider refresh. HTTP, pagination, response parsing,
/// response composition, and provider decoding all remain on the Zig side of
/// the ABI. Callers can run different `Kind` values concurrently because every
/// branch mutates a distinct provider instance.
pub fn refresh(
    allocator: std.mem.Allocator,
    standard_client: *std.http.Client,
    providers: Providers,
    credentials: Credentials,
    kind: Kind,
    period: model.Period,
    now: i64,
) !void {
    var backend = http.StdBackend{ .client = standard_client };
    var client = http.Client(http.StdBackend).init(&backend);
    return refreshWithClient(
        allocator,
        &client,
        providers,
        credentials,
        kind,
        period,
        now,
    );
}

/// The same refresh over any compile-time HTTP client, so an instrumented
/// transport can measure a provider without restating its request sequence.
pub fn refreshWithClient(
    allocator: std.mem.Allocator,
    client: anytype,
    providers: Providers,
    credentials: Credentials,
    kind: Kind,
    period: model.Period,
    now: i64,
) !void {
    switch (kind) {
        .digitalocean => try providers.digitalocean.fetch(
            allocator,
            client,
            .{ .token = credentials.digitalocean_token.? },
            now,
        ),
        .hetzner => try providers.hetzner.fetch(
            allocator,
            client,
            .{ .token = credentials.hetzner_token.? },
            now,
        ),
        .cloudflare => try providers.cloudflare.fetch(
            allocator,
            client,
            .{
                .token = credentials.cloudflare_token.?,
                .account_id = credentials.cloudflare_account_id.?,
            },
            now,
        ),
        .runpod => try refreshRunpod(
            allocator,
            client,
            providers.runpod,
            credentials.runpod_api_key.?,
            period,
            now,
        ),
        .vercel => try refreshVercel(
            allocator,
            client,
            providers.vercel,
            credentials.vercel_token.?,
            credentials.vercel_team,
            period,
            now,
        ),
        .openrouter => try refreshOpenRouter(
            allocator,
            client,
            providers.openrouter,
            credentials.openrouter_api_key.?,
            credentials.openrouter_management_key,
            period,
            now,
        ),
        .openai_api => try refreshOpenAI(
            allocator,
            client,
            providers.openai_api,
            credentials.openai_admin_key.?,
            period,
            now,
        ),
        .anthropic_api => try refreshAnthropic(
            allocator,
            client,
            providers.anthropic_api,
            credentials.anthropic_admin_key.?,
            period,
            now,
        ),
        .xai_api => try refreshXAI(
            allocator,
            client,
            providers.xai_api,
            credentials.xai_management_key.?,
            credentials.xai_team_id.?,
            period,
            now,
        ),
        .github => if (credentials.github_use_cli)
            return error.GitHubCLIRequiresProcessRuntime
        else
            try refreshGitHub(
                allocator,
                client,
                providers.github,
                credentials.github_token orelse return error.MissingCredential,
                credentials.github_organization.?,
                period,
                now,
            ),
        .cursor => try refreshCursor(
            allocator,
            client,
            providers.cursor,
            credentials.cursor_admin_key.?,
            period,
            now,
        ),
    }
}

fn refreshRunpod(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *runpod.Runpod,
    api_key: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const account_body =
        \\{"query":"query CostbarAccount { myself { clientBalance currentSpendPerHr pods { id name } } }"}
    ;
    const account = try fetch(allocator, client, .{
        .url = "https://api.runpod.io/graphql",
        .bearer_token = api_key,
        .method = .POST,
        .payload = account_body,
        .content_type = "application/json",
    });
    defer allocator.free(account);

    const end = reportEnd(period, now);
    const start_iso = try iso8601(allocator, period.start_unix, false);
    defer allocator.free(start_iso);
    const end_iso = try iso8601(allocator, end, false);
    defer allocator.free(end_iso);

    const pods = try fetchRunpodBilling(
        allocator,
        client,
        api_key,
        "pods",
        "podId",
        start_iso,
        end_iso,
    );
    defer allocator.free(pods);
    const endpoints = try fetchRunpodBilling(
        allocator,
        client,
        api_key,
        "endpoints",
        "endpointId",
        start_iso,
        end_iso,
    );
    defer allocator.free(endpoints);
    const volumes = try fetchRunpodBilling(
        allocator,
        client,
        api_key,
        "networkvolumes",
        null,
        start_iso,
        end_iso,
    );
    defer allocator.free(volumes);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"account\":");
    try output.writer.writeAll(account);
    try output.writer.writeAll(",\"pods\":");
    try output.writer.writeAll(pods);
    try output.writer.writeAll(",\"endpoints\":");
    try output.writer.writeAll(endpoints);
    try output.writer.writeAll(",\"networkVolumes\":");
    try output.writer.writeAll(volumes);
    try output.writer.writeByte('}');
    try provider.ingest(allocator, "snapshot", output.written(), now);
}

fn fetchRunpodBilling(
    allocator: std.mem.Allocator,
    client: anytype,
    api_key: []const u8,
    resource: []const u8,
    grouping: ?[]const u8,
    start_iso: []const u8,
    end_iso: []const u8,
) ![]u8 {
    const url = try runpodBillingURL(
        allocator,
        resource,
        grouping,
        start_iso,
        end_iso,
    );
    defer allocator.free(url);
    return fetch(allocator, client, .{ .url = url, .bearer_token = api_key });
}

fn runpodBillingURL(
    allocator: std.mem.Allocator,
    resource: []const u8,
    grouping: ?[]const u8,
    start_iso: []const u8,
    end_iso: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://rest.runpod.io/v1/billing/{s}?startTime={s}&endTime={s}&bucketSize=month{s}{s}",
        .{
            resource,
            start_iso,
            end_iso,
            if (grouping == null) "" else "&grouping=",
            grouping orelse "",
        },
    );
}

fn refreshVercel(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *vercel.Vercel,
    token: []const u8,
    raw_team: ?[]const u8,
    period: model.Period,
    now: i64,
) !void {
    const start = try iso8601(allocator, period.start_unix, true);
    defer allocator.free(start);
    const end = try iso8601(allocator, @min(@max(now, period.start_unix), period.end_exclusive_unix), true);
    defer allocator.free(end);
    const team = if (raw_team) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    const scope = if (team.len == 0)
        try allocator.dupe(u8, "")
    else
        try queryParameter(
            allocator,
            if (std.mem.startsWith(u8, team, "team_")) "teamId" else "slug",
            team,
        );
    defer allocator.free(scope);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.vercel.com/v1/billing/charges?from={s}&to={s}{s}",
        .{ start, end, scope },
    );
    defer allocator.free(url);
    const accept = [_]std.http.Header{.{
        .name = "Accept",
        .value = "application/x-ndjson, application/json",
    }};
    const body = try fetch(allocator, client, .{
        .url = url,
        .bearer_token = token,
        .extra_headers = &accept,
        .max_response_bytes = 64 * 1024 * 1024,
    });
    defer allocator.free(body);
    try provider.ingest(allocator, "charges", body, now);
}

fn refreshOpenRouter(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *openrouter.OpenRouter,
    api_key: []const u8,
    raw_management_key: ?[]const u8,
    period: model.Period,
    now: i64,
) !void {
    const key = try fetch(allocator, client, .{
        .url = "https://openrouter.ai/api/v1/key",
        .bearer_token = api_key,
    });
    defer allocator.free(key);

    var credits: ?[]u8 = null;
    defer if (credits) |body| allocator.free(body);
    var analytics: ?[]u8 = null;
    defer if (analytics) |body| allocator.free(body);
    if (raw_management_key) |raw| {
        const management_key = std.mem.trim(u8, raw, " \t\r\n");
        if (management_key.len > 0) {
            credits = fetch(allocator, client, .{
                .url = "https://openrouter.ai/api/v1/credits",
                .bearer_token = management_key,
            }) catch null;

            const report_end = reportEnd(period, now);
            const history_start = report_end -| 30 * std.time.s_per_day;
            const query_start = @min(period.start_unix, history_start);
            const start = try iso8601(allocator, query_start, false);
            defer allocator.free(start);
            const end = try iso8601(allocator, report_end, false);
            defer allocator.free(end);
            const analytics_query = try std.fmt.allocPrint(
                allocator,
                "{{\"metrics\":[\"total_usage\",\"tokens_prompt\",\"tokens_completion\",\"reasoning_tokens\"],\"dimensions\":[\"model\"],\"granularity\":\"hour\",\"time_range\":{{\"start\":\"{s}\",\"end\":\"{s}\"}},\"limit\":10000}}",
                .{ start, end },
            );
            defer allocator.free(analytics_query);
            analytics = fetch(allocator, client, .{
                .url = "https://openrouter.ai/api/v1/analytics/query",
                .bearer_token = management_key,
                .method = .POST,
                .payload = analytics_query,
                .content_type = "application/json",
                .max_response_bytes = 16 * 1024 * 1024,
            }) catch null;
        }
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"key\":");
    try output.writer.writeAll(key);
    try output.writer.print(
        ",\"activity_period\":{{\"start_unix\":{d},\"end_exclusive_unix\":{d}}},\"history_period\":{{\"start_unix\":{d},\"end_exclusive_unix\":{d}}}",
        .{
            period.start_unix,
            period.end_exclusive_unix,
            reportEnd(period, now) -| 30 * std.time.s_per_day,
            reportEnd(period, now),
        },
    );
    if (credits) |body| {
        try output.writer.writeAll(",\"credits\":");
        try output.writer.writeAll(body);
    }
    if (analytics) |body| {
        try output.writer.writeAll(",\"analytics\":");
        try output.writer.writeAll(body);
    }
    try output.writer.writeByte('}');
    try provider.ingest(allocator, "snapshot", output.written(), now);
}

fn refreshOpenAI(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *openai_api.OpenAIAPI,
    admin_key: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const end = reportEnd(period, now);
    const costs_query = try std.fmt.allocPrint(
        allocator,
        "start_time={d}&end_time={d}&bucket_width=1d&limit=180&group_by%5B%5D=project_id&group_by%5B%5D=line_item",
        .{ period.start_unix, end },
    );
    defer allocator.free(costs_query);
    const usage_query = try std.fmt.allocPrint(
        allocator,
        "start_time={d}&end_time={d}&bucket_width=1d&limit=31&group_by%5B%5D=model",
        .{ period.start_unix, end },
    );
    defer allocator.free(usage_query);
    const costs = try pagedReport(
        allocator,
        client,
        "https://api.openai.com/v1/organization/costs",
        costs_query,
        .{ .bearer_token = admin_key },
    );
    defer allocator.free(costs);
    const usage = try pagedReport(
        allocator,
        client,
        "https://api.openai.com/v1/organization/usage/completions",
        usage_query,
        .{ .bearer_token = admin_key },
    );
    defer allocator.free(usage);
    try ingestOrganization(allocator, provider, "organization", period, costs, usage, now);
}

fn refreshAnthropic(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *anthropic_api.AnthropicAPI,
    admin_key: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const end_unix = reportEnd(period, now);
    const start = try iso8601(allocator, period.start_unix, false);
    defer allocator.free(start);
    const end = try iso8601(allocator, end_unix, false);
    defer allocator.free(end);
    const costs_query = try std.fmt.allocPrint(
        allocator,
        "starting_at={s}&ending_at={s}&bucket_width=1d&limit=31&group_by%5B%5D=workspace_id&group_by%5B%5D=description",
        .{ start, end },
    );
    defer allocator.free(costs_query);
    const usage_query = try std.fmt.allocPrint(
        allocator,
        "starting_at={s}&ending_at={s}&bucket_width=1d&limit=31&group_by%5B%5D=model",
        .{ start, end },
    );
    defer allocator.free(usage_query);
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "x-api-key", .value = admin_key },
    };
    const costs = try pagedReport(
        allocator,
        client,
        "https://api.anthropic.com/v1/organizations/cost_report",
        costs_query,
        .{ .extra_headers = &headers },
    );
    defer allocator.free(costs);
    const usage = try pagedReport(
        allocator,
        client,
        "https://api.anthropic.com/v1/organizations/usage_report/messages",
        usage_query,
        .{ .extra_headers = &headers },
    );
    defer allocator.free(usage);
    try ingestOrganization(allocator, provider, "organization", period, costs, usage, now);
}

const RequestAuthentication = struct {
    bearer_token: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
};

fn pagedReport(
    allocator: std.mem.Allocator,
    client: anytype,
    base_url: []const u8,
    base_query: []const u8,
    authentication: RequestAuthentication,
) ![]u8 {
    const Page = struct {
        data: []std.json.Value,
        has_more: bool = false,
        next_page: ?[]const u8 = null,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeByte('[');
    var cursor_value: ?[]u8 = null;
    defer if (cursor_value) |value| allocator.free(value);
    var page_count: usize = 0;
    while (true) {
        page_count += 1;
        if (page_count > 100) return error.TooManyPages;
        const cursor_query = if (cursor_value) |value|
            try queryParameter(allocator, "page", value)
        else
            try allocator.dupe(u8, "");
        defer allocator.free(cursor_query);
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}?{s}{s}",
            .{ base_url, base_query, cursor_query },
        );
        defer allocator.free(url);
        const body = try fetch(allocator, client, .{
            .url = url,
            .bearer_token = authentication.bearer_token,
            .extra_headers = authentication.extra_headers,
            .max_response_bytes = 32 * 1024 * 1024,
        });
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(Page, allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (page_count > 1) try output.writer.writeByte(',');
        try output.writer.writeAll(body);
        if (!parsed.value.has_more) break;
        const next = parsed.value.next_page orelse return error.InvalidResponse;
        const replacement = try allocator.dupe(u8, next);
        if (cursor_value) |old| allocator.free(old);
        cursor_value = replacement;
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

fn ingestOrganization(
    allocator: std.mem.Allocator,
    provider: anytype,
    document: []const u8,
    period: model.Period,
    costs: []const u8,
    usage: []const u8,
    now: i64,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print(
        "{{\"period\":{{\"start_unix\":{d},\"end_exclusive_unix\":{d}}},\"cost_pages\":",
        .{ period.start_unix, period.end_exclusive_unix },
    );
    try output.writer.writeAll(costs);
    try output.writer.writeAll(",\"usage_pages\":");
    try output.writer.writeAll(usage);
    try output.writer.writeByte('}');
    try provider.ingest(allocator, document, output.written(), now);
}

fn refreshXAI(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *xai_api.XAIAPI,
    management_key: []const u8,
    raw_team_id: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const team_id = std.mem.trim(u8, raw_team_id, " \t\r\n");
    if (team_id.len == 0 or team_id.len > 128) return error.InvalidTeamID;
    for (team_id) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
            return error.InvalidTeamID;
        }
    }
    const report_end = reportEnd(period, now);
    const start_time = try analyticsTimestamp(allocator, period.start_unix);
    defer allocator.free(start_time);
    const end_time = try analyticsTimestamp(allocator, report_end - 1);
    defer allocator.free(end_time);
    const usage_url = try std.fmt.allocPrint(
        allocator,
        "https://management-api.x.ai/v1/billing/teams/{s}/usage",
        .{team_id},
    );
    defer allocator.free(usage_url);
    const balance_url = try std.fmt.allocPrint(
        allocator,
        "https://management-api.x.ai/v1/billing/teams/{s}/prepaid/balance",
        .{team_id},
    );
    defer allocator.free(balance_url);
    const request_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"analyticsRequest\":{{\"timeRange\":{{\"startTime\":\"{s}\",\"endTime\":\"{s}\",\"timezone\":\"Etc/GMT\"}},\"timeUnit\":\"TIME_UNIT_DAY\",\"values\":[{{\"name\":\"usd\",\"aggregation\":\"AGGREGATION_SUM\"}}],\"groupBy\":[\"description\"],\"filters\":[]}}}}",
        .{ start_time, end_time },
    );
    defer allocator.free(request_payload);
    const usage = try fetch(allocator, client, .{
        .url = usage_url,
        .bearer_token = management_key,
        .method = .POST,
        .payload = request_payload,
        .content_type = "application/json",
        .max_response_bytes = 16 * 1024 * 1024,
    });
    defer allocator.free(usage);
    const balance = try fetch(allocator, client, .{
        .url = balance_url,
        .bearer_token = management_key,
        .max_response_bytes = 4 * 1024 * 1024,
    });
    defer allocator.free(balance);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print(
        "{{\"period\":{{\"start_unix\":{d},\"end_exclusive_unix\":{d}}},\"usage\":",
        .{ period.start_unix, period.end_exclusive_unix },
    );
    try output.writer.writeAll(usage);
    try output.writer.writeAll(",\"balance\":");
    try output.writer.writeAll(balance);
    try output.writer.writeByte('}');
    try provider.ingest(allocator, "billing", output.written(), now);
}

fn refreshGitHub(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *github.GitHub,
    token: []const u8,
    raw_organizations: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const organizations = try githubOrganizations(allocator, raw_organizations);
    defer allocator.free(organizations);
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2026-03-10" },
    };
    var documents: std.ArrayList(github.OrganizationUsage) = .empty;
    defer {
        for (documents.items) |document| allocator.free(document.payload);
        documents.deinit(allocator);
    }
    for (organizations) |organization| {
        const path = try githubBillingPath(allocator, organization, period);
        defer allocator.free(path);
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.github.com{s}",
            .{path},
        );
        defer allocator.free(url);
        const body = try fetch(allocator, client, .{
            .url = url,
            .bearer_token = token,
            .extra_headers = &headers,
        });
        errdefer allocator.free(body);
        try documents.append(allocator, .{
            .organization = organization,
            .payload = body,
        });
    }
    try provider.ingestOrganizations(allocator, documents.items, now);
}

pub fn refreshGitHubCLI(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    provider: *github.GitHub,
    raw_organizations: []const u8,
    period: model.Period,
    now: i64,
) !void {
    var runner = GitHubCLIRunner{ .io = io, .home = home };
    return refreshGitHubWithRunner(
        allocator,
        &runner,
        provider,
        raw_organizations,
        period,
        now,
    );
}

fn refreshGitHubWithRunner(
    allocator: std.mem.Allocator,
    runner: anytype,
    provider: *github.GitHub,
    raw_organizations: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const organizations = try githubOrganizations(allocator, raw_organizations);
    defer allocator.free(organizations);
    var documents: std.ArrayList(github.OrganizationUsage) = .empty;
    defer {
        for (documents.items) |document| allocator.free(document.payload);
        documents.deinit(allocator);
    }
    for (organizations) |organization| {
        const path = try githubBillingPath(allocator, organization, period);
        defer allocator.free(path);
        const body = try runner.run(allocator, path);
        errdefer allocator.free(body);
        try documents.append(allocator, .{
            .organization = organization,
            .payload = body,
        });
    }
    try provider.ingestOrganizations(allocator, documents.items, now);
}

pub fn discoverGitHubCLIOrganizations(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
) ![]u8 {
    var runner = GitHubCLIRunner{ .io = io, .home = home };
    return discoverGitHubCLIOrganizationsWithRunner(allocator, &runner);
}

fn discoverGitHubCLIOrganizationsWithRunner(
    allocator: std.mem.Allocator,
    runner: anytype,
) ![]u8 {
    const raw = try runner.listOrganizations(allocator);
    defer allocator.free(raw);
    const organizations = try githubOrganizations(allocator, raw);
    defer allocator.free(organizations);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (organizations, 0..) |organization, index| {
        if (index > 0) try output.writer.writeByte('\n');
        try output.writer.writeAll(organization);
    }
    return output.toOwnedSlice();
}

const GitHubCLIRunner = struct {
    io: std.Io,
    home: []const u8,

    fn run(self: *GitHubCLIRunner, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.runCommand(allocator, path, .billing);
    }

    fn listOrganizations(self: *GitHubCLIRunner, allocator: std.mem.Allocator) ![]u8 {
        return self.runCommand(allocator, "/user/orgs?per_page=100", .organizations);
    }

    const Command = enum { billing, organizations };

    fn runCommand(
        self: *GitHubCLIRunner,
        allocator: std.mem.Allocator,
        path: []const u8,
        command: Command,
    ) ![]u8 {
        const home_executable = try std.fs.path.join(
            allocator,
            &.{ self.home, ".nix-profile/bin/gh" },
        );
        defer allocator.free(home_executable);
        const user_executable = try std.fmt.allocPrint(
            allocator,
            "/etc/profiles/per-user/{s}/bin/gh",
            .{std.fs.path.basename(self.home)},
        );
        defer allocator.free(user_executable);
        const candidates = [_][]const u8{
            home_executable,
            user_executable,
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/run/current-system/sw/bin/gh",
            "gh",
        };
        for (candidates) |executable| {
            const result = switch (command) {
                .billing => result: {
                    const argv = githubCLIArguments(executable, path);
                    break :result std.process.run(allocator, self.io, .{
                        .argv = &argv,
                        .stdout_limit = .limited(32 * 1024 * 1024),
                        .stderr_limit = .limited(1024 * 1024),
                        .timeout = .{ .duration = .{
                            .clock = .awake,
                            .raw = .fromSeconds(30),
                        } },
                    });
                },
                .organizations => result: {
                    const argv = githubCLIOrganizationArguments(executable, path);
                    break :result std.process.run(allocator, self.io, .{
                        .argv = &argv,
                        .stdout_limit = .limited(4 * 1024 * 1024),
                        .stderr_limit = .limited(1024 * 1024),
                        .timeout = .{ .duration = .{
                            .clock = .awake,
                            .raw = .fromSeconds(30),
                        } },
                    });
                },
            } catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            allocator.free(result.stderr);
            if (result.term == .exited and result.term.exited == 0) {
                return result.stdout;
            }
            allocator.free(result.stdout);
            return switch (result.term) {
                .exited => |code| if (code == 4)
                    error.GitHubCLISignedOut
                else
                    error.GitHubCLIRequestFailed,
                else => error.GitHubCLIRequestFailed,
            };
        }
        return error.GitHubCLINotInstalled;
    }
};

fn githubCLIArguments(executable: []const u8, path: []const u8) [11][]const u8 {
    return .{
        executable,
        "api",
        "--hostname",
        "github.com",
        "--method",
        "GET",
        "--header",
        "Accept: application/vnd.github+json",
        "--header",
        "X-GitHub-Api-Version: 2026-03-10",
        path,
    };
}

fn githubCLIOrganizationArguments(executable: []const u8, path: []const u8) [14][]const u8 {
    return .{
        executable,
        "api",
        "--hostname",
        "github.com",
        "--method",
        "GET",
        "--header",
        "Accept: application/vnd.github+json",
        "--header",
        "X-GitHub-Api-Version: 2026-03-10",
        "--paginate",
        "--jq",
        ".[].login",
        path,
    };
}

fn githubOrganizations(
    allocator: std.mem.Allocator,
    raw_organizations: []const u8,
) ![][]const u8 {
    var organizations: std.ArrayList([]const u8) = .empty;
    errdefer organizations.deinit(allocator);
    var values = std.mem.tokenizeAny(u8, raw_organizations, ",\r\n");
    while (values.next()) |raw_organization| {
        const organization = std.mem.trim(u8, raw_organization, " \t");
        try validateGitHubOrganization(organization);
        const duplicate = for (organizations.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, organization)) break true;
        } else false;
        if (!duplicate) try organizations.append(allocator, organization);
        if (organizations.items.len > 100) return error.TooManyOrganizations;
    }
    if (organizations.items.len == 0) return error.InvalidOrganization;
    return organizations.toOwnedSlice(allocator);
}

fn validateGitHubOrganization(organization: []const u8) !void {
    if (organization.len == 0 or organization.len > 100) {
        return error.InvalidOrganization;
    }
    for (organization) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-') {
            return error.InvalidOrganization;
        }
    }
}

fn githubBillingPath(
    allocator: std.mem.Allocator,
    raw_organization: []const u8,
    period: model.Period,
) ![]u8 {
    const organization = std.mem.trim(u8, raw_organization, " \t\r\n");
    try validateGitHubOrganization(organization);
    const date = dateTime(period.start_unix) orelse return error.InvalidPeriod;
    return std.fmt.allocPrint(
        allocator,
        "/organizations/{s}/settings/billing/usage?year={d}&month={d}",
        .{ organization, date.year, date.month },
    );
}

fn refreshCursor(
    allocator: std.mem.Allocator,
    client: anytype,
    provider: *cursor.Cursor,
    admin_key: []const u8,
    period: model.Period,
    now: i64,
) !void {
    const Page = struct {
        usageEvents: []std.json.Value,
        pagination: ?struct { hasNextPage: bool = false } = null,
        totalPages: ?usize = null,
    };
    const credential = try std.fmt.allocPrint(allocator, "{s}:", .{admin_key});
    defer allocator.free(credential);
    const encoded_len = std.base64.standard.Encoder.calcSize(credential.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, credential);
    const authorization = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    defer allocator.free(authorization);

    var pages: std.Io.Writer.Allocating = .init(allocator);
    defer pages.deinit();
    try pages.writer.writeByte('[');
    var page_number: usize = 1;
    while (true) : (page_number += 1) {
        if (page_number > 100) return error.TooManyPages;
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"startDate\":{d},\"endDate\":{d},\"page\":{d},\"pageSize\":500}}",
            .{ period.start_unix * 1000, reportEnd(period, now) * 1000, page_number },
        );
        defer allocator.free(payload);
        const body = try fetch(allocator, client, .{
            .url = "https://api.cursor.com/teams/filtered-usage-events",
            .authorization = authorization,
            .method = .POST,
            .payload = payload,
            .content_type = "application/json",
            .max_response_bytes = 32 * 1024 * 1024,
        });
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(Page, allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (page_number > 1) try pages.writer.writeByte(',');
        try pages.writer.writeAll(body);
        const has_next = if (parsed.value.pagination) |pagination|
            pagination.hasNextPage
        else if (parsed.value.totalPages) |total|
            page_number < total
        else
            false;
        if (!has_next) break;
    }
    try pages.writer.writeByte(']');

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print(
        "{{\"period\":{{\"start_unix\":{d},\"end_exclusive_unix\":{d}}},\"pages\":",
        .{ period.start_unix, period.end_exclusive_unix },
    );
    try output.writer.writeAll(pages.written());
    try output.writer.writeByte('}');
    try provider.ingest(allocator, "usage-events", output.written(), now);
}

fn fetch(
    allocator: std.mem.Allocator,
    client: anytype,
    request: http.Request,
) ![]u8 {
    const response = try client.get(allocator, request);
    errdefer response.deinit(allocator);
    try response.requireSuccess();
    return response.body;
}

fn queryParameter(allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeByte('&');
    try output.writer.writeAll(name);
    try output.writer.writeByte('=');
    for (value) |character| {
        if (std.ascii.isAlphanumeric(character) or
            character == '-' or character == '_' or character == '.' or character == '~')
        {
            try output.writer.writeByte(character);
        } else {
            try output.writer.print("%{X:0>2}", .{character});
        }
    }
    return output.toOwnedSlice();
}

fn reportEnd(period: model.Period, now: i64) i64 {
    return @min(@max(now, period.start_unix + 1), period.end_exclusive_unix);
}

const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn dateTime(timestamp: i64) ?DateTime {
    if (timestamp < 0) return null;
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

fn iso8601(allocator: std.mem.Allocator, timestamp: i64, fractional: bool) ![]u8 {
    const value = dateTime(timestamp) orelse return error.InvalidPeriod;
    return if (fractional)
        std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z",
            .{ value.year, value.month, value.day, value.hour, value.minute, value.second },
        )
    else
        std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ value.year, value.month, value.day, value.hour, value.minute, value.second },
        );
}

fn analyticsTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const value = dateTime(timestamp) orelse return error.InvalidPeriod;
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ value.year, value.month, value.day, value.hour, value.minute, value.second },
    );
}

fn nonEmpty(value: ?[]const u8) bool {
    return if (value) |found| std.mem.trim(u8, found, " \t\r\n").len > 0 else false;
}

test "provider configuration requires complete credential pairs" {
    const credentials = Credentials{
        .digitalocean_token = "token",
        .hetzner_token = "token",
        .cloudflare_token = "token",
        .github_token = "token",
        .github_organization = "org",
        .xai_management_key = "management",
    };
    try std.testing.expect(credentials.isConfigured(.digitalocean));
    try std.testing.expect(credentials.isConfigured(.hetzner));
    try std.testing.expect(!credentials.isConfigured(.cloudflare));
    try std.testing.expect(credentials.isConfigured(.github));
    try std.testing.expect(!credentials.isConfigured(.xai_api));
    try std.testing.expect(!credentials.isConfigured(.cursor));

    const github_cli = Credentials{
        .github_organization = "org",
        .github_use_cli = true,
    };
    try std.testing.expect(github_cli.isConfigured(.github));
}

test "UTC API timestamps are formatted without Foundation" {
    const value = try iso8601(std.testing.allocator, 0, true);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", value);
}

test "xAI analytics timestamps use the management API format" {
    const value = try analyticsTimestamp(std.testing.allocator, 0);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", value);
}

test "OpenRouter refresh queries rolling analytics by model and hour" {
    const Backend = struct {
        calls: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            const body = switch (self.calls) {
                0 => blk: {
                    try std.testing.expectEqualStrings(
                        "https://openrouter.ai/api/v1/key",
                        request.url,
                    );
                    try std.testing.expectEqualStrings("inference-secret", request.bearer_token.?);
                    break :blk "{\"data\":{\"usage_monthly\":0}}";
                },
                1 => blk: {
                    try std.testing.expectEqualStrings(
                        "https://openrouter.ai/api/v1/credits",
                        request.url,
                    );
                    try std.testing.expectEqualStrings("management-secret", request.bearer_token.?);
                    break :blk "{\"data\":{\"total_credits\":50,\"total_usage\":0.25}}";
                },
                2 => blk: {
                    try std.testing.expectEqualStrings(
                        "https://openrouter.ai/api/v1/analytics/query",
                        request.url,
                    );
                    try std.testing.expectEqualStrings("management-secret", request.bearer_token.?);
                    try std.testing.expectEqual(std.http.Method.POST, request.method);
                    try std.testing.expectEqualStrings("application/json", request.content_type.?);
                    try std.testing.expect(std.mem.indexOf(
                        u8,
                        request.payload.?,
                        "\"metrics\":[\"total_usage\",\"tokens_prompt\",\"tokens_completion\",\"reasoning_tokens\"]",
                    ) != null);
                    try std.testing.expect(std.mem.indexOf(
                        u8,
                        request.payload.?,
                        "\"dimensions\":[\"model\"],\"granularity\":\"hour\"",
                    ) != null);
                    try std.testing.expect(std.mem.indexOf(
                        u8,
                        request.payload.?,
                        "\"start\":\"2026-07-26T13:20:00Z\"",
                    ) != null);
                    try std.testing.expect(std.mem.indexOf(
                        u8,
                        request.payload.?,
                        "\"end\":\"2026-08-25T13:20:00Z\"",
                    ) != null);
                    break :blk
                    \\{"data":{"data":[{"date__hour":"2026-08-25 13:00:00","model":"google/gemini-3.7-flash","total_usage":0.003,"tokens_prompt":"30000","tokens_completion":"900","reasoning_tokens":"100"}],"metadata":{"truncated":false}}}
                    ;
                },
                else => return error.UnexpectedRequest,
            };
            self.calls += 1;
            return .{ .status = 200, .body = try allocator.dupe(u8, body) };
        }
    };

    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    var provider = openrouter.OpenRouter.init();
    defer provider.deinit();
    const period = model.Period{
        .start_unix = 1785535200,
        .end_exclusive_unix = 1788213600,
    };
    try refreshOpenRouter(
        std.testing.allocator,
        &client,
        &provider,
        "inference-secret",
        " management-secret ",
        period,
        1787664000,
    );
    const report = try provider.collect(std.testing.allocator, period);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), backend.calls);
    try std.testing.expectEqual(@as(i64, 3_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 49_750_000), report.summary.credit_remaining_micros);
    try std.testing.expectEqual(@as(usize, 1), report.spend_series.len);
}

test "xAI refresh uses the management billing endpoints and bearer key" {
    const Backend = struct {
        calls: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            try std.testing.expectEqualStrings("management-secret", request.bearer_token.?);
            const body = if (self.calls == 0) blk: {
                try std.testing.expectEqualStrings(
                    "https://management-api.x.ai/v1/billing/teams/team_123/usage",
                    request.url,
                );
                try std.testing.expectEqual(std.http.Method.POST, request.method);
                try std.testing.expectEqualStrings("application/json", request.content_type.?);
                try std.testing.expect(std.mem.indexOf(
                    u8,
                    request.payload.?,
                    "\"groupBy\":[\"description\"]",
                ) != null);
                break :blk
                \\{"timeSeries":[{"groupLabels":["grok-4"],"dataPoints":[{"values":[1.25]}]}],"limitReached":false}
                ;
            } else blk: {
                try std.testing.expectEqualStrings(
                    "https://management-api.x.ai/v1/billing/teams/team_123/prepaid/balance",
                    request.url,
                );
                try std.testing.expectEqual(std.http.Method.GET, request.method);
                break :blk
                \\{"total":{"val":"-500"}}
                ;
            };
            self.calls += 1;
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, body),
            };
        }
    };

    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    var provider = xai_api.XAIAPI.init();
    defer provider.deinit();
    const period = model.Period{ .start_unix = 1, .end_exclusive_unix = 200 };
    try refreshXAI(
        std.testing.allocator,
        &client,
        &provider,
        "management-secret",
        " team_123 ",
        period,
        100,
    );
    const report = try provider.collect(std.testing.allocator, period);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), backend.calls);
    try std.testing.expectEqual(@as(i64, 1_250_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 5_000_000), report.summary.credit_remaining_micros);
}

test "GitHub CLI refresh keeps authentication inside gh" {
    const Runner = struct {
        calls: usize = 0,

        pub fn run(
            self: *@This(),
            allocator: std.mem.Allocator,
            path: []const u8,
        ) ![]u8 {
            self.calls += 1;
            if (std.mem.indexOf(u8, path, "/organizations/alpha/") != null) {
                return allocator.dupe(u8,
                    \\{"usageItems":[{"product":"Actions","sku":"Linux","netAmount":1.25}]}
                );
            }
            try std.testing.expectEqualStrings(
                "/organizations/beta/settings/billing/usage?year=1970&month=1",
                path,
            );
            return allocator.dupe(u8,
                \\{"usageItems":[{"product":"Actions","sku":"Linux","netAmount":2.75}]}
            );
        }
    };

    var runner = Runner{};
    var provider = github.GitHub.init();
    defer provider.deinit();
    const period = model.Period{ .start_unix = 1, .end_exclusive_unix = 200 };
    try refreshGitHubWithRunner(
        std.testing.allocator,
        &runner,
        &provider,
        " alpha, beta ",
        period,
        100,
    );
    const report = try provider.collect(std.testing.allocator, period);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), runner.calls);
    try std.testing.expectEqual(@as(i64, 4_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
}

test "GitHub CLI arguments call the API without exporting a token" {
    const argv = githubCLIArguments("/test/gh", "/organizations/test");
    try std.testing.expectEqualStrings("/test/gh", argv[0]);
    try std.testing.expectEqualStrings("api", argv[1]);
    try std.testing.expectEqualStrings("github.com", argv[3]);
    try std.testing.expectEqualStrings("/organizations/test", argv[10]);
    for (argv) |argument| {
        try std.testing.expect(!std.mem.eql(u8, argument, "token"));
        try std.testing.expect(!std.mem.eql(u8, argument, "auth"));
    }
}

test "GitHub CLI organization discovery normalizes and deduplicates names" {
    const Runner = struct {
        fn listOrganizations(_: *@This(), allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "beta\nalpha\nBETA\n");
        }
    };
    var runner = Runner{};
    const organizations = try discoverGitHubCLIOrganizationsWithRunner(
        std.testing.allocator,
        &runner,
    );
    defer std.testing.allocator.free(organizations);
    try std.testing.expectEqualStrings("beta\nalpha", organizations);

    const argv = githubCLIOrganizationArguments("/test/gh", "/user/orgs?per_page=100");
    try std.testing.expectEqualStrings("--paginate", argv[10]);
    try std.testing.expectEqualStrings(".[].login", argv[12]);
    try std.testing.expectEqualStrings("/user/orgs?per_page=100", argv[13]);
}

test "GitHub organization selection accepts commas and newlines" {
    const organizations = try githubOrganizations(
        std.testing.allocator,
        " alpha, beta\nALPHA ",
    );
    defer std.testing.allocator.free(organizations);
    try std.testing.expectEqual(@as(usize, 2), organizations.len);
    try std.testing.expectEqualStrings("alpha", organizations[0]);
    try std.testing.expectEqualStrings("beta", organizations[1]);
}

test "query values are percent encoded in Zig" {
    const value = try queryParameter(std.testing.allocator, "page", "a+b/c=");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("&page=a%2Bb%2Fc%3D", value);
}

test "Runpod Pod billing is grouped by resource ID" {
    const value = try runpodBillingURL(
        std.testing.allocator,
        "pods",
        "podId",
        "2026-08-01T00:00:00Z",
        "2026-08-24T00:00:00Z",
    );
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(
        "https://rest.runpod.io/v1/billing/pods?startTime=2026-08-01T00:00:00Z&endTime=2026-08-24T00:00:00Z&bucketSize=month&grouping=podId",
        value,
    );
}

test "organization pagination follows and escapes provider cursors in Zig" {
    const Backend = struct {
        calls: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: http.Request,
        ) !http.Response {
            const expected_url = if (self.calls == 0)
                "https://example.test/report?limit=31"
            else
                "https://example.test/report?limit=31&page=next%2Fpage";
            try std.testing.expectEqualStrings(expected_url, request.url);
            try std.testing.expectEqualStrings("admin", request.bearer_token.?);
            const body = if (self.calls == 0)
                "{\"data\":[],\"has_more\":true,\"next_page\":\"next/page\"}"
            else
                "{\"data\":[],\"has_more\":false}";
            self.calls += 1;
            return .{ .status = 200, .body = try allocator.dupe(u8, body) };
        }
    };
    var backend = Backend{};
    var client = http.Client(Backend).init(&backend);
    const pages = try pagedReport(
        std.testing.allocator,
        &client,
        "https://example.test/report",
        "limit=31",
        .{ .bearer_token = "admin" },
    );
    defer std.testing.allocator.free(pages);
    try std.testing.expectEqual(@as(usize, 2), backend.calls);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pages, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}
