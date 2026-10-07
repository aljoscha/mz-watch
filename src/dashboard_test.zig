const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Dashboard = @import("dashboard.zig").Dashboard;
const api = @import("runner.zig");

fn fixture(allocator: std.mem.Allocator, runner: *api.Runner) !*Dashboard {
    const model = try allocator.create(Dashboard);
    errdefer allocator.destroy(model);
    model.init(allocator, runner);
    errdefer model.deinit();
    try model.endpoints.ensureUnusedCapacity(allocator, 1);
    model.endpoints.appendAssumeCapacity(.{ .id = 1, .name = try allocator.dupe(u8, "primary") });
    try model.canaries.ensureUnusedCapacity(allocator, 1);
    const name = try allocator.dupe(u8, "latency");
    errdefer allocator.free(name);
    const sql = try allocator.dupe(u8, "SELECT 1");
    model.canaries.appendAssumeCapacity(.{ .id = 2, .name = name, .sql = sql, .interval_ms = 1000, .timeout_ms = 5000 });
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

test "responsive frames preserve footer and fit both charts at 80x24" {
    const a = std.testing.allocator;
    var runner = api.Runner.init(a, std.testing.io);
    defer runner.deinit();
    const model = try fixture(a, &runner);
    defer a.destroy(model);
    defer model.deinit();
    model.canaries.items[0].stats.record(@divFloor(api.nowNs(std.testing.io), std.time.ns_per_ms), 20);
    const sizes = [_]vxfw.Size{
        .{ .width = 0, .height = 0 },    .{ .width = 1, .height = 1 },     .{ .width = 20, .height = 8 },
        .{ .width = 35, .height = 15 },  .{ .width = 74, .height = 24 },   .{ .width = 80, .height = 24 },
        .{ .width = 120, .height = 32 }, .{ .width = 250, .height = 120 },
    };
    for (sizes) |size| {
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
        if (size.width == 80) {
            try std.testing.expect(std.mem.indexOf(u8, rendered, "HISTOGRAM") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "MEAN / SECOND") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, ".1s") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, ".5s") != null);
        }
    }
}
