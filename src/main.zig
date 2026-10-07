const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Runner = @import("runner.zig").Runner;
const Dashboard = @import("dashboard.zig").Dashboard;
const config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const config_path = try config.defaultPath(init.gpa, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME"));
    defer init.gpa.free(config_path);
    var runner = Runner.init(init.gpa, init.io);
    defer runner.deinit();
    const dashboard = try init.gpa.create(Dashboard);
    defer init.gpa.destroy(dashboard);
    dashboard.init(init.gpa, &runner);
    defer dashboard.deinit();
    dashboard.config_path = config_path;
    {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const saved = config.load(init.gpa, arena.allocator(), init.io, config_path) catch |err| {
            std.debug.print("Cannot load configuration {s}: {t}\n", .{ config_path, err });
            return err;
        };
        try dashboard.loadConfiguration(saved);
    }
    try runner.start();
    var buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();
    try app.run(dashboard.widget(), .{ .framerate = 30 });
}

test {
    _ = @import("metrics.zig");
    _ = @import("runner.zig");
    _ = @import("dashboard.zig");
}
