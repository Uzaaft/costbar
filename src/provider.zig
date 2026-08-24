const std = @import("std");
const model = @import("model.zig");

/// Type-erased interface implemented by every subscription or cloud provider.
/// Concrete providers only need `metadata(self)` and
/// `collect(self, allocator, period)` methods.
pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        metadata: *const fn (*const anyopaque) model.ProviderMetadata,
        collect: *const fn (
            *anyopaque,
            std.mem.Allocator,
            model.Period,
        ) anyerror!model.ProviderReport,
        ingest: *const fn (
            *anyopaque,
            std.mem.Allocator,
            []const u8,
            []const u8,
            i64,
        ) anyerror!void,
    };

    pub fn from(pointer: anytype) Provider {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Provider.from expects a single-item pointer");
        }

        const Concrete = pointer_info.pointer.child;
        const Adapter = struct {
            fn metadataAdapter(context: *const anyopaque) model.ProviderMetadata {
                const self: *const Concrete = @ptrCast(@alignCast(context));
                return self.metadata();
            }

            fn collectAdapter(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                period: model.Period,
            ) anyerror!model.ProviderReport {
                const self: *Concrete = @ptrCast(@alignCast(context));
                return self.collect(allocator, period);
            }

            fn ingestAdapter(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                document_id: []const u8,
                payload: []const u8,
                received_at_unix: i64,
            ) anyerror!void {
                if (!@hasDecl(Concrete, "ingest")) return error.UnsupportedDocument;
                const self: *Concrete = @ptrCast(@alignCast(context));
                return self.ingest(allocator, document_id, payload, received_at_unix);
            }

            const vtable: VTable = .{
                .metadata = metadataAdapter,
                .collect = collectAdapter,
                .ingest = ingestAdapter,
            };
        };

        return .{
            .context = @ptrCast(pointer),
            .vtable = &Adapter.vtable,
        };
    }

    pub fn metadata(self: Provider) model.ProviderMetadata {
        return self.vtable.metadata(self.context);
    }

    pub fn collect(
        self: Provider,
        allocator: std.mem.Allocator,
        period: model.Period,
    ) !model.ProviderReport {
        return self.vtable.collect(self.context, allocator, period);
    }

    pub fn ingest(
        self: Provider,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        return self.vtable.ingest(
            self.context,
            allocator,
            document_id,
            payload,
            received_at_unix,
        );
    }
};

test "an arbitrary concrete type can implement Provider" {
    const Fake = struct {
        pub fn metadata(_: *const @This()) model.ProviderMetadata {
            return .{ .id = "fake", .display_name = "Fake", .kind = .other };
        }

        pub fn collect(
            _: *@This(),
            allocator: std.mem.Allocator,
            _: model.Period,
        ) !model.ProviderReport {
            return .{
                .summary = .{
                    .id = "fake",
                    .display_name = "Fake",
                    .kind = .other,
                    .currency = "USD",
                    .current_cost_micros = 42,
                    .updated_at_unix = 1,
                },
                .resources = try allocator.alloc(model.Resource, 0),
                .line_items = try allocator.alloc(model.CostLineItem, 0),
            };
        }
    };

    var fake = Fake{};
    const interface = Provider.from(&fake);
    try std.testing.expectEqualStrings("fake", interface.metadata().id);

    const report = try interface.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), report.summary.current_cost_micros);
    try std.testing.expectError(
        error.UnsupportedDocument,
        interface.ingest(std.testing.allocator, "anything", "{}", 1),
    );
}
