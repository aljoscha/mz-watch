const std = @import("std");
const vxfw = @import("vaxis").vxfw;

const Model = struct {
    button: vxfw.Button,

    fn widget(self: *Model) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(ptr: *anyopaque, ctx: *vxfw.EventContext, ev: vxfw.Event) !void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .init => try ctx.requestFocus(self.button.widget()),
            .key_press => |key| if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                ctx.quit = true;
            },
            else => {},
        }
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = 1, .col = 1 },
            .surface = try self.button.draw(ctx.withConstraints(.{ .width = 0, .height = 0 }, .{ .width = @min(ctx.max.size().width, 24), .height = 3 })),
        };
        return .{ .size = ctx.max.size(), .widget = self.widget(), .buffer = &.{}, .children = children };
    }

    fn quit(_: ?*anyopaque, ctx: *vxfw.EventContext) !void {
        ctx.quit = true;
    }
};

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();
    var model: Model = .{ .button = .{ .label = "mz-watch: quit", .onClick = Model.quit } };
    try app.run(model.widget(), .{});
}

test {
    std.testing.refAllDecls(@This());
}
