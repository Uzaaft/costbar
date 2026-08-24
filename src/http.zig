const std = @import("std");

/// The request surface available to provider modules. Authentication is kept
/// separate from arbitrary headers so transports can treat it as privileged
/// data and strip it when a redirect changes origin.
pub const Request = struct {
    url: []const u8,
    bearer_token: []const u8,
    max_response_bytes: usize = 4 * 1024 * 1024,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }

    pub fn requireSuccess(self: Response) !void {
        if (self.status >= 200 and self.status < 300) return;
        return switch (self.status) {
            401, 403 => error.AuthenticationFailed,
            404 => error.EndpointNotFound,
            429 => error.RateLimited,
            500...599 => error.ProviderServerError,
            else => error.HttpFailure,
        };
    }
};

/// Compile-time HTTP interface. A backend participates by declaring:
///
///     fn get(*Backend, Allocator, Request) !Response
///
/// No vtable or heap allocation is involved; an incompatible backend fails at
/// the call site while compiling the provider that uses it.
pub fn Client(comptime Backend: type) type {
    comptime {
        if (!@hasDecl(Backend, "get")) {
            @compileError(@typeName(Backend) ++ " must declare get");
        }
    }

    return struct {
        backend: *Backend,

        const Self = @This();

        pub fn init(backend: *Backend) Self {
            return .{ .backend = backend };
        }

        pub fn get(
            self: *Self,
            allocator: std.mem.Allocator,
            request: Request,
        ) !Response {
            const response: Response = try self.backend.get(allocator, request);
            return response;
        }
    };
}

/// Adapter for production callers that want provider modules to perform their
/// own HTTPS requests with Zig's standard HTTP client.
pub const StdBackend = struct {
    client: *std.http.Client,

    pub fn get(
        self: *StdBackend,
        allocator: std.mem.Allocator,
        request: Request,
    ) !Response {
        const authorization = try std.fmt.allocPrint(
            allocator,
            "Bearer {s}",
            .{request.bearer_token},
        );
        defer allocator.free(authorization);

        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();

        const result = try self.client.fetch(.{
            .location = .{ .url = request.url },
            .response_writer = &body_writer.writer,
            // Provider URLs are fixed. Treat redirects as responses instead
            // of forwarding a bearer token to a server-selected location.
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = authorization },
            },
        });
        if (body_writer.writer.end > request.max_response_bytes) {
            return error.ResponseTooLarge;
        }

        var body = body_writer.toArrayList();
        errdefer body.deinit(allocator);
        return .{
            .status = @intFromEnum(result.status),
            .body = try body.toOwnedSlice(allocator),
        };
    }
};

test "comptime client dispatches to a compatible backend" {
    const Backend = struct {
        calls: usize = 0,

        pub fn get(
            self: *@This(),
            allocator: std.mem.Allocator,
            request: Request,
        ) !Response {
            self.calls += 1;
            try std.testing.expectEqualStrings("https://example.test/billing", request.url);
            return .{
                .status = 200,
                .body = try allocator.dupe(u8, "{}"),
            };
        }
    };

    var backend = Backend{};
    var client = Client(Backend).init(&backend);
    const response = try client.get(std.testing.allocator, .{
        .url = "https://example.test/billing",
        .bearer_token = "secret",
    });
    defer response.deinit(std.testing.allocator);

    try response.requireSuccess();
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
}

test "HTTP failures are normalized without exposing response data" {
    var response = Response{
        .status = 429,
        .body = try std.testing.allocator.dupe(u8, "rate limited"),
    };
    defer response.deinit(std.testing.allocator);
    try std.testing.expectError(error.RateLimited, response.requireSuccess());
}

test "standard HTTP backend satisfies the comptime client" {
    var io_threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    var standard_client = std.http.Client{
        .allocator = std.testing.allocator,
        .io = io_threaded.io(),
    };
    defer standard_client.deinit();

    var backend = StdBackend{ .client = &standard_client };
    var client = Client(StdBackend).init(&backend);
    const response = client.get(std.testing.allocator, .{
        .url = "://invalid-url",
        .bearer_token = "secret",
    }) catch return;
    defer response.deinit(std.testing.allocator);
    return error.ExpectedInvalidUrl;
}
