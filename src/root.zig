pub const model = @import("model.zig");
pub const money = @import("money.zig");
pub const http = @import("http.zig");
pub const provider = @import("provider.zig");
pub const registry = @import("registry.zig");
pub const local_usage = @import("local_usage.zig");
pub const dashboard_cache = @import("dashboard_cache.zig");
pub const live_refresh = @import("live_refresh.zig");
pub const claude_status = @import("claude_status.zig");
pub const providers = struct {
    pub const digitalocean = @import("providers/digitalocean.zig");
    pub const ovh = @import("providers/ovh.zig");
    pub const hetzner = @import("providers/hetzner.zig");
    pub const cloudflare = @import("providers/cloudflare.zig");
    pub const runpod = @import("providers/runpod.zig");
    pub const vercel = @import("providers/vercel.zig");
    pub const openrouter = @import("providers/openrouter.zig");
    pub const codex = @import("providers/codex.zig");
    pub const claude = @import("providers/claude.zig");
    pub const openai_api = @import("providers/openai_api.zig");
    pub const anthropic_api = @import("providers/anthropic_api.zig");
    pub const xai_api = @import("providers/xai_api.zig");
    pub const github = @import("providers/github.zig");
    pub const cursor = @import("providers/cursor.zig");
    pub const opencode = @import("providers/opencode.zig");
};
pub const c_api = @import("c_api.zig");

comptime {
    _ = c_api;
}

test {
    _ = model;
    _ = money;
    _ = http;
    _ = provider;
    _ = registry;
    _ = local_usage;
    _ = dashboard_cache;
    _ = live_refresh;
    _ = claude_status;
    _ = providers.digitalocean;
    _ = providers.ovh;
    _ = providers.hetzner;
    _ = providers.cloudflare;
    _ = providers.runpod;
    _ = providers.vercel;
    _ = providers.openrouter;
    _ = providers.codex;
    _ = providers.claude;
    _ = providers.openai_api;
    _ = providers.anthropic_api;
    _ = providers.xai_api;
    _ = providers.github;
    _ = providers.cursor;
    _ = providers.opencode;
    _ = c_api;
}
