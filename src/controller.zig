const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Endpoints = std.json.ArrayHashMap([]const []const u8);
pub const Readiness = struct {
    ready: ?bool = null,
    @"error": ?[]const u8 = null,
    changed_at: i64,
};
pub const Adapter = struct {
    id: []const u8,
    name: []const u8,
    generation: u64,
    service: []const u8,
    endpoints: Endpoints,
    observed_processes: std.json.Value,
    readiness: ?Readiness = null,
    provisioning_error: ?[]const u8 = null,
};
pub const Replica = struct {
    cluster_id: []const u8,
    replica_id: []const u8,
    cluster_name: []const u8,
    replica_name: []const u8,
    generation: u64,
    service: []const u8,
    endpoints: Endpoints,
    observed_processes: std.json.Value,
    provisioning_error: ?[]const u8 = null,
};
pub const Pubsub = struct {
    service: []const u8,
    cpu_limit: std.json.Value,
    memory_limit: std.json.Value,
    endpoints: Endpoints,
    // Pubsub uses a process-ID-keyed object, adapters and replicas use arrays.
    observed_processes: std.json.Value,
    provisioning_error: ?[]const u8 = null,
};
pub const Inventory = struct {
    generation: u64,
    pubsub: ?Pubsub = null,
    adapters: []const Adapter,
    replicas: []const Replica,
};
pub const Collection = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    // Rust Timestamp serializes its inner u64, not a string or object.
    since: ?[]const u64 = null,
};
pub const Collections = []const Collection;
pub const InventoryParsed = std.json.Parsed(Inventory);
pub const CollectionsParsed = std.json.Parsed(Collections);

pub fn parseInventory(allocator: Allocator, bytes: []const u8) !InventoryParsed {
    return std.json.parseFromSlice(Inventory, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
pub fn parseCollections(allocator: Allocator, bytes: []const u8) !CollectionsParsed {
    return std.json.parseFromSlice(Collections, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Owned snapshot delta. A null parse never replaces the UI's last good data.
/// An attempted flag distinguishes success (null error) from no new observation.
/// Only render collections when revision matches the currently applied filters.
pub const Update = struct {
    revision: u64,
    inventory: ?InventoryParsed = null,
    collections: ?CollectionsParsed = null,
    inventory_attempted: bool = false,
    collections_attempted: bool = false,
    inventory_error: ?[]const u8 = null,
    collections_error: ?[]const u8 = null,

    pub fn deinit(self: *Update) void {
        if (self.inventory) |value| value.deinit();
        if (self.collections) |value| value.deinit();
        self.* = .{ .revision = self.revision };
    }
};

const max_response = 16 * 1024 * 1024;
const Kind = enum { inventory, collections };

/// Keep at a stable address from start until deinit. Allocator and Io must be
/// threadsafe and outlive the worker and every transferred Update. UI methods
/// are serialized by the caller. deinit cancels and joins both polling tasks.
/// Requires curl on PATH for interruptible DNS with libc-linked Zig runtimes.
pub const Worker = struct {
    allocator: Allocator,
    io: Io,
    url: []const u8,
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    started: bool = false,
    stopping: bool = false,
    revision: u64 = 0,
    id_pattern: ?[]const u8 = null,
    name_pattern: ?[]const u8 = null,
    pending: ?Update = null,

    /// Copies and validates a base URL. Paths are preserved as a base prefix.
    /// Credentials, queries and fragments are rejected rather than propagated.
    pub fn init(allocator: Allocator, io: Io, url: []const u8) !Worker {
        try validateUrl(url);
        return .{ .allocator = allocator, .io = io, .url = try allocator.dupe(u8, std.mem.trimEnd(u8, url, "/")) };
    }

    pub fn start(self: *Worker) !void {
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            self.group.cancel(self.io);
            self.stopping = false;
            self.started = false;
        }
        try self.group.concurrent(self.io, poll, .{ self, .inventory });
        try self.group.concurrent(self.io, poll, .{ self, .collections });
    }

    pub fn deinit(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.group.cancel(self.io);
        if (self.pending) |*update| update.deinit();
        if (self.id_pattern) |value| self.allocator.free(value);
        if (self.name_pattern) |value| self.allocator.free(value);
        self.allocator.free(self.url);
        self.* = undefined;
    }

    /// Null omits a filter, while an empty string is an exact empty LIKE pattern.
    /// Copies both patterns atomically and advances revision even for equal input.
    /// Clear displayed collection rows when applying filters, until a matching
    /// revision arrives. Inventory itself has no server-side filter API.
    pub fn setFilters(self: *Worker, id_pattern: ?[]const u8, name_pattern: ?[]const u8) !void {
        const id = if (id_pattern) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (id) |value| self.allocator.free(value);
        const name = if (name_pattern) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (name) |value| self.allocator.free(value);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        if (self.id_pattern) |value| self.allocator.free(value);
        if (self.name_pattern) |value| self.allocator.free(value);
        self.id_pattern = id;
        self.name_pattern = name;
        self.revision += 1;
        if (self.pending) |*update| update.deinit();
        self.pending = null;
        self.changed.broadcast(self.io);
    }

    pub fn currentRevision(self: *Worker) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.revision;
    }

    /// Transfers ownership, including the arenas. Caller must call Update.deinit.
    pub fn takeUpdate(self: *Worker) ?Update {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const update = self.pending;
        self.pending = null;
        return update;
    }

    fn publish(self: *Worker, update: *Update) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or update.revision != self.revision) return;
        if (self.pending == null) self.pending = .{ .revision = update.revision };
        const pending = &self.pending.?;
        // Coalesce per endpoint, preserving an unconsumed good parse on failure.
        if (update.inventory_attempted) {
            pending.inventory_attempted = true;
            pending.inventory_error = update.inventory_error;
            if (update.inventory) |value| {
                if (pending.inventory) |old| old.deinit();
                pending.inventory = value;
                update.inventory = null;
            }
        }
        if (update.collections_attempted) {
            pending.collections_attempted = true;
            pending.collections_error = update.collections_error;
            if (update.collections) |value| {
                if (pending.collections) |old| old.deinit();
                pending.collections = value;
                update.collections = null;
            }
        }
    }

    fn poll(self: *Worker, kind: Kind) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const revision = self.revision;
            const url = buildUrl(self.allocator, self.url, kind, self.id_pattern, self.name_pattern) catch {
                self.mutex.unlock(self.io);
                var update: Update = .{ .revision = revision };
                markError(&update, kind, "request allocation failed");
                self.publish(&update);
                if (!self.wait(revision)) return;
                continue;
            };
            self.mutex.unlock(self.io);
            var update = self.fetch(kind, url, revision);
            self.allocator.free(url);
            self.publish(&update);
            update.deinit();
            if (!self.wait(revision)) return;
        }
    }

    fn wait(self: *Worker, revision: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const deadline: Io.Timeout = .{ .deadline = .fromNow(self.io, .{ .clock = .awake, .raw = .fromSeconds(1) }) };
        while (!self.stopping and revision == self.revision) {
            self.changed.waitTimeout(self.io, &self.mutex, deadline) catch |err| switch (err) {
                error.Timeout => return true,
                error.Canceled => return false,
            };
        }
        return !self.stopping;
    }

    fn fetch(self: *Worker, kind: Kind, url: []const u8, revision: u64) Update {
        var update: Update = .{ .revision = revision };
        switch (kind) {
            .inventory => update.inventory_attempted = true,
            .collections => update.collections_attempted = true,
        }
        // Zig's libc resolver uses blocking getaddrinfo. A killable subprocess
        // bounds DNS, connect, TLS and body reads alike. process.run kills/reaps
        // on timeout, response overflow or task cancellation. Never load curlrc,
        // follow redirects, disable TLS validation or expose stderr diagnostics.
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "curl", "--disable", "--silent", "--fail", "--globoff", "--noproxy", "*", "--proto", "=http,https", "--connect-timeout", "2", "--max-time", "3", "--max-filesize", "16777216", "--write-out", "\n%{http_code}", "--url", url },
            .stdout_limit = .limited(max_response + 4),
            .stderr_limit = .limited(4096),
            .timeout = .{ .deadline = .fromNow(self.io, .{ .clock = .awake, .raw = .fromSeconds(4) }) },
        }) catch {
            markError(&update, kind, "HTTP request failed");
            return update;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const success = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        const output = result.stdout;
        // curl --fail permits redirects. Require exactly 200 without following.
        if (!success or output.len < 4 or !std.mem.eql(u8, output[output.len - 4 ..], "\n200")) {
            markError(&update, kind, "HTTP request failed");
            return update;
        }
        const body = output[0 .. output.len - 4];
        if (body.len > max_response) {
            markError(&update, kind, "HTTP response too large");
            return update;
        }
        switch (kind) {
            .inventory => update.inventory = parseInventory(self.allocator, body) catch {
                markError(&update, kind, "invalid inventory response");
                return update;
            },
            .collections => update.collections = parseCollections(self.allocator, body) catch {
                markError(&update, kind, "invalid collections response");
                return update;
            },
        }
        return update;
    }
};

fn markError(update: *Update, kind: Kind, message: []const u8) void {
    switch (kind) {
        .inventory => {
            update.inventory_attempted = true;
            update.inventory_error = message;
        },
        .collections => {
            update.collections_attempted = true;
            update.collections_error = message;
        },
    }
}

fn validateUrl(url: []const u8) !void {
    for (url) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUrl;
    if (uri.host == null or uri.host.?.percent_encoded.len == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidUrl;
}

fn encode(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(allocator, byte);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
}

fn buildUrl(allocator: Allocator, base: []const u8, kind: Kind, id: ?[]const u8, name: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, base);
    try out.appendSlice(allocator, switch (kind) {
        .inventory => "/api/inventory",
        .collections => "/api/collections",
    });
    if (kind == .collections) {
        if (id) |value| {
            try out.appendSlice(allocator, "?id=");
            try encode(allocator, &out, value);
        }
        if (name) |value| {
            try out.appendSlice(allocator, if (id != null) "&name=" else "?name=");
            try encode(allocator, &out, value);
        }
    }
    return out.toOwnedSlice(allocator);
}

const inventory_fixture =
    \\{"generation":18446744073709551615,"extra":true,
    \\ "pubsub":{"service":"relay","cpu_limit":1,"memory_limit":"512 MiB",
    \\ "endpoints":{"pubsub":["localhost:9"]},"observed_processes":{"0":{"status":"online"}},"provisioning_error":null},
    \\ "adapters":[{"id":"a1","name":"primary","generation":2,"service":"adapter",
    \\ "endpoints":{"sql-custom":["localhost:1","localhost:2"]},"observed_processes":[],
    \\ "readiness":{"ready":null,"error":"waiting","changed_at":-1},"size":"1"}],
    \\ "replicas":[{"cluster_id":"u1","replica_id":"u2","cluster_name":"c","replica_name":"r",
    \\ "generation":3,"service":"replica","endpoints":{},"observed_processes":[],"provisioning_error":"unavailable"}]}
;

test "typed parses own strings and preserve null, empty and full u64 frontiers" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, inventory_fixture);
    defer allocator.free(source);
    var inventory = try parseInventory(allocator, source);
    defer inventory.deinit();
    @memset(source, 'x');
    try std.testing.expectEqual(std.math.maxInt(u64), inventory.value.generation);
    const adapter = inventory.value.adapters[0];
    try std.testing.expectEqualStrings("primary", adapter.name);
    try std.testing.expectEqualStrings("localhost:2", adapter.endpoints.map.get("sql-custom").?[1]);
    try std.testing.expectEqual(@as(?bool, null), adapter.readiness.?.ready);
    try std.testing.expectEqual(@as(i64, -1), adapter.readiness.?.changed_at);
    try std.testing.expectEqualStrings("waiting", adapter.readiness.?.@"error".?);
    try std.testing.expectEqualStrings("u2", inventory.value.replicas[0].replica_id);
    try std.testing.expect(inventory.value.pubsub.?.observed_processes.object.contains("0"));
    var rows = try parseCollections(allocator,
        \\[{"id":"u1","name":null,"since":null},{"id":"s1","name":"x","since":[]},
        \\ {"id":"u2","since":[0,18446744073709551615],"extra":"ignored"}]
    );
    defer rows.deinit();
    try std.testing.expect(rows.value[0].name == null and rows.value[0].since == null);
    try std.testing.expectEqual(@as(usize, 0), rows.value[1].since.?.len);
    try std.testing.expectEqual(std.math.maxInt(u64), rows.value[2].since.?[1]);
    try std.testing.expectError(error.Overflow, parseCollections(allocator, "[{\"id\":\"u1\",\"since\":[18446744073709551616]}]"));
}

test "URL validation and exact LIKE encoding" {
    for ([_][]const u8{ "file:///tmp/x", "ftp://example.com", "http:///x", "http://a?secret=x", "https://a/#x", "http://u:p@a", "http://a/\r\nx" }) |url| {
        try std.testing.expectError(error.InvalidUrl, validateUrl(url));
    }
    try validateUrl("https://[::1]:6882/base/");
    const url = try buildUrl(std.testing.allocator, "https://host/base", .collections, "s%", "%mz\\_catalog.+ &é");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://host/base/api/collections?id=s%25&name=%25mz%5C_catalog.%2B%20%26%C3%A9", url);
    const empty = try buildUrl(std.testing.allocator, "http://host", .collections, null, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("http://host/api/collections?name=", empty);
}

test "mailbox transfers arenas, coalesces endpoints and fences filter revisions" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var worker = try Worker.init(std.testing.allocator, threaded.io(), "https://host/");
    defer worker.deinit();
    var first: Update = .{ .revision = 0, .inventory_attempted = true, .inventory = try parseInventory(std.testing.allocator, inventory_fixture) };
    defer first.deinit();
    worker.publish(&first);
    try std.testing.expect(first.inventory == null);
    var failed: Update = .{ .revision = 0, .inventory_attempted = true, .inventory_error = "HTTP request failed", .collections_attempted = true, .collections = try parseCollections(std.testing.allocator, "[]") };
    defer failed.deinit();
    worker.publish(&failed);
    var taken = worker.takeUpdate().?;
    defer taken.deinit();
    try std.testing.expect(taken.inventory != null and taken.collections != null and taken.inventory_error != null);
    try std.testing.expect(worker.takeUpdate() == null);
    var pattern = [_]u8{ 's', '%' };
    try worker.setFilters(&pattern, null);
    pattern[0] = 'x';
    try std.testing.expectEqualStrings("s%", worker.id_pattern.?);
    try std.testing.expectEqual(@as(u64, 1), worker.currentRevision());
    worker.publish(&failed);
    try std.testing.expect(worker.takeUpdate() == null);
    var fresh: Update = .{ .revision = 1, .collections_attempted = true, .collections = try parseCollections(std.testing.allocator, "[]") };
    defer fresh.deinit();
    worker.publish(&fresh);
    try worker.setFilters(null, null);
    try std.testing.expect(worker.takeUpdate() == null);
}

const HttpHarness = struct {
    io: Io,
    server: Io.net.Server,
    tasks: Io.Group = .init,
    handlers: Io.Group = .init,
    stall_inventory: bool = false,
    inventory_seen: Io.Event = .unset,
    encoded_seen: std.atomic.Value(bool) = .init(false),

    fn serve(self: *HttpHarness) void {
        while (true) {
            const stream = self.server.accept(self.io) catch return;
            self.handlers.concurrent(self.io, handle, .{ self, stream }) catch {
                stream.close(self.io);
                return;
            };
        }
    }

    fn handle(self: *HttpHarness, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        var buffer: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < buffer.len) {
            var slices = [_][]u8{buffer[len..]};
            const read = stream.readWithControl(self.io, &slices, &.{}) catch return;
            const count = read.data_len;
            if (count == 0) return;
            len += count;
            if (std.mem.indexOf(u8, buffer[0..len], "\r\n\r\n") != null) break;
        }
        const request = buffer[0..len];
        const is_inventory = std.mem.startsWith(u8, request, "GET /api/inventory ");
        if (is_inventory) {
            self.inventory_seen.set(self.io);
            if (self.stall_inventory) {
                Io.sleep(self.io, .fromSeconds(30), .awake) catch {};
                return;
            }
        }
        const encoded = std.mem.startsWith(u8, request, "GET /api/collections?id=s%25&name=%25mz%5C_catalog.%25 ");
        if (encoded) self.encoded_seen.store(true, .release);
        const malformed = std.mem.startsWith(u8, request, "GET /api/collections?name=malformed ");
        const redirect = std.mem.startsWith(u8, request, "GET /api/collections?name=redirect ");
        const oversized = std.mem.startsWith(u8, request, "GET /api/collections?name=oversized ");
        const body = if (is_inventory) inventory_fixture else if (encoded) "[]" else if (malformed) "{" else "unavailable";
        var writer = stream.writer(self.io, &.{});
        if (redirect or oversized) {
            writer.interface.print("HTTP/1.1 {s}\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
                if (redirect) "302 Found" else "200 OK", if (oversized) @as(usize, max_response + 1) else 0,
            }) catch return;
            writer.interface.flush() catch {};
            return;
        }
        writer.interface.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            if (is_inventory or encoded or malformed) "200 OK" else "503 Unavailable", body.len, body,
        }) catch return;
        writer.interface.flush() catch {};
    }

    fn stop(self: *HttpHarness) void {
        self.tasks.cancel(self.io);
        self.handlers.cancel(self.io);
        self.server.deinit(self.io);
    }
};

fn awaitUpdate(worker: *Worker, kind: Kind, success: bool) !Update {
    const deadline = Io.Clock.awake.now(worker.io).addDuration(.fromSeconds(6));
    while (Io.Clock.awake.now(worker.io).nanoseconds < deadline.nanoseconds) {
        if (worker.takeUpdate()) |value| {
            var update = value;
            const matches = switch (kind) {
                .inventory => update.inventory_attempted and (update.inventory != null) == success,
                .collections => update.collections_attempted and (update.collections != null) == success,
            };
            if (matches) return update;
            update.deinit();
        }
        try Io.sleep(worker.io, .fromMilliseconds(10), .awake);
    }
    return error.TestTimeout;
}

test "local HTTP polling has independent results, encoded filters and owned updates" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var harness: HttpHarness = .{ .io = io, .server = try address.listen(io, .{}) };
    defer harness.stop();
    try harness.tasks.concurrent(io, HttpHarness.serve, .{&harness});
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{harness.server.socket.address.getPort()});
    var worker = try Worker.init(std.testing.allocator, io, url);
    var alive = true;
    defer if (alive) worker.deinit();
    try worker.start();
    try std.testing.expectError(error.AlreadyStarted, worker.start());
    var failed = try awaitUpdate(&worker, .collections, false);
    defer failed.deinit();
    try std.testing.expectEqualStrings("HTTP request failed", failed.collections_error.?);
    var inventory = try awaitUpdate(&worker, .inventory, true);
    defer inventory.deinit();
    try worker.setFilters("s%", "%mz\\_catalog.%");
    var filtered = try awaitUpdate(&worker, .collections, true);
    defer filtered.deinit();
    try std.testing.expectEqual(@as(u64, 1), filtered.revision);
    try std.testing.expect(harness.encoded_seen.load(.acquire));
    worker.deinit();
    alive = false;
    try std.testing.expectEqualStrings("primary", inventory.inventory.?.value.adapters[0].name);
}

test "stalled inventory does not block collections or bounded shutdown" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var harness: HttpHarness = .{ .io = io, .server = try address.listen(io, .{}), .stall_inventory = true };
    defer harness.stop();
    try harness.tasks.concurrent(io, HttpHarness.serve, .{&harness});
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{harness.server.socket.address.getPort()});
    var worker = try Worker.init(std.testing.allocator, io, url);
    var alive = true;
    defer if (alive) worker.deinit();
    try worker.setFilters("s%", "%mz\\_catalog.%");
    try worker.start();
    try harness.inventory_seen.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var update = try awaitUpdate(&worker, .collections, true);
    defer update.deinit();
    // A second controller must progress while this one's inventory is stalled.
    var healthy: HttpHarness = .{ .io = io, .server = try address.listen(io, .{}) };
    defer healthy.stop();
    try healthy.tasks.concurrent(io, HttpHarness.serve, .{&healthy});
    var healthy_buf: [128]u8 = undefined;
    const healthy_url = try std.fmt.bufPrint(&healthy_buf, "http://127.0.0.1:{d}", .{healthy.server.socket.address.getPort()});
    var other = try Worker.init(std.testing.allocator, io, healthy_url);
    defer other.deinit();
    try other.start();
    var other_update = try awaitUpdate(&other, .inventory, true);
    defer other_update.deinit();
    try std.testing.expectEqualStrings("primary", other_update.inventory.?.value.adapters[0].name);
    const before = Io.Clock.awake.now(io);
    worker.deinit();
    alive = false;
    const elapsed = before.durationTo(Io.Clock.awake.now(io));
    try std.testing.expect(elapsed.nanoseconds < 2 * std.time.ns_per_s);
}

test "HTTP deadline, malformed JSON, redirect and oversized response errors are generic" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var harness: HttpHarness = .{ .io = io, .server = try address.listen(io, .{}), .stall_inventory = true };
    defer harness.stop();
    try harness.tasks.concurrent(io, HttpHarness.serve, .{&harness});
    var url_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{harness.server.socket.address.getPort()});
    var worker = try Worker.init(std.testing.allocator, io, base);
    defer worker.deinit();
    for ([_][]const u8{ "malformed", "redirect", "oversized" }) |name| {
        const url = try buildUrl(std.testing.allocator, base, .collections, null, name);
        defer std.testing.allocator.free(url);
        var update = worker.fetch(.collections, url, 0);
        defer update.deinit();
        try std.testing.expect(update.collections == null and update.collections_error != null);
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, name, "malformed")) "invalid collections response" else "HTTP request failed", update.collections_error.?);
    }
    const url = try buildUrl(std.testing.allocator, base, .inventory, null, null);
    defer std.testing.allocator.free(url);
    const before = Io.Clock.awake.now(io);
    var timeout = worker.fetch(.inventory, url, 0);
    defer timeout.deinit();
    try std.testing.expect(timeout.inventory == null and timeout.inventory_error != null);
    try std.testing.expect(before.durationTo(Io.Clock.awake.now(io)).nanoseconds < 5 * std.time.ns_per_s);
}
