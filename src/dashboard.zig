const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const runner_mod = @import("runner.zig");
const metrics = @import("metrics.zig");
const config = @import("config.zig");

const Palette = @import("theme.zig").Palette;

const Endpoint = struct { id: u64, name: []const u8, conninfo: []const u8, label: []const u8 };
const Observation = struct {
    status: runner_mod.Status = .connecting,
    last_status: ?runner_mod.Status = null,
    latency: ?f64 = null,
    successes: u64 = 0,
    errors: u64 = 0,
    skipped: u64 = 0,
    wins: u64 = 0,
    sqlstate: [5]u8 = @splat(' '),
};
const Canary = struct {
    id: u64,
    name: []const u8,
    sql: []const u8,
    interval_ms: u32,
    timeout_ms: u32,
    paused: bool = false,
    stats: metrics.Stats = .{},
    winner: ?u64 = null,
    observations: std.AutoHashMapUnmanaged(u64, Observation) = .empty,
};
const Page = enum { canaries, endpoints };
const Form = enum { none, endpoint, canary, remove_endpoint, remove_canary };
const Action = enum { add_endpoint, add_canary, remove, pause, show_canaries, show_endpoints, quit, save, cancel, prev_canary, next_canary };
const toolbar_actions = [_]Action{ .add_endpoint, .add_canary, .remove, .pause, .show_canaries, .show_endpoints, .quit, .prev_canary, .next_canary };
const ListArea = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
    row_height: usize = 1,

    fn contains(self: ListArea, mouse: vaxis.Mouse) bool {
        if (mouse.col < 0 or mouse.row < 0) return false;
        const x: usize = @intCast(mouse.col);
        const y: usize = @intCast(mouse.row);
        return x >= self.x and x < self.x + self.width and y >= self.y and y < self.y + self.height;
    }
};
const Viewport = struct {
    start: usize = 0,
    ensure_selection: bool = true,
};
const Control = struct {
    owner: *Dashboard,
    action: Action,
    button: vxfw.Button,

    fn click(ptr: ?*anyopaque, ctx: *vxfw.EventContext) !void {
        const self: *Control = @ptrCast(@alignCast(ptr.?));
        // Hit-testing may still use the pre-modal frame within an input batch.
        // Modal isolation must also hold at the action boundary.
        if (self.owner.form != .none and self.action != .save and self.action != .cancel) return ctx.consumeEvent();
        self.owner.toolbar_focus = self.action;
        try self.owner.act(self.action, ctx);
    }
};
const Row = struct {
    owner: *Dashboard,
    page: Page = .canaries,
    id: u64 = 0,
    button: vxfw.Button,
    summary: []const u8 = "",

    fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(ptr: *anyopaque, ctx: *vxfw.EventContext, ev: vxfw.Event) !void {
        const self: *Row = @ptrCast(@alignCast(ptr));
        try self.button.handleEvent(ctx, ev);
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const button = &self.button;
        const style = if (button.mouse_down) button.style.mouse_down else if (button.has_mouse) button.style.hover else if (button.focused) button.style.focus else button.style.default;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        @memset(surface.buffer, .{ .style = style });
        const width: usize = surface.size.width;
        const height: usize = surface.size.height;
        if (width == 0 or height == 0) return surface;
        const compact = height == 1;
        const label_width = if (compact and self.summary.len > 0) width / 2 else width;
        text(surface, ctx, 0, 0, label_width, button.label, style);
        var muted = self.owner.colors.muted;
        muted.bg = style.bg;
        const summary_x = if (compact) label_width + 1 else 2;
        text(surface, ctx, summary_x, if (compact) 0 else 1, width -| summary_x, self.summary, muted);
        if (!compact) {
            var separator = self.owner.colors.border;
            separator.bg = style.bg;
            for (0..width) |col| text(surface, ctx, col, height - 1, 1, "─", separator);
        } else {
            for (surface.buffer) |*cell| cell.style.ul_style = .single;
        }
        return surface;
    }

    fn click(ptr: ?*anyopaque, ctx: *vxfw.EventContext) !void {
        const self: *Row = @ptrCast(@alignCast(ptr.?));
        if (self.owner.form != .none) return ctx.consumeEvent();
        self.owner.page = self.page;
        self.owner.toolbar_focus = null;
        const index = if (self.page == .canaries) self.owner.canaryIndex(self.id) else self.owner.endpointIndex(self.id);
        if (index) |i| {
            if (self.page == .canaries) self.owner.canary_index = i else self.owner.endpoint_index = i;
            self.owner.viewports[@backingInt(self.page)].ensure_selection = true;
        }
        try ctx.requestFocus(self.owner.widget());
        ctx.consumeAndRedraw();
    }
};

pub const Dashboard = struct {
    allocator: std.mem.Allocator,
    runner: *runner_mod.Runner,
    colors: Palette = .light,
    endpoints: std.ArrayList(Endpoint) = .empty,
    canaries: std.ArrayList(Canary) = .empty,
    // Row widgets are reused by visible position. Their lifetime is independent
    // of config deletion, including focus and mouse events from the last frame.
    rows: std.ArrayList(*Row) = .empty,
    controls: [11]Control = undefined,
    fields: [4]vxfw.TextField = undefined,
    form: Form = .none,
    page: Page = .canaries,
    form_focus: usize = 0,
    toolbar_focus: ?Action = null,
    canary_index: usize = 0,
    endpoint_index: usize = 0,
    next_id: u64 = 1,
    message: []const u8 = "",
    config_path: ?[]const u8 = null,
    save_error: ?anyerror = null,
    viewports: [2]Viewport = .{ .{}, .{} },
    list_area: ListArea = .{},
    scrollbar_drag: ?usize = null,
    modal_area: ListArea = .{},

    /// Initialize only after placement at a stable address.
    pub fn init(self: *Dashboard, allocator: std.mem.Allocator, runner: *runner_mod.Runner) void {
        self.* = .{ .allocator = allocator, .runner = runner };
        const labels = [_][]const u8{ "+ Endpoint", "+ Canary", "Remove", "Pause/resume", "Canaries", "Endpoints", "Quit", "Save", "Cancel", "< Canary", "Canary >" };
        inline for (std.meta.tags(Action), 0..) |action, i| {
            self.controls[i] = .{ .owner = self, .action = action, .button = .{ .label = labels[i], .onClick = Control.click } };
            self.controls[i].button.userdata = &self.controls[i];
            self.controls[i].button.style.default = self.colors.selected;
            self.controls[i].button.style.hover = self.colors.hover;
            self.controls[i].button.style.focus = self.controls[i].button.style.hover;
        }
        for (&self.fields) |*field| {
            field.* = vxfw.TextField.init(allocator);
            field.style = self.colors.selected;
            field.userdata = self;
        }
    }

    pub fn deinit(self: *Dashboard) void {
        for (&self.fields) |*field| field.deinit();
        for (self.endpoints.items) |endpoint| {
            self.allocator.free(endpoint.name);
            self.allocator.free(endpoint.conninfo);
            self.allocator.free(endpoint.label);
        }
        for (self.canaries.items) |*canary| self.freeCanary(canary);
        for (self.rows.items) |item| self.allocator.destroy(item);
        self.rows.deinit(self.allocator);
        self.endpoints.deinit(self.allocator);
        self.canaries.deinit(self.allocator);
    }

    fn freeCanary(self: *Dashboard, canary: *Canary) void {
        self.allocator.free(canary.name);
        self.allocator.free(canary.sql);
        canary.observations.deinit(self.allocator);
    }

    /// Load validated configuration once, before starting the runner.
    /// Strings are copied. On failure, deinit still releases partial state.
    pub fn loadConfiguration(self: *Dashboard, saved: config.Config) !void {
        for (saved.endpoints) |endpoint| try self.addEndpoint(endpoint.name, endpoint.conninfo);
        for (saved.canaries) |canary| try self.addCanary(canary);
        self.endpoint_index = 0;
        self.canary_index = 0;
    }

    fn addEndpoint(self: *Dashboard, name: []const u8, conninfo: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_conninfo = try self.allocator.dupe(u8, conninfo);
        errdefer self.allocator.free(owned_conninfo);
        const label = try @import("connection_label.zig").format(self.allocator, conninfo);
        errdefer self.allocator.free(label);
        try self.endpoints.ensureUnusedCapacity(self.allocator, 1);
        try self.runner.addEndpoint(self.next_id, conninfo);
        self.endpoints.appendAssumeCapacity(.{ .id = self.next_id, .name = owned_name, .conninfo = owned_conninfo, .label = label });
        self.endpoint_index = self.endpoints.items.len - 1;
        self.viewports[@backingInt(Page.endpoints)].ensure_selection = true;
        self.next_id += 1;
    }

    fn addCanary(self: *Dashboard, saved: config.Canary) !void {
        {
            const owned_name = try self.allocator.dupe(u8, saved.name);
            errdefer self.allocator.free(owned_name);
            const owned_sql = try self.allocator.dupe(u8, saved.sql);
            errdefer self.allocator.free(owned_sql);
            try self.canaries.ensureUnusedCapacity(self.allocator, 1);
            try self.runner.addCanary(self.next_id, saved.sql, saved.interval_ms, saved.timeout_ms);
            self.canaries.appendAssumeCapacity(.{ .id = self.next_id, .name = owned_name, .sql = owned_sql, .interval_ms = saved.interval_ms, .timeout_ms = saved.timeout_ms });
        }
        // Establish ownership before a fallible command. Startup can then clean
        // up a partially loaded configuration without leaking its strings.
        self.next_id += 1;
        self.canary_index = self.canaries.items.len - 1;
        self.viewports[@backingInt(Page.canaries)].ensure_selection = true;
        if (saved.paused) {
            try self.runner.pause(self.canaries.items[self.canary_index].id, true);
            self.canaries.items[self.canary_index].paused = true;
        }
    }

    fn persist(self: *Dashboard) void {
        self.writeConfiguration() catch |err| {
            self.save_error = err;
            return;
        };
        self.save_error = null;
    }

    fn writeConfiguration(self: *Dashboard) !void {
        const path = self.config_path orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const endpoints = try a.alloc(config.Endpoint, self.endpoints.items.len);
        for (endpoints, self.endpoints.items) |*saved, endpoint| saved.* = .{ .name = endpoint.name, .conninfo = endpoint.conninfo };
        const canaries = try a.alloc(config.Canary, self.canaries.items.len);
        for (canaries, self.canaries.items) |*saved, canary| saved.* = .{ .name = canary.name, .sql = canary.sql, .interval_ms = canary.interval_ms, .timeout_ms = canary.timeout_ms, .paused = canary.paused };
        try config.save(a, self.runner.io, path, .{ .endpoints = endpoints, .canaries = canaries });
    }

    pub fn widget(self: *Dashboard) vxfw.Widget {
        return .{ .userdata = self, .captureHandler = capture, .eventHandler = event, .drawFn = draw };
    }

    fn canaryIndex(self: *Dashboard, id: u64) ?usize {
        for (self.canaries.items, 0..) |canary, i| if (canary.id == id) return i;
        return null;
    }

    fn endpointIndex(self: *Dashboard, id: u64) ?usize {
        for (self.endpoints.items, 0..) |endpoint, i| if (endpoint.id == id) return i;
        return null;
    }

    fn selectedCanary(self: *Dashboard) ?*Canary {
        if (self.canaries.items.len == 0) return null;
        self.canary_index = @min(self.canary_index, self.canaries.items.len - 1);
        return &self.canaries.items[self.canary_index];
    }

    fn drain(self: *Dashboard) !void {
        var events = self.runner.takeEvents();
        defer events.deinit(self.allocator);
        for (events.items) |ev| switch (ev) {
            .sample => |sample| {
                const i = self.canaryIndex(sample.canary) orelse continue;
                const canary = &self.canaries.items[i];
                canary.stats.record(sample.at_ms, sample.latency_ms);
                canary.winner = if (sample.winner) |id| if (self.endpointIndex(id) != null) id else null else null;
                if (canary.winner) |id| {
                    const record = try canary.observations.getOrPut(self.allocator, id);
                    if (!record.found_existing) record.value_ptr.* = .{};
                    record.value_ptr.wins += 1;
                }
            },
            .endpoint => |outcome| {
                const i = self.canaryIndex(outcome.canary) orelse continue;
                if (self.endpointIndex(outcome.endpoint) == null) continue;
                const record = try self.canaries.items[i].observations.getOrPut(self.allocator, outcome.endpoint);
                if (!record.found_existing) record.value_ptr.* = .{};
                const value = record.value_ptr;
                value.status = outcome.status;
                switch (outcome.status) {
                    .success, .query_error, .timeout, .connection_error => {
                        value.last_status = outcome.status;
                        value.sqlstate = outcome.sqlstate;
                        value.latency = outcome.latency_ms;
                    },
                    else => {},
                }
                switch (outcome.status) {
                    .success => value.successes += 1,
                    .query_error, .timeout, .connection_error => value.errors += 1,
                    .busy, .unavailable => value.skipped += 1,
                    else => {},
                }
            },
        };
        if (self.runner.failed.load(.acquire)) self.message = "Database runner stopped. Quit and restart. No measurements are being collected.";
    }

    fn capture(ptr: *anyopaque, ctx: *vxfw.EventContext, ev: vxfw.Event) !void {
        const self: *Dashboard = @ptrCast(@alignCast(ptr));
        // Hover notifications request redraw but must not consume the following
        // pointer event. The framework dispatches both using the same context.
        if (ev == .mouse) ctx.consume_event = false;
        if (ev == .mouse and self.form != .none and !self.modal_area.contains(ev.mouse)) return ctx.consumeEvent();
        if (ev == .mouse and self.form == .none) {
            if (try self.scrollMouse(ctx, ev.mouse)) return;
        }
        if (ev == .mouse and ev.mouse.type == .press and ev.mouse.button == .left and (self.form == .endpoint or self.form == .canary)) {
            const count: usize = if (self.form == .endpoint) 2 else 4;
            const row_y = @as(i32, ev.mouse.row) - @as(i32, @intCast(self.modal_area.y));
            for (0..count) |i| {
                if (row_y == 4 + i * 2) {
                    self.form_focus = i;
                    try ctx.requestFocus(self.fields[i].widget());
                    return ctx.consumeAndRedraw();
                }
            }
        }
        if (ev != .key_press) return;
        self.scrollbar_drag = null;
        const key = ev.key_press;
        if (key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            return ctx.consumeEvent();
        }
        if (self.form != .none) {
            if (key.matches(vaxis.Key.escape, .{})) return self.act(.cancel, ctx);
            if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
                const count: usize = if (self.form == .endpoint) 2 else if (self.form == .canary) 4 else 0;
                const n = count + 2;
                self.form_focus = (self.form_focus + if (key.mods.shift) n - 1 else @as(usize, 1)) % n;
                try ctx.requestFocus(if (self.form_focus < count) self.fields[self.form_focus].widget() else self.controls[7 + self.form_focus - count].button.widget());
                return ctx.consumeAndRedraw();
            }
            const count: usize = if (self.form == .endpoint) 2 else if (self.form == .canary) 4 else 0;
            // Focus commands are applied after an input batch. Route form keys
            // using the immediate logical focus so Tab followed by pasted text
            // cannot put that text into the previous field.
            if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) return self.act(if (self.form_focus <= count) .save else .cancel, ctx);
            if (self.form_focus < count) {
                try self.fields[self.form_focus].handleEvent(ctx, ev);
                return ctx.consumeEvent();
            }
        } else if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
            const count: usize = if (self.page == .endpoints and self.canaries.items.len > 0 and self.endpoints.items.len > 0) toolbar_actions.len else 7;
            const index = for (toolbar_actions[0..count], 0..) |action, i| {
                if (self.toolbar_focus == action) break i;
            } else if (key.mods.shift) @as(usize, 0) else count - 1;
            const next = (index + if (key.mods.shift) count - 1 else @as(usize, 1)) % count;
            const action = toolbar_actions[next];
            self.toolbar_focus = action;
            try ctx.requestFocus(self.controls[@backingInt(action)].button.widget());
            return ctx.consumeAndRedraw();
        } else {
            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.toolbar_focus) |action| return self.act(action, ctx);
            }
            // Global shortcuts remain usable while a closed form's queued
            // focus change is waiting for the next layout.
            self.toolbar_focus = null;
            try event(ptr, ctx, ev);
        }
    }

    fn event(ptr: *anyopaque, ctx: *vxfw.EventContext, ev: vxfw.Event) !void {
        const self: *Dashboard = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .mouse => if (ctx.phase == .at_target) {
                // The root's scrollbar and blank list cells have no child hit.
                // Mouse capture excludes the target, unlike keyboard capture.
                ctx.consume_event = false;
                if (self.form == .none) _ = try self.scrollMouse(ctx, ev.mouse);
            },
            .init => {
                ctx.redraw = true;
                try ctx.tick(50, self.widget());
            },
            .color_scheme => |scheme| {
                self.colors = if (scheme == .light) .light else .dark;
                for (&self.controls) |*control| {
                    control.button.style.default = self.colors.selected;
                    control.button.style.hover = self.colors.hover;
                    control.button.style.focus = self.colors.hover;
                }
                for (&self.fields) |*field| field.style = self.colors.selected;
                ctx.redraw = true;
            },
            .tick => {
                try self.drain();
                ctx.redraw = true;
                try ctx.tick(50, self.widget());
            },
            .paste => |pasted| {
                defer self.allocator.free(pasted);
                if ((self.form == .endpoint or self.form == .canary) and self.form_focus < (if (self.form == .endpoint) @as(usize, 2) else 4)) {
                    try self.fields[self.form_focus].insertSliceAtCursor(pasted);
                    ctx.consumeAndRedraw();
                }
            },
            .key_press => |key| {
                if (self.form != .none) return;
                if (key.matches('q', .{})) return self.act(.quit, ctx);
                if (key.matches('e', .{})) return self.act(.add_endpoint, ctx);
                if (key.matches('a', .{})) return self.act(.add_canary, ctx);
                if (key.matches('p', .{})) return self.act(.pause, ctx);
                if (key.matches('x', .{})) return self.act(.remove, ctx);
                if (key.matches('1', .{})) return self.act(.show_canaries, ctx);
                if (key.matches('2', .{})) return self.act(.show_endpoints, ctx);
                if (self.page == .endpoints and (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{}))) return self.act(.prev_canary, ctx);
                if (self.page == .endpoints and (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{}))) return self.act(.next_canary, ctx);
                const down = key.matches(vaxis.Key.down, .{}) or key.matches('j', .{});
                const up = key.matches(vaxis.Key.up, .{}) or key.matches('k', .{});
                if (up or down) {
                    const len = if (self.page == .canaries) self.canaries.items.len else self.endpoints.items.len;
                    const index = if (self.page == .canaries) &self.canary_index else &self.endpoint_index;
                    if (len > 0) index.* = if (down) @min(index.* + 1, len - 1) else index.* -| 1;
                    self.viewports[@backingInt(self.page)].ensure_selection = true;
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn resetFields(self: *Dashboard) void {
        for (&self.fields) |*field| {
            field.deinit();
            field.* = vxfw.TextField.init(self.allocator);
            field.style = self.colors.selected;
            field.userdata = self;
        }
    }

    fn act(self: *Dashboard, action: Action, ctx: *vxfw.EventContext) !void {
        switch (action) {
            .quit => ctx.quit = true,
            .add_endpoint, .add_canary => {
                self.resetFields();
                self.form = if (action == .add_endpoint) .endpoint else .canary;
                self.form_focus = 0;
                self.message = "";
                if (self.form == .canary) {
                    try self.fields[1].insertSliceAtCursor("SELECT 1");
                    try self.fields[2].insertSliceAtCursor("1000");
                    try self.fields[3].insertSliceAtCursor("5000");
                }
                try ctx.requestFocus(self.fields[0].widget());
            },
            .cancel => {
                self.toolbar_focus = null;
                self.form = .none;
                self.resetFields();
                self.message = "";
                try ctx.requestFocus(self.widget());
            },
            .save => try self.save(ctx),
            .show_canaries, .show_endpoints => {
                self.page = if (action == .show_canaries) .canaries else .endpoints;
                try ctx.requestFocus(self.widget());
            },
            .prev_canary, .next_canary => {
                if (self.canaries.items.len > 0) self.canary_index = if (action == .next_canary) @min(self.canary_index + 1, self.canaries.items.len - 1) else self.canary_index -| 1;
                self.viewports[@backingInt(Page.canaries)].ensure_selection = true;
            },
            .pause => if (self.selectedCanary()) |canary| {
                try self.runner.pause(canary.id, !canary.paused);
                canary.paused = !canary.paused;
                self.message = if (canary.paused) "Canary paused" else "Canary resumed";
                self.persist();
            },
            .remove => {
                if (self.page == .canaries and self.selectedCanary() != null) self.form = .remove_canary;
                if (self.page == .endpoints and self.endpoints.items.len > 0) self.form = .remove_endpoint;
                if (self.form != .none) {
                    self.form_focus = 0;
                    try ctx.requestFocus(self.controls[7].button.widget());
                }
            },
        }
        ctx.consumeAndRedraw();
    }

    fn save(self: *Dashboard, ctx: *vxfw.EventContext) !void {
        if (self.form == .remove_canary) {
            if (self.selectedCanary()) |canary| {
                try self.runner.removeCanary(canary.id);
                self.freeCanary(canary);
                _ = self.canaries.orderedRemove(self.canary_index);
            }
        } else if (self.form == .remove_endpoint) {
            if (self.endpoints.items.len > 0) {
                self.endpoint_index = @min(self.endpoint_index, self.endpoints.items.len - 1);
                const endpoint = self.endpoints.items[self.endpoint_index];
                try self.runner.removeEndpoint(endpoint.id);
                self.allocator.free(endpoint.name);
                self.allocator.free(endpoint.conninfo);
                self.allocator.free(endpoint.label);
                _ = self.endpoints.orderedRemove(self.endpoint_index);
                for (self.canaries.items) |*canary| {
                    _ = canary.observations.remove(endpoint.id);
                    if (canary.winner == endpoint.id) canary.winner = null;
                }
            }
        } else if (self.form == .endpoint or self.form == .canary) {
            var values: [4][]const u8 = @splat("");
            defer for (values) |value| self.allocator.free(value);
            const count: usize = if (self.form == .endpoint) 2 else 4;
            for (values[0..count], 0..) |*value, i| value.* = try self.fields[i].buf.dupe();
            const name = std.mem.trim(u8, values[0], " \t\r\n");
            const query = std.mem.trim(u8, values[1], " \t\r\n");
            const candidate: config.Config = if (self.form == .endpoint)
                .{ .endpoints = &.{.{ .name = name, .conninfo = query }} }
            else
                .{ .canaries = &.{.{ .name = name, .sql = query }} };
            config.validate(candidate) catch {
                self.message = "Use a nonempty name without control characters, and a nonempty UTF-8 connection/query without NUL bytes.";
                return ctx.consumeAndRedraw();
            };
            if (self.form == .endpoint) {
                try self.addEndpoint(name, query);
            } else {
                const interval = std.fmt.parseInt(u32, std.mem.trim(u8, values[2], " \t"), 10) catch 0;
                const timeout = std.fmt.parseInt(u32, std.mem.trim(u8, values[3], " \t"), 10) catch 0;
                if (interval == 0 or timeout == 0) {
                    self.message = "Interval and timeout must be positive milliseconds.";
                    return ctx.consumeAndRedraw();
                }
                try self.addCanary(.{ .name = name, .sql = query, .interval_ms = interval, .timeout_ms = timeout });
                self.page = .canaries;
            }
        }
        self.viewports[@backingInt(self.page)].ensure_selection = true;
        self.persist();
        self.form = .none;
        self.toolbar_focus = null;
        self.resetFields();
        self.message = "";
        try ctx.requestFocus(self.widget());
        ctx.consumeAndRedraw();
    }

    fn row(self: *Dashboard, i: usize, page: Page, id: u64, label: []const u8, summary: []const u8, active: bool) !*Row {
        while (self.rows.items.len <= i) {
            const value = try self.allocator.create(Row);
            errdefer self.allocator.destroy(value);
            value.* = .{ .owner = self, .button = .{ .label = "", .onClick = Row.click } };
            value.button.userdata = value;
            try self.rows.append(self.allocator, value);
        }
        const value = self.rows.items[i];
        if (value.id != id or value.page != page) value.button.mouse_down = false;
        value.page = page;
        value.id = id;
        value.button.label = label;
        value.summary = summary;
        value.button.style.default = if (active) self.colors.selected else self.colors.panel;
        value.button.style.hover = self.colors.selected;
        value.button.style.focus = self.colors.selected;
        value.button.style.mouse_down = self.colors.selected;
        return value;
    }

    fn scrollMouse(self: *Dashboard, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) !bool {
        const area = self.list_area;
        const len = if (self.page == .canaries) self.canaries.items.len else self.endpoints.items.len;
        const viewport = &self.viewports[@backingInt(self.page)];
        if (self.scrollbar_drag != null and mouse.type == .release) {
            self.scrollbar_drag = null;
            ctx.consumeEvent();
            return true;
        }
        if (area.height == 0 or len == 0) return false;
        const capacity = area.height / area.row_height;
        const maximum = len -| capacity;
        if (area.contains(mouse) and mouse.type == .press and (mouse.button == .wheel_down or mouse.button == .wheel_up)) {
            viewport.start = if (mouse.button == .wheel_down) @min(viewport.start + 1, maximum) else viewport.start -| 1;
            viewport.ensure_selection = false;
            self.toolbar_focus = null;
            try ctx.requestFocus(self.widget());
            ctx.consumeAndRedraw();
            return true;
        }
        if (maximum == 0) return false;
        const thumb = @max(@as(usize, 1), area.height * capacity / len);
        const travel = area.height - thumb;
        const thumb_top = viewport.start * travel / maximum;
        if (area.contains(mouse) and @as(usize, @intCast(mouse.col)) == area.x + area.width - 1 and mouse.type == .press and mouse.button == .left) {
            const relative_row = @as(usize, @intCast(mouse.row)) - area.y;
            self.scrollbar_drag = if (relative_row >= thumb_top and relative_row < thumb_top + thumb) relative_row - thumb_top else thumb / 2;
            if (relative_row < thumb_top or relative_row >= thumb_top + thumb) {
                const position = @min(relative_row -| self.scrollbar_drag.?, travel);
                viewport.start = if (travel == 0) 0 else position * maximum / travel;
            }
            viewport.ensure_selection = false;
            self.toolbar_focus = null;
            try ctx.requestFocus(self.widget());
            ctx.consumeAndRedraw();
            return true;
        }
        if (self.scrollbar_drag) |grab| {
            if (mouse.type == .drag or mouse.type == .motion) {
                const relative_row: usize = @intCast(@max(@as(i32, mouse.row) - @as(i32, @intCast(area.y)), 0));
                const position = @min(relative_row -| grab, travel);
                viewport.start = if (travel == 0) 0 else position * maximum / travel;
                viewport.ensure_selection = false;
                ctx.consumeAndRedraw();
                return true;
            }
        }
        return false;
    }

    fn list(self: *Dashboard, surface: vxfw.Surface, children: *std.ArrayList(vxfw.SubSurface), ctx: vxfw.DrawContext, x: usize, y: usize, width: usize, height: usize) !void {
        if (width < 2 or height == 0) return;
        const row_height: usize = if (surface.size.width >= 112) 3 else 1;
        const capacity = height / row_height;
        if (capacity == 0) return;
        if (self.list_area.height != height or self.list_area.row_height != row_height) self.viewports[@backingInt(self.page)].ensure_selection = true;
        self.list_area = .{ .x = x, .y = y, .width = width, .height = height, .row_height = row_height };
        const page = self.page;
        const len = if (page == .canaries) self.canaries.items.len else self.endpoints.items.len;
        const title = if (page == .canaries) "CANARIES" else "ENDPOINTS";
        if (len == 0) {
            text(surface, ctx, x, y -| 1, width, title, self.colors.accent);
            text(surface, ctx, x, y, width, if (page == .canaries) "No canaries" else "No endpoints", self.colors.muted);
            return;
        }
        const index = if (page == .canaries) &self.canary_index else &self.endpoint_index;
        index.* = @min(index.*, len - 1);
        const viewport = &self.viewports[@backingInt(page)];
        viewport.start = @min(viewport.start, len -| capacity);
        // Keyboard selection follows the cursor. Wheel browsing deliberately
        // leaves the selection and its detail panel unchanged.
        if (viewport.ensure_selection) {
            if (index.* < viewport.start) viewport.start = index.*;
            if (index.* >= viewport.start + capacity) viewport.start = index.* - capacity + 1;
            viewport.ensure_selection = false;
        }
        text(surface, ctx, x, y -| 1, width, try std.fmt.allocPrint(ctx.arena, "{s} {d}/{d}  [j/k]", .{ title, index.* + 1, len }), self.colors.accent);
        const overflow = len > capacity;
        const row_width = width - @as(usize, if (overflow) 2 else 0);
        for (viewport.start..@min(len, viewport.start + capacity)) |i| {
            const id = if (page == .canaries) self.canaries.items[i].id else self.endpoints.items[i].id;
            const name = if (page == .canaries) self.canaries.items[i].name else self.endpoints.items[i].name;
            const label = try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ if (i == index.*) ">" else " ", name });
            const summary = if (page == .canaries) blk: {
                const canary = self.canaries.items[i];
                break :blk try std.fmt.allocPrint(ctx.arena, "{s} ok {d} / fail {d}", .{ if (canary.paused) "paused" else "live", canary.stats.successes, canary.stats.failures });
            } else if (self.selectedCanary()) |canary| blk: {
                const observation: Observation = canary.observations.get(id) orelse .{};
                break :blk try std.fmt.allocPrint(ctx.arena, "{s} wins {d}", .{ @tagName(observation.status), observation.wins });
            } else "";
            const item = try self.row(i - viewport.start, page, id, label, summary, i == index.*);
            try child(children, ctx, item.widget(), x, y + (i - viewport.start) * row_height, row_width, row_height);
        }
        if (overflow) {
            const thumb = @max(@as(usize, 1), height * capacity / len);
            const thumb_top = viewport.start * (height - thumb) / (len - capacity);
            for (0..height) |row_y| text(surface, ctx, x + width - 1, y + row_y, 1, if (row_y >= thumb_top and row_y < thumb_top + thumb) "┃" else "│", if (row_y >= thumb_top and row_y < thumb_top + thumb) self.colors.accent else self.colors.border);
        }
    }

    fn details(self: *Dashboard, full_surface: vxfw.Surface, ctx: vxfw.DrawContext, x: usize, y: usize, width: usize, height: usize) !void {
        const surface = full_surface.trimHeight(@intCast(@min(full_surface.size.height, y + height)));
        const canary = self.selectedCanary() orelse {
            text(surface, ctx, x, y + 1, width, "No canaries", self.colors.muted);
            return;
        };
        const now = @divFloor(runner_mod.nowNs(self.runner.io), std.time.ns_per_ms);
        text(surface, ctx, x, y, width, try std.fmt.allocPrint(ctx.arena, "Canary: {s}  {s}", .{ canary.name, if (canary.paused) "[paused]" else "[live]" }), self.colors.accent);
        text(surface, ctx, x, y + 1, width, canary.sql, self.colors.muted);
        text(surface, ctx, x, y + 2, width, try std.fmt.allocPrint(ctx.arena, "Every {d}ms  /  deadline {d}ms  /  {d} endpoints", .{ canary.interval_ms, canary.timeout_ms, self.endpoints.items.len }), self.colors.muted);
        const mean = if (canary.stats.mean(now)) |value| try std.fmt.allocPrint(ctx.arena, "{d:.2}ms", .{value}) else "no samples";
        text(surface, ctx, x, y + 3, width, try std.fmt.allocPrint(ctx.arena, "OK {d}  FAIL {d}  Mean (60s) {s}", .{ canary.stats.successes, canary.stats.failures, mean }), self.colors.base);
        const winner = if (canary.winner) |id| if (self.endpointIndex(id)) |i| self.endpoints.items[i].name else "removed" else "none";
        text(surface, ctx, x, y + 4, width, try std.fmt.allocPrint(ctx.arena, "Last winner: {s}", .{winner}), self.colors.accent);
        if (height < 11 or width < 36 or (width < 75 and height < 16)) {
            text(surface, ctx, x, y + 6, width, "Enlarge the terminal for live charts.", self.colors.muted);
            return;
        }
        if (width >= 75) {
            const chart_width = (width - 3) / 2;
            const chart_height = @min(@as(usize, 9), height - 9);
            try histogram(surface, ctx, self.colors, &canary.stats, now, x, y + 6, chart_width, chart_height);
            try timeline(surface, ctx, self.colors, &canary.stats, now, x + chart_width + 3, y + 6, width - chart_width - 3, chart_height);
        } else {
            const chart_height = @max(@as(usize, 2), (height - 12) / 2);
            try histogram(surface, ctx, self.colors, &canary.stats, now, x, y + 6, width, chart_height);
            try timeline(surface, ctx, self.colors, &canary.stats, now, x, y + 6 + chart_height + 3, width, chart_height);
        }
    }

    fn endpointDetails(self: *Dashboard, full_surface: vxfw.Surface, children: *std.ArrayList(vxfw.SubSurface), full_ctx: vxfw.DrawContext, x: usize, y: usize, width: usize, height: usize) !void {
        const surface = full_surface.trimHeight(@intCast(@min(full_surface.size.height, y + height)));
        const ctx = full_ctx.withConstraints(.{ .width = 0, .height = 0 }, vxfw.MaxSize.fromSize(surface.size));
        if (self.endpoints.items.len == 0) return;
        self.endpoint_index = @min(self.endpoint_index, self.endpoints.items.len - 1);
        const endpoint = self.endpoints.items[self.endpoint_index];
        text(surface, ctx, x, y, width, try std.fmt.allocPrint(ctx.arena, "Endpoint: {s}", .{endpoint.name}), self.colors.accent);
        text(surface, ctx, x, y + 1, width, endpoint.label, self.colors.muted);
        const canary = self.selectedCanary() orelse {
            text(surface, ctx, x, y + 2, width, "No canaries", self.colors.muted);
            return;
        };
        try child(children, ctx, self.controls[9].button.widget(), x, y + 2, 11, 1);
        try child(children, ctx, self.controls[10].button.widget(), x + 13, y + 2, 11, 1);
        text(surface, ctx, x, y + 4, width, try std.fmt.allocPrint(ctx.arena, "Canary {d}/{d}: {s}  [h/l]", .{ self.canary_index + 1, self.canaries.items.len, canary.name }), self.colors.accent);
        const value: Observation = canary.observations.get(endpoint.id) orelse .{};
        text(surface, ctx, x, y + 6, width, try std.fmt.allocPrint(ctx.arena, "Current: {s}", .{@tagName(value.status)}), statusStyle(self.colors, value.status));
        const last = if (value.last_status) |status| @tagName(status) else "none";
        text(surface, ctx, x, y + 7, width, try std.fmt.allocPrint(ctx.arena, "Last result: {s}  SQLSTATE {s}", .{ last, value.sqlstate }), if (value.last_status) |status| statusStyle(self.colors, status) else self.colors.muted);
        text(surface, ctx, x, y + 9, width, try std.fmt.allocPrint(ctx.arena, "ok {d}  errors {d}  skipped {d}  wins {d}", .{ value.successes, value.errors, value.skipped, value.wins }), self.colors.base);
        const latency = if (value.latency) |n| try std.fmt.allocPrint(ctx.arena, "{d:.2}ms", .{n}) else "-";
        text(surface, ctx, x, y + 10, width, try std.fmt.allocPrint(ctx.arena, "Last result latency: {s}", .{latency}), self.colors.muted);
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Dashboard = @ptrCast(@alignCast(ptr));
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        var canvas = self.colors.base;
        canvas.bg = self.colors.canvas;
        @memset(surface.buffer, .{ .style = canvas });
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const w: usize = surface.size.width;
        const h: usize = surface.size.height;
        if (w < 35 or h < 15) {
            self.list_area = .{};
            text(surface, ctx, 0, 0, w, "mz-watch", self.colors.accent);
            text(surface, ctx, 0, 2, w, "Resize to at least 35x15. Ctrl-C quits.", self.colors.muted);
            return surface;
        }
        text(surface, ctx, 1, 0, w - 2, "mz-watch", self.colors.accent);
        {
            self.controls[3].button.label = if (self.selectedCanary()) |canary| if (canary.paused) "Resume" else "Pause" else "Pause";
            const widths = [_]usize{ 13, 11, 9, 9 };
            var x: usize = 1;
            var y: usize = 2;
            for (self.controls[0..4], widths) |*control, width| {
                if (x + width >= w) {
                    x = 1;
                    y += 2;
                }
                try child(&children, ctx, control.button.widget(), x, y, width, 1);
                x += width + 1;
            }
            try child(&children, ctx, self.controls[6].button.widget(), w - 8, 0, 7, 1);
            for ([_]Page{ .canaries, .endpoints }, 4..) |page, i| {
                const active = self.page == page;
                var style = if (active) self.colors.panel else self.colors.selected;
                style.bold = active;
                self.controls[i].button.style.default = style;
                style.ul_style = .single;
                self.controls[i].button.style.hover = style;
                self.controls[i].button.style.mouse_down = style;
                self.controls[i].button.style.focus = style;
            }
            try child(&children, ctx, self.controls[4].button.widget(), 1, y + 2, 13, 1);
            try child(&children, ctx, self.controls[5].button.widget(), 15, y + 2, 13, 1);
            const top = y + 4;
            const bottom = h - 3;
            if (w >= 112) {
                const sidebar: usize = 30;
                box(surface, ctx, self.colors, 0, top - 1, sidebar + 2, bottom -| top + 2);
                box(surface, ctx, self.colors, 33, top - 1, w - 34, bottom -| top + 2);
                try self.list(surface, &children, ctx, 2, top, sidebar - 2, bottom -| top);
                if (self.page == .canaries) try self.details(surface, ctx, 35, top, w - 37, bottom -| top) else try self.endpointDetails(surface, &children, ctx, 35, top, w - 37, bottom -| top);
            } else {
                const available = bottom -| top;
                const list_height: usize = @min(available -| 2, @min(@as(usize, 6), @max(@as(usize, 2), available -| 13)));
                box(surface, ctx, self.colors, 0, top - 1, w, list_height + 2);
                try self.list(surface, &children, ctx, 1, top, w - 2, list_height);
                const detail_top = top + list_height + 2;
                box(surface, ctx, self.colors, 0, detail_top - 1, w, bottom -| detail_top + 2);
                if (self.page == .canaries) try self.details(surface, ctx, 1, detail_top, w - 2, bottom -| detail_top) else try self.endpointDetails(surface, &children, ctx, 1, detail_top, w - 2, bottom -| detail_top);
            }
            const message = if (self.save_error) |err| try std.fmt.allocPrint(ctx.arena, "Configuration not saved: {t}. Changes are session-only.", .{err}) else self.message;
            text(surface, ctx, 1, h - 2, w - 2, message, if (self.save_error != null or self.runner.failed.load(.acquire)) self.colors.danger else self.colors.muted);
            text(surface, ctx, 1, h - 1, w - 2, "1/2 panels j/k select h/l canary a/e add p pause x remove Tab focus q quit", self.colors.muted);
        }
        surface.children = children.items;
        if (self.form != .none) {
            dim(surface, self.colors);
            const modal_width = @min(w, if (self.form == .remove_endpoint or self.form == .remove_canary) @as(usize, 54) else 94);
            const modal_height = @min(h, if (self.form == .canary) @as(usize, 18) else 14);
            self.modal_area = .{ .x = (w - modal_width) / 2, .y = (h - modal_height) / 2, .width = modal_width, .height = modal_height };
            try child(&children, ctx, self.modalWidget(), self.modal_area.x, self.modal_area.y, modal_width, modal_height);
            surface.children = children.items;
        }
        return surface;
    }

    fn modalWidget(self: *Dashboard) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawModal, .eventHandler = modalEvent };
    }

    fn modalEvent(_: *anyopaque, ctx: *vxfw.EventContext, ev: vxfw.Event) !void {
        if (ev == .mouse) ctx.consumeEvent();
    }

    fn drawModal(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Dashboard = @ptrCast(@alignCast(ptr));
        var surface = try vxfw.Surface.init(ctx.arena, self.modalWidget(), ctx.max.size());
        @memset(surface.buffer, .{ .style = self.colors.panel });
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try self.drawForm(surface, &children, ctx);
        surface.children = children.items;
        return surface;
    }

    fn drawForm(self: *Dashboard, surface: vxfw.Surface, children: *std.ArrayList(vxfw.SubSurface), ctx: vxfw.DrawContext) !void {
        const w: usize = surface.size.width;
        const h: usize = surface.size.height;
        const width = @min(@as(usize, 90), w - 4);
        const x = (w - width) / 2;
        const removal = self.form == .remove_endpoint or self.form == .remove_canary;
        box(surface, ctx, self.colors, x - 1, 1, width + 2, @min(h - 2, if (self.form == .canary) @as(usize, 15) else 11));
        text(surface, ctx, x, 2, width, if (removal) "Remove selected item?" else if (self.form == .endpoint) "ADD ENDPOINT" else "ADD CANARY", self.colors.accent);
        if (removal) {
            const name = if (self.form == .remove_canary) (self.selectedCanary() orelse return).name else self.endpoints.items[@min(self.endpoint_index, self.endpoints.items.len - 1)].name;
            text(surface, ctx, x, 5, width, try std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ if (self.form == .remove_canary) "Canary" else "Endpoint", name }), self.colors.base);
            self.controls[7].button.label = "Remove";
        } else {
            self.controls[7].button.label = "Save";
            const labels: []const []const u8 = if (self.form == .endpoint) &.{ "Name", "libpq URI / conninfo / service=name (use verify-full for TLS)" } else &.{ "Name", "SQL (one read-only statement)", "Interval (milliseconds)", "Timeout (milliseconds)" };
            for (labels, 0..) |label, i| {
                text(surface, ctx, x, 3 + i * 2, width, label, self.colors.muted);
                try child(children, ctx, self.fields[i].widget(), x, 4 + i * 2, width, 1);
            }
        }
        const button_y: usize = if (removal) 8 else if (self.form == .endpoint) 8 else 12;
        try child(children, ctx, self.controls[7].button.widget(), x, button_y, 12, 1);
        try child(children, ctx, self.controls[8].button.widget(), x + 14, button_y, 12, 1);
        text(surface, ctx, x, @min(button_y + 2, h - 2), width, self.message, self.colors.danger);
        text(surface, ctx, x, h - 1, width, "Tab / Shift-Tab move  Enter submits  Esc cancels", self.colors.muted);
    }
};

fn dim(surface: vxfw.Surface, colors: Palette) void {
    const scrim: [3]u8 = if (colors.canvas == .default) .{ 19, 23, 30 } else .{ 218, 224, 230 };
    for (surface.buffer) |*cell| {
        cell.style.fg = blend(cell.style.fg, scrim);
        cell.style.bg = blend(cell.style.bg, scrim);
        cell.style.bold = false;
    }
    for (surface.children) |sub| dim(sub.surface, colors);
}

fn blend(color: vaxis.Cell.Color, scrim: [3]u8) vaxis.Cell.Color {
    const source = if (color == .rgb) color.rgb else scrim;
    var result: [3]u8 = undefined;
    for (&result, source, scrim) |*channel, original, target| channel.* = @intCast((@as(u16, original) + @as(u16, target) * 2) / 3);
    return .{ .rgb = result };
}

fn statusStyle(colors: Palette, status: runner_mod.Status) vaxis.Style {
    return switch (status) {
        .success, .ready => colors.accent,
        .query_error, .connection_error, .timeout => colors.danger,
        else => colors.muted,
    };
}

fn child(children: *std.ArrayList(vxfw.SubSurface), ctx: vxfw.DrawContext, widget: vxfw.Widget, x: usize, y: usize, width: usize, height: usize) !void {
    const size = ctx.max.size();
    if (x >= size.width or y >= size.height) return;
    const w: u16 = @intCast(@min(width, size.width - x));
    const h: u16 = @intCast(@min(height, size.height - y));
    if (w == 0 or h == 0) return;
    try children.append(ctx.arena, .{
        .origin = .{ .row = @intCast(y), .col = @intCast(x) },
        .surface = try widget.draw(ctx.withConstraints(.{ .width = w, .height = h }, .{ .width = w, .height = h })),
    });
}

fn box(surface: vxfw.Surface, ctx: vxfw.DrawContext, colors: Palette, x: usize, y: usize, width: usize, height: usize) void {
    if (width < 2 or height < 2) return;
    for (y..@min(y + height, surface.size.height)) |row_y| {
        for (x..@min(x + width, surface.size.width)) |col| surface.writeCell(@intCast(col), @intCast(row_y), .{ .style = colors.panel });
    }
    for (1..width - 1) |col| {
        text(surface, ctx, x + col, y, 1, "─", colors.border);
        text(surface, ctx, x + col, y + height - 1, 1, "─", colors.border);
    }
    for (1..height - 1) |row_y| {
        text(surface, ctx, x, y + row_y, 1, "│", colors.border);
        text(surface, ctx, x + width - 1, y + row_y, 1, "│", colors.border);
    }
    text(surface, ctx, x, y, 1, "╭", colors.border);
    text(surface, ctx, x + width - 1, y, 1, "╮", colors.border);
    text(surface, ctx, x, y + height - 1, 1, "╰", colors.border);
    text(surface, ctx, x + width - 1, y + height - 1, 1, "╯", colors.border);
}

fn text(surface: vxfw.Surface, ctx: vxfw.DrawContext, x: usize, y: usize, width: usize, value: []const u8, style: vaxis.Style) void {
    if (y >= surface.size.height or x >= surface.size.width) return;
    var iter = ctx.graphemeIterator(value);
    var col = x;
    const end = @min(surface.size.width, x + width);
    while (iter.next()) |grapheme| {
        const raw = grapheme.bytes(value);
        const bytes = if (raw.len == 1 and (raw[0] < 32 or raw[0] == 127)) " " else raw;
        const n = ctx.stringWidth(bytes);
        if (n == 0) continue;
        if (col + n > end) break;
        var inherited = style;
        if (inherited.bg == .default) inherited.bg = surface.readCell(col, y).style.bg;
        surface.writeCell(@intCast(col), @intCast(y), .{ .char = .{ .grapheme = bytes, .width = @intCast(n) }, .style = inherited });
        col += n;
    }
}

fn histogram(surface: vxfw.Surface, ctx: vxfw.DrawContext, colors: Palette, stats: *const metrics.Stats, now: i64, x: usize, y: usize, width: usize, height: usize) !void {
    const bins = stats.histogram(now);
    var peak: u64 = 1;
    for (bins) |count| peak = @max(peak, count);
    text(surface, ctx, x, y, width, try std.fmt.allocPrint(ctx.arena, "HISTOGRAM 60s  peak {d}", .{peak}), colors.muted);
    const stride = @max(@as(usize, 1), width / 12);
    for (bins, 0..) |count, i| {
        const n: usize = @intCast((count * height + peak - 1) / peak);
        for (0..n) |row_y| text(surface, ctx, x + i * stride, y + height - row_y, @max(@as(usize, 1), stride -| 1), "██", colors.accent);
    }
    const labels = [_][]const u8{ "1", "2", "5", "10", "20", "50", ".1s", ".2s", ".5s", "1s", "5s", ">5s" };
    for (labels, 0..) |label, i| text(surface, ctx, x + i * stride, y + height + 1, stride, label, colors.muted);
    text(surface, ctx, x, y + height + 2, width, "Inclusive upper bounds (ms unless marked s)", colors.muted);
}

fn timeline(surface: vxfw.Surface, ctx: vxfw.DrawContext, colors: Palette, stats: *const metrics.Stats, now: i64, x: usize, y: usize, width: usize, height: usize) !void {
    const series = stats.series(now);
    var peak: f64 = 1;
    for (series) |value| if (value) |n| {
        peak = @max(peak, n);
    };
    text(surface, ctx, x, y, width, try std.fmt.allocPrint(ctx.arena, "MEAN / SECOND  top {d:.1}ms", .{peak}), colors.muted);
    for (series, 0..) |value, i| {
        const n = value orelse continue;
        const row: usize = @intFromFloat(@round(n / peak * @as(f64, @floatFromInt(height - 1))));
        text(surface, ctx, x + i * (width - 1) / 59, y + height - row, 1, "•", colors.accent);
    }
    text(surface, ctx, x, y + height + 1, width, "-59s", colors.muted);
    text(surface, ctx, x + width -| 3, y + height + 1, 3, "now", colors.muted);
    text(surface, ctx, x, y + height + 2, width, "Gaps = no successful samples", colors.muted);
}
