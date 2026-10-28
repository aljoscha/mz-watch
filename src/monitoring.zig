//! UI-owned controller snapshots. Failed polls never replace a good inventory.
const std = @import("std");
const config = @import("config.zig");
const controller = @import("controller.zig");
const discovery = @import("discovery.zig");
const Value = std.json.Value;

pub const Source = struct {
    saved: config.Controller,
    worker: *controller.Worker,
    inventory: ?controller.InventoryParsed = null,
    collections: ?controller.CollectionsParsed = null,
    inventory_error: bool = true,
    collections_error: bool = true,
    revision: u64 = 0,
};
pub const Service = struct { controller_index: usize, title: []const u8, details: []const u8, addresses: []const u8 };
pub const Destination = struct { conninfo: []const u8, sources: []const u8 };

pub const Monitor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    controllers: std.ArrayList(Source) = .empty,
    selected: usize = 0,
    id_filter: []const u8 = "",
    name_filter: []const u8 = "",
    started: bool = false,
    changed: bool = true,

    pub fn init(a: std.mem.Allocator, io: std.Io) Monitor {
        return .{ .allocator = a, .io = io };
    }
    pub fn deinit(self: *Monitor) void {
        for (self.controllers.items) |*source| self.freeSource(source);
        self.controllers.deinit(self.allocator);
        if (self.id_filter.len > 0) self.allocator.free(self.id_filter);
        if (self.name_filter.len > 0) self.allocator.free(self.name_filter);
    }
    fn freeSource(self: *Monitor, source: *Source) void {
        source.worker.deinit();
        self.allocator.destroy(source.worker);
        if (source.inventory) |*value| value.deinit();
        if (source.collections) |*value| value.deinit();
        self.allocator.free(source.saved.name);
        self.allocator.free(source.saved.url);
        self.allocator.free(source.saved.conninfo);
    }
    pub fn load(self: *Monitor, saved: config.Config) !void {
        try self.setFilters(saved.collection_id_filter, saved.collection_name_filter);
        for (saved.controllers) |item| try self.add(item);
        self.selected = 0;
        if (saved.collections_controller) |url| for (self.controllers.items, 0..) |source, i| {
            if (std.mem.eql(u8, source.saved.url, std.mem.trimEnd(u8, url, "/"))) self.selected = i;
        };
    }
    pub fn configuration(self: *Monitor, a: std.mem.Allocator) ![]config.Controller {
        const result = try a.alloc(config.Controller, self.controllers.items.len);
        for (result, self.controllers.items) |*item, source| item.* = source.saved;
        return result;
    }
    pub fn selectedUrl(self: *Monitor) ?[]const u8 {
        const source = self.selectedSource() orelse return null;
        return source.saved.url;
    }
    pub fn selectedName(self: *Monitor) []const u8 {
        const source = self.selectedSource() orelse return "No controllers";
        return source.saved.name;
    }
    pub fn selectedSource(self: *Monitor) ?*Source {
        if (self.controllers.items.len == 0) return null;
        self.selected = @min(self.selected, self.controllers.items.len - 1);
        return &self.controllers.items[self.selected];
    }
    pub fn select(self: *Monitor, down: bool) void {
        if (self.controllers.items.len > 0) self.selected = if (down) @min(self.selected + 1, self.controllers.items.len - 1) else self.selected -| 1;
    }
    pub fn add(self: *Monitor, saved: config.Controller) !void {
        try config.validate(.{ .controllers = &.{saved} });
        for (self.controllers.items) |source| if (std.mem.eql(u8, std.mem.trimEnd(u8, source.saved.url, "/"), std.mem.trimEnd(u8, saved.url, "/"))) return error.DuplicateController;
        const canonical = try discovery.canonical(self.allocator, saved.conninfo);
        defer self.allocator.free(canonical);
        const name = try self.allocator.dupe(u8, saved.name);
        errdefer self.allocator.free(name);
        const url = try self.allocator.dupe(u8, std.mem.trimEnd(u8, saved.url, "/"));
        errdefer self.allocator.free(url);
        const conninfo = try self.allocator.dupe(u8, saved.conninfo);
        errdefer self.allocator.free(conninfo);
        const worker = try self.allocator.create(controller.Worker);
        errdefer self.allocator.destroy(worker);
        worker.* = try controller.Worker.init(self.allocator, self.io, url);
        errdefer worker.deinit();
        try worker.setFilters(optional(self.id_filter), optional(self.name_filter));
        try self.controllers.ensureUnusedCapacity(self.allocator, 1);
        if (self.started) try worker.start();
        self.controllers.appendAssumeCapacity(.{ .saved = .{ .name = name, .url = url, .conninfo = conninfo }, .worker = worker, .revision = worker.currentRevision() });
        self.selected = self.controllers.items.len - 1;
        self.changed = true;
    }
    pub fn start(self: *Monitor) !void {
        if (self.started) return;
        self.started = true;
        for (self.controllers.items) |source| try source.worker.start();
    }
    pub fn removeSelected(self: *Monitor) !void {
        if (self.selectedSource() == null) return;
        self.remove(self.selected);
    }
    pub fn remove(self: *Monitor, index: usize) void {
        var source = self.controllers.orderedRemove(index);
        self.freeSource(&source);
        if (index < self.selected) self.selected -= 1;
        if (self.controllers.items.len > 0) self.selected = @min(self.selected, self.controllers.items.len - 1);
        self.changed = true;
    }
    pub fn setFilters(self: *Monitor, id: []const u8, name: []const u8) !void {
        try config.validate(.{ .collection_id_filter = id, .collection_name_filter = name });
        const owned_id = if (id.len > 0) try self.allocator.dupe(u8, id) else "";
        errdefer if (owned_id.len > 0) self.allocator.free(owned_id);
        const owned_name = if (name.len > 0) try self.allocator.dupe(u8, name) else "";
        errdefer if (owned_name.len > 0) self.allocator.free(owned_name);
        for (self.controllers.items) |*source| {
            try source.worker.setFilters(optional(id), optional(name));
            source.revision = source.worker.currentRevision();
            if (source.collections) |*value| value.deinit();
            source.collections = null;
            source.collections_error = true;
        }
        if (self.id_filter.len > 0) self.allocator.free(self.id_filter);
        if (self.name_filter.len > 0) self.allocator.free(self.name_filter);
        self.id_filter = owned_id;
        self.name_filter = owned_name;
    }
    pub fn drain(self: *Monitor) !void {
        for (self.controllers.items) |*source| {
            if (source.worker.takeUpdate()) |update_value| {
                var update = update_value;
                defer update.deinit();
                if (update.inventory_attempted) source.inventory_error = update.inventory_error != null;
                if (update.inventory) |value| {
                    if (source.inventory) |*old| old.deinit();
                    source.inventory = value;
                    update.inventory = null;
                    self.changed = true;
                }
                if (update.revision == source.revision) {
                    if (update.collections_attempted) source.collections_error = update.collections_error != null;
                    if (update.collections) |value| {
                        if (source.collections) |*old| old.deinit();
                        source.collections = value;
                        update.collections = null;
                    }
                }
            }
        }
    }
    pub fn destinations(self: *Monitor, a: std.mem.Allocator) ![]Destination {
        var result: std.ArrayList(Destination) = .empty;
        for (self.controllers.items) |source| {
            const snapshot = source.inventory orelse continue;
            for (snapshot.value.adapters) |adapter| {
                for (adapter.endpoints.map.get("sql-external") orelse &.{}) |address| {
                    const conninfo = discovery.destination(a, source.saved.conninfo, address) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        continue;
                    };
                    const label = try std.fmt.allocPrint(a, "{s}/g{d}/{s} ({s})", .{ source.saved.name, adapter.generation, adapter.id, adapter.name });
                    var found = false;
                    for (result.items) |*existing| if (std.mem.eql(u8, existing.conninfo, conninfo)) {
                        existing.sources = try std.fmt.allocPrint(a, "{s}, {s}", .{ existing.sources, label });
                        found = true;
                        break;
                    };
                    if (!found) try result.append(a, .{ .conninfo = conninfo, .sources = label });
                }
            }
        }
        return result.toOwnedSlice(a);
    }
    pub fn serviceCount(self: *Monitor) usize {
        var n: usize = 0;
        for (self.controllers.items) |source| {
            n += 1;
            if (source.inventory) |snapshot| n += snapshot.value.adapters.len + snapshot.value.replicas.len + @as(usize, if (snapshot.value.pubsub != null) 1 else 0);
        }
        return n;
    }
    pub fn selectService(self: *Monitor, index: usize) void {
        var first: usize = 0;
        for (self.controllers.items, 0..) |source, i| {
            const count = if (source.inventory) |snapshot| 1 + snapshot.value.adapters.len + snapshot.value.replicas.len + @as(usize, if (snapshot.value.pubsub != null) 1 else 0) else 1;
            if (index < first + count) {
                self.selected = i;
                return;
            }
            first += count;
        }
    }
    pub fn services(self: *Monitor, a: std.mem.Allocator) ![]Service {
        var result: std.ArrayList(Service) = .empty;
        for (self.controllers.items, 0..) |source, i| {
            try result.append(a, .{ .controller_index = i, .title = try std.fmt.allocPrint(a, "Controller: {s}  [{s}]", .{ source.saved.name, if (source.inventory_error) "stale / unavailable" else "live" }), .details = source.saved.url, .addresses = "" });
            const snapshot = source.inventory orelse continue;
            for (snapshot.value.adapters) |entry| {
                const ready = if (entry.readiness) |value| if (value.ready) |yes| if (yes) "ready" else "not ready" else "unknown" else "unknown";
                const process = try processSummary(a, entry.observed_processes);
                try result.append(a, .{ .controller_index = i, .title = try std.fmt.allocPrint(a, "Adapter: {s} ({s})", .{ entry.name, entry.id }), .details = try std.fmt.allocPrint(a, "g{d}  {s}  SQL {s}{s}{s}", .{ entry.generation, process, ready, if (entry.provisioning_error != null) "  error: " else "", entry.provisioning_error orelse "" }), .addresses = try endpointsText(a, entry.endpoints) });
            }
            for (snapshot.value.replicas) |entry| {
                try result.append(a, .{ .controller_index = i, .title = try std.fmt.allocPrint(a, "Replica: {s}.{s} ({s}/{s})", .{ entry.cluster_name, entry.replica_name, entry.cluster_id, entry.replica_id }), .details = try std.fmt.allocPrint(a, "g{d}  {s}{s}{s}", .{ entry.generation, try processSummary(a, entry.observed_processes), if (entry.provisioning_error != null) "  error: " else "", entry.provisioning_error orelse "" }), .addresses = try endpointsText(a, entry.endpoints) });
            }
            if (snapshot.value.pubsub) |entry| {
                try result.append(a, .{ .controller_index = i, .title = "Pubsub", .details = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ try processSummary(a, entry.observed_processes), if (entry.provisioning_error != null) "  error: " else "", entry.provisioning_error orelse "" }), .addresses = try endpointsText(a, entry.endpoints) });
            }
        }

        return result.toOwnedSlice(a);
    }
    pub fn collectionCount(self: *Monitor) usize {
        const source = self.selectedSource() orelse return 0;
        const snapshot = source.collections orelse return 0;
        return snapshot.value.len;
    }
    pub fn collections(self: *Monitor) controller.Collections {
        const source = self.selectedSource() orelse return &.{};
        const snapshot = source.collections orelse return &.{};
        return snapshot.value;
    }
};
pub fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn string(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
pub fn array(value: Value) []const Value {
    return if (value == .array) value.array.items else &.{};
}
pub fn json(a: std.mem.Allocator, value: Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

fn optional(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
fn endpointsText(a: std.mem.Allocator, endpoints: controller.Endpoints) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var iter = endpoints.map.iterator();
    while (iter.next()) |entry| for (entry.value_ptr.*) |address| {
        try parts.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ entry.key_ptr.*, address }));
    };
    return std.mem.join(a, "  ", parts.items);
}
fn processSummary(a: std.mem.Allocator, processes: Value) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const entries = if (processes == .array) processes.array.items else if (processes == .object) processes.object.values() else &.{};
    for (entries) |entry| {
        const status = field(entry, "status");
        try parts.append(a, try std.fmt.allocPrint(a, "p{s}: {s} restarts {s}", .{ try json(a, field(entry, "process_id")), if (status == .string) string(status) else try json(a, status), try json(a, field(entry, "restart_count")) }));
    }
    return if (parts.items.len == 0) "process unknown" else std.mem.join(a, ", ", parts.items);
}

const inventory_fixture =
    \\{"generation":7,"adapters":[{"id":"a1","name":"main","generation":7,"service":"adapter-a1","endpoints":{"sql-external":["127.0.0.1:6875"],"sql-internal":["127.0.0.1:6877"],"custom-http":["127.0.0.1:6880"]},"observed_processes":[{"process_id":0,"status":"online","restart_count":2}],"readiness":{"ready":false,"error":null,"changed_at":123}}],"replicas":[],"pubsub":null}
;

test "discovery deduplicates destinations across controllers without merging service identity" {
    const a = std.testing.allocator;
    var monitor = Monitor.init(a, std.testing.io);
    defer monitor.deinit();
    try monitor.load(.{ .controllers = &.{
        .{ .name = "old", .url = "http://localhost:1" },
        .{ .name = "new", .url = "http://localhost:2" },
    }, .collections_controller = "http://localhost:2/" });
    try std.testing.expectEqualStrings("new", monitor.selectedName());
    for (monitor.controllers.items) |*source| source.inventory = try controller.parseInventory(a, inventory_fixture);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const destinations = try monitor.destinations(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), destinations.len);
    try std.testing.expect(std.mem.indexOf(u8, destinations[0].sources, "old/g7/a1") != null);
    try std.testing.expect(std.mem.indexOf(u8, destinations[0].sources, "new/g7/a1") != null);
    try std.testing.expect(std.mem.indexOf(u8, destinations[0].conninfo, "6877") == null);
    const services = try monitor.services(arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), services.len);
    try std.testing.expect(std.mem.indexOf(u8, services[1].details, "online") != null);
    try std.testing.expect(std.mem.indexOf(u8, services[1].details, "SQL not ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, services[1].addresses, "custom-http=") != null);
    monitor.selected = 0;
    try monitor.removeSelected();
    const remaining = try monitor.destinations(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expect(std.mem.indexOf(u8, remaining[0].sources, "old/") == null);
}

fn loadOwnership(a: std.mem.Allocator) !void {
    var monitor = Monitor.init(a, std.testing.io);
    defer monitor.deinit();
    try monitor.load(.{ .controllers = &.{.{ .name = "demo", .url = "http://localhost:6882" }}, .collection_name_filter = "%test%", .collection_id_filter = "u%" });
    try monitor.setFilters("s%", "");
}
test "controller configuration and filter ownership survive allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadOwnership, .{});
}
