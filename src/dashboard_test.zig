const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Dashboard = @import("dashboard.zig").Dashboard;
const api = @import("runner.zig");

fn configurationLoad(allocator: std.mem.Allocator) !void {
    var runner = api.Runner.init(allocator, std.testing.io);
    defer runner.deinit();
    const model = try allocator.create(Dashboard);
    defer allocator.destroy(model);
    model.init(allocator, &runner);
    defer model.deinit();
    try model.loadConfiguration(.{
        .endpoints = &.{.{ .name = "primary", .conninfo = "service=demo" }},
        .canaries = &.{
            .{ .name = "one", .sql = "SELECT 1", .paused = true },
            .{ .name = "two", .sql = "SELECT 2", .paused = true },
            .{ .name = "three", .sql = "SELECT 3", .paused = true },
            .{ .name = "four", .sql = "SELECT 4", .paused = true },
            .{ .name = "five", .sql = "SELECT 5", .paused = true },
        },
    });
}

test "configuration loading releases partial ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, configurationLoad, .{});
}

fn fixture(allocator: std.mem.Allocator, runner: *api.Runner) !*Dashboard {
    const model = try allocator.create(Dashboard);
    errdefer allocator.destroy(model);
    model.init(allocator, runner);
    errdefer model.deinit();
    try model.loadConfiguration(.{
        .endpoints = &.{.{ .name = "primary", .conninfo = "service=demo" }},
        .canaries = &.{.{ .name = "latency", .sql = "SELECT 1" }},
    });
    return model;
}

fn context(arena: std.mem.Allocator, size: vxfw.Size) vxfw.DrawContext {
    return .{ .arena = arena, .min = .{ .width = 0, .height = 0 }, .max = .fromSize(size), .cell_size = .{ .width = 1, .height = 1 } };
}

fn paint(surface: vxfw.Surface, cells: []@import("vaxis").Cell, size: vxfw.Size, col: i32, row: i32) void {
    for (surface.buffer, 0..) |cell, i| {
        const x = col + @as(i32, @intCast(i % surface.size.width));
        const y = row + @as(i32, @intCast(i / surface.size.width));
        if (x >= 0 and x < size.width and y >= 0 and y < size.height) cells[@as(usize, @intCast(y)) * size.width + @as(usize, @intCast(x))] = cell;
    }
    for (surface.children) |sub| paint(sub.surface, cells, size, col + sub.origin.col, row + sub.origin.row);
}

fn frameText(allocator: std.mem.Allocator, surface: vxfw.Surface) ![]const u8 {
    const cells = try allocator.alloc(@import("vaxis").Cell, @as(usize, surface.size.width) * surface.size.height);
    defer allocator.free(cells);
    @memset(cells, .{});
    paint(surface, cells, surface.size, 0, 0);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (cells, 0..) |cell, i| {
        try result.appendSlice(allocator, cell.char.grapheme);
        if ((i + 1) % surface.size.width == 0) try result.append(allocator, '\n');
    }
    return result.toOwnedSlice(allocator);
}

test "completed diagnostics survive transient activity and do not retain stale latency" {
    const a = std.testing.allocator;
    var runner = api.Runner.init(a, std.testing.io);
    defer runner.deinit();
    const model = try fixture(a, &runner);
    defer a.destroy(model);
    defer model.deinit();
    model.page = .endpoints;
    try runner.events.appendSlice(a, &.{
        .{ .endpoint = .{ .canary = 2, .endpoint = 1, .status = .success, .latency_ms = 10 } },
        .{ .endpoint = .{ .canary = 2, .endpoint = 1, .status = .query_error, .sqlstate = "22012".* } },
        .{ .endpoint = .{ .canary = 2, .endpoint = 1, .status = .running } },
        .{ .endpoint = .{ .canary = 2, .endpoint = 1, .status = .busy } },
    });
    var event_ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = a, .cmds = .empty };
    defer event_ctx.cmds.deinit(a);
    try model.widget().handleEvent(&event_ctx, .tick);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = try model.widget().draw(context(arena.allocator(), .{ .width = 120, .height = 32 }));
    const rendered = try frameText(a, frame);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Current: busy") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Last result: query_error  SQLSTATE 22012") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Last result latency: -") != null);
}

test "endpoint comparison shows each destination for the shared canary" {
    const a = std.testing.allocator;
    var runner = api.Runner.init(a, std.testing.io);
    defer runner.deinit();
    const model = try a.create(Dashboard);
    defer a.destroy(model);
    model.init(a, &runner);
    defer model.deinit();
    try model.loadConfiguration(.{
        .endpoints = &.{
            .{ .name = "alpha", .conninfo = "service=alpha" },
            .{ .name = "beta", .conninfo = "service=beta" },
        },
        .canaries = &.{
            .{ .name = "read", .sql = "SELECT 1" },
            .{ .name = "divide", .sql = "SELECT 1/0" },
        },
    });
    try runner.events.appendSlice(a, &.{
        .{ .endpoint = .{ .canary = 3, .endpoint = 1, .status = .success, .latency_ms = 10 } },
        .{ .endpoint = .{ .canary = 3, .endpoint = 2, .status = .timeout } },
        .{ .endpoint = .{ .canary = 4, .endpoint = 1, .status = .query_error, .sqlstate = "22012".* } },
        .{ .endpoint = .{ .canary = 4, .endpoint = 2, .status = .success, .latency_ms = 77 } },
    });
    var event_ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = a, .cmds = .empty };
    defer event_ctx.cmds.deinit(a);
    try model.widget().handleEvent(&event_ctx, .tick);
    model.page = .endpoints;
    for (0..2) |canary_index| {
        model.canary_index = canary_index;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = try model.widget().draw(context(arena.allocator(), .{ .width = 80, .height = 24 }));
        const rendered = try frameText(a, frame);
        defer a.free(rendered);
        const header = try std.fmt.allocPrint(arena.allocator(), "Canary {d}/2:", .{canary_index + 1});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, header));
        try std.testing.expect(std.mem.indexOf(u8, rendered, model.canaries.items[canary_index].sql) != null);
        const alpha = std.mem.indexOf(u8, rendered, "Endpoint: alpha").?;
        const beta = std.mem.indexOf(u8, rendered, "Endpoint: beta").?;
        const alpha_card = rendered[alpha..beta];
        const beta_card = rendered[beta..];
        if (canary_index == 0) {
            try std.testing.expect(std.mem.indexOf(u8, alpha_card, "Current: success") != null);
            try std.testing.expect(std.mem.indexOf(u8, alpha_card, "Last result latency: 10.00ms") != null);
            try std.testing.expect(std.mem.indexOf(u8, beta_card, "Current: timeout") != null);
            try std.testing.expect(std.mem.indexOf(u8, beta_card, "Last result latency: -") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, alpha_card, "Last result: query_error  SQLSTATE 22012") != null);
            try std.testing.expect(std.mem.indexOf(u8, beta_card, "Current: success") != null);
            try std.testing.expect(std.mem.indexOf(u8, beta_card, "Last result latency: 77.00ms") != null);
        }
    }
}

test "responsive frames preserve footer and fit both charts at 80x24" {
    const a = std.testing.allocator;
    var runner = api.Runner.init(a, std.testing.io);
    defer runner.deinit();
    const model = try fixture(a, &runner);
    defer a.destroy(model);
    defer model.deinit();
    model.canaries.items[0].stats.record(@divFloor(api.nowNs(std.testing.io), std.time.ns_per_ms), 20);
    const sizes = [_]vxfw.Size{
        .{ .width = 0, .height = 0 },     .{ .width = 1, .height = 1 },    .{ .width = 20, .height = 8 },
        .{ .width = 35, .height = 15 },   .{ .width = 74, .height = 24 },  .{ .width = 80, .height = 24 },
        .{ .width = 80, .height = 40 },   .{ .width = 112, .height = 32 }, .{ .width = 120, .height = 32 },
        .{ .width = 250, .height = 120 },
    };
    for (sizes) |size| {
        for ([_]@TypeOf(model.page){ .canaries, .endpoints }) |page| {
            model.page = page;
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const frame = try model.widget().draw(context(arena.allocator(), size));
            try std.testing.expectEqual(size, frame.size);
            for (frame.children) |sub| {
                try std.testing.expect(sub.origin.col >= 0 and sub.origin.row >= 0);
                try std.testing.expect(@as(usize, @intCast(sub.origin.col)) + sub.surface.size.width <= size.width);
                try std.testing.expect(@as(usize, @intCast(sub.origin.row)) + sub.surface.size.height <= size.height);
            }
            const rendered = try frameText(a, frame);
            defer a.free(rendered);
            if (size.width >= 35 and size.height >= 15) {
                var lines = std.mem.splitScalar(u8, rendered, '\n');
                var footer: []const u8 = "";
                for (0..size.height) |_| footer = lines.next().?;
                try std.testing.expect(std.mem.indexOf(u8, footer, "1/2 panels") != null);
            }
            if (size.width == 80 and page == .canaries) {
                try std.testing.expect(std.mem.indexOf(u8, rendered, "HISTOGRAM") != null);
                try std.testing.expect(std.mem.indexOf(u8, rendered, "MEAN / SECOND") != null);
                try std.testing.expect(std.mem.indexOf(u8, rendered, ".1s") != null);
                try std.testing.expect(std.mem.indexOf(u8, rendered, ".5s") != null);
            }
        }
    }
}
