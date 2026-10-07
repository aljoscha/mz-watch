const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Runner = @import("runner.zig").Runner;
const Dashboard = @import("dashboard.zig").Dashboard;

pub fn main(init: std.process.Init) !void {
    var runner = Runner.init(init.gpa, init.io);
    try runner.start();
    defer runner.deinit();
    var buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();
    const dashboard = try init.gpa.create(Dashboard);
    defer init.gpa.destroy(dashboard);
    dashboard.init(init.gpa, &runner);
    defer dashboard.deinit();
    try app.run(dashboard.widget(), .{ .framerate = 30 });
}

test {
    _ = @import("metrics.zig");
    _ = @import("runner.zig");
    _ = @import("dashboard.zig");
}
