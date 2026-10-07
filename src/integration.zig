const std = @import("std");
const api = @import("runner.zig");
const pq = @import("pq.zig");

const fast: api.Id = 1;
const slow: api.Id = 2;
const canary: api.Id = 10;
const deadline_ms = 20_000;

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn expect(ok: bool, promise: []const u8) !void {
    if (!ok) {
        std.debug.print("FAIL: {s}\n", .{promise});
        return error.IntegrationFailed;
    }
}

const Harness = struct {
    runner: api.Runner,
    allocator: std.mem.Allocator,
    io: std.Io,
    events: std.ArrayList(api.Event) = .empty,

    fn init(a: std.mem.Allocator, io: std.Io) Harness {
        return .{ .runner = api.Runner.init(a, io), .allocator = a, .io = io };
    }

    fn deinit(self: *Harness) void {
        self.runner.deinit();
        self.events.deinit(self.allocator);
    }

    fn collect(self: *Harness) !void {
        var batch = self.runner.takeEvents();
        defer batch.deinit(self.allocator);
        try self.events.appendSlice(self.allocator, batch.items);
    }

    fn tick(self: *Harness) !void {
        try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
        try self.collect();
    }

    fn deadline(self: *Harness) i64 {
        return nowNs(self.io) + deadline_ms * std.time.ns_per_ms;
    }

    fn statusIndex(self: *Harness, id: api.Id, status: api.Status) ?usize {
        for (self.events.items, 0..) |event, i| switch (event) {
            .endpoint => |e| if (e.canary == canary and e.endpoint == id and e.status == status) return i,
            else => {},
        };
        return null;
    }

    fn waitStatus(self: *Harness, id: api.Id, status: api.Status) !usize {
        const until = self.deadline();
        while (nowNs(self.io) < until) {
            try self.collect();
            if (self.statusIndex(id, status)) |index| return index;
            try self.tick();
        }
        std.debug.print("Missing endpoint {d} status {s}\n", .{ id, @tagName(status) });
        return error.DeadlineExceeded;
    }

    fn waitSample(self: *Harness, winner: ?api.Id) !usize {
        const until = self.deadline();
        while (nowNs(self.io) < until) {
            try self.collect();
            for (self.events.items, 0..) |event, i| switch (event) {
                .sample => |s| if (s.canary == canary) {
                    try expect(s.winner == winner, "sample has the expected winner");
                    try expect((s.latency_ms != null) == (winner != null), "only successful samples carry latency");
                    if (s.latency_ms) |latency| try expect(std.math.isFinite(latency) and latency >= 0, "measured latency is finite and nonnegative");
                    try expect(s.at_ms > 0 and s.at_ms <= @divFloor(nowNs(self.io), std.time.ns_per_ms), "sample timestamp is an actual observation time");
                    return i;
                },
                else => {},
            };
            try self.tick();
        }
        return error.DeadlineExceeded;
    }

    fn quiet(self: *Harness, duration_ms: i64) !void {
        const until = nowNs(self.io) + duration_ms * std.time.ns_per_ms;
        while (nowNs(self.io) < until) try self.tick();
    }

    fn samples(self: *Harness) usize {
        var count: usize = 0;
        for (self.events.items) |event| switch (event) {
            .sample => count += 1,
            else => {},
        };
        return count;
    }

    fn prepare(self: *Harness, conninfo: []const u8, sql: []const u8, interval: u32, timeout: u32, both: bool) !void {
        const a = self.allocator;
        const fast_conn = try std.fmt.allocPrint(a, "{s} application_name=fast", .{conninfo});
        defer a.free(fast_conn);
        const slow_conn = try std.fmt.allocPrint(a, "{s} application_name=slow", .{conninfo});
        defer a.free(slow_conn);
        try self.runner.addEndpoint(fast, fast_conn);
        if (both) try self.runner.addEndpoint(slow, slow_conn);
        try self.runner.addCanary(canary, sql, interval, timeout);
        try self.runner.pause(canary, true);
        try self.runner.start();
        _ = try self.waitStatus(fast, .ready);
        if (both) _ = try self.waitStatus(slow, .ready);
        self.events.clearRetainingCapacity();
        try self.runner.pause(canary, false);
    }
};

// An independent server-side observer proves mutations happen during actual
// queries, rather than assuming that a sleep on the harness means work began.
extern "pq" fn PQconnectdb([*:0]const u8) ?*pq.Conn;
extern "pq" fn PQexec(*pq.Conn, [*:0]const u8) ?*pq.Result;
extern "pq" fn PQgetvalue(*const pq.Result, c_int, c_int) [*:0]const u8;

const Observer = struct {
    conn: *pq.Conn,

    fn init(a: std.mem.Allocator, conninfo: []const u8) !Observer {
        const config = try std.fmt.allocPrintSentinel(a, "{s} application_name=mz_watch_observer connect_timeout=5 options='-c statement_timeout=3000'", .{conninfo}, 0);
        defer a.free(config);
        const conn = PQconnectdb(config.ptr) orelse return error.ObserverConnectionFailed;
        errdefer pq.PQfinish(conn);
        try expect(pq.PQstatus(conn) == pq.connection_ok, "observer connects");
        return .{ .conn = conn };
    }

    fn boolean(self: Observer, sql: [:0]const u8) !bool {
        const result = PQexec(self.conn, sql.ptr) orelse return error.ObserverQueryFailed;
        defer pq.PQclear(result);
        try expect(pq.PQresultStatus(result) == pq.tuples_ok, "observer SQL succeeds");
        return std.mem.eql(u8, std.mem.span(PQgetvalue(result, 0, 0)), "t");
    }

    fn waitFor(self: Observer, h: *Harness, sql: [:0]const u8) !void {
        const until = h.deadline();
        while (nowNs(h.io) < until) {
            if (try self.boolean(sql)) return;
            try h.tick();
        }
        return error.InFlightDeadlineExceeded;
    }
};

fn firstSuccess(a: std.mem.Allocator, io: std.Io, conninfo: []const u8) !void {
    var h = Harness.init(a, io);
    defer h.deinit();
    try h.prepare(conninfo, "SELECT pg_sleep(CASE current_setting('application_name') WHEN 'fast' THEN 0.1 ELSE 3 END)", 1_000, 10_000, true);
    const sample = try h.waitSample(fast);
    try expect(h.statusIndex(slow, .success) == null, "winner is observable while the slow loser is still outstanding");
    try h.runner.pause(canary, true);
    const loser = try h.waitStatus(slow, .success);
    try expect(sample < loser, "winner publication precedes losing completion");
    const count = h.samples();
    try h.quiet(1_000);
    try expect(h.samples() == count and count == 1, "pause permits in-flight completion without another sample");
    std.debug.print("PASS: early winner, losing visibility, in-flight pause\n", .{});
}

fn errors(a: std.mem.Allocator, io: std.Io, conninfo: []const u8, observer: Observer) !void {
    {
        var h = Harness.init(a, io);
        defer h.deinit();
        try h.prepare(conninfo, "SELECT 1 / CASE current_setting('application_name') WHEN 'fast' THEN 0 ELSE 1 END, pg_sleep(CASE current_setting('application_name') WHEN 'slow' THEN 1 ELSE 0 END)", 60_000, 10_000, true);
        const failed = try h.waitStatus(fast, .query_error);
        const sample = try h.waitSample(slow);
        try expect(failed < sample, "an earlier error never wins over a later success");
        try expect(std.mem.eql(u8, &h.events.items[failed].endpoint.sqlstate, "22012"), "real division error SQLSTATE is preserved");
    }
    const cases = [_]struct { sql: []const u8, state: []const u8 }{
        .{ .sql = "SELECT 1 / (length(current_setting('application_name')) - length(current_setting('application_name')))", .state = "22012" },
        .{ .sql = "INSERT INTO mz_watch_integration_writes VALUES (1)", .state = "25006" },
        .{ .sql = "SELECT 1; SELECT 2", .state = "42601" },
    };
    for (cases) |case| {
        var h = Harness.init(a, io);
        defer h.deinit();
        try h.prepare(conninfo, case.sql, 60_000, 10_000, true);
        const f = try h.waitStatus(fast, .query_error);
        const s = try h.waitStatus(slow, .query_error);
        const sample = try h.waitSample(null);
        try expect(sample > f and sample > s, "all-failed sample follows both failures");
        try expect(std.mem.eql(u8, &h.events.items[f].endpoint.sqlstate, case.state) and std.mem.eql(u8, &h.events.items[s].endpoint.sqlstate, case.state), "both endpoints report the expected SQLSTATE");
        try expect(h.statusIndex(fast, .success) == null and h.statusIndex(slow, .success) == null, "rejected SQL produces no success");
    }
    try expect(try observer.boolean("SELECT count(*) = 0 FROM mz_watch_integration_writes"), "read-only canaries leave the disposable table unchanged");
    std.debug.print("PASS: errors never win, all-failed sample, read-only and single-statement enforcement\n", .{});
}

fn timeouts(a: std.mem.Allocator, io: std.Io, conninfo: []const u8) !void {
    var h = Harness.init(a, io);
    defer h.deinit();
    try h.prepare(conninfo, "SELECT pg_sleep(6)", 200, 1_500, true);
    const bf = try h.waitStatus(fast, .busy);
    const bs = try h.waitStatus(slow, .busy);
    // Pause after missed ticks, while both requests are outstanding. A backlog
    // would still execute after those requests time out and connections recover.
    try h.runner.pause(canary, true);
    const tf = try h.waitStatus(fast, .timeout);
    const ts = try h.waitStatus(slow, .timeout);
    try expect(bf < tf and bs < ts, "busy ticks are skipped before explicit request deadlines");
    _ = try h.waitSample(null);
    h.events.clearRetainingCapacity();
    _ = try h.waitStatus(fast, .ready);
    _ = try h.waitStatus(slow, .ready);
    try h.quiet(2_000);
    try expect(h.samples() == 0 and h.statusIndex(fast, .busy) == null and h.statusIndex(slow, .busy) == null and h.statusIndex(fast, .timeout) == null and h.statusIndex(slow, .timeout) == null, "busy ticks create no queued work after recovery");
    std.debug.print("PASS: explicit timeout, busy skipping, no backlog\n", .{});
}

fn skippedSchedules(a: std.mem.Allocator, io: std.Io, conninfo: []const u8) !void {
    var h = Harness.init(a, io);
    defer h.deinit();
    const interval = 2_000;
    try h.prepare(conninfo, "SELECT pg_sleep(3)", interval, 10_000, true);
    const until = h.deadline();
    var cursor: usize = 0;
    var skipped_at: ?i64 = null;
    var successes: usize = 0;
    while (nowNs(io) < until) {
        try h.tick();
        for (h.events.items[cursor..]) |event| switch (event) {
            .sample => |s| {
                if (s.winner == null) {
                    if (successes == 0) skipped_at = s.at_ms;
                    continue;
                }
                successes += 1;
                if (successes != 2) continue;
                try expect(skipped_at != null, "a schedule tick was skipped while all endpoints were busy");
                try expect(s.latency_ms != null, "successful sample carries the measured duration");
                // A completed request must not release a queued missed tick.
                // Infer the next race's start from public timestamp and latency,
                // allowing only rounding of the integer millisecond timestamp.
                const next_start = @as(f64, @floatFromInt(s.at_ms)) - s.latency_ms.?;
                try expect(next_start + 2 >= @as(f64, @floatFromInt(skipped_at.? + interval)), "missed ticks are not replayed immediately after completion");
                std.debug.print("PASS: busy schedules do not replay as a catch-up burst\n", .{});
                return;
            },
            else => {},
        };
        cursor = h.events.items.len;
    }
    return error.DeadlineExceeded;
}

fn lifecycle(a: std.mem.Allocator, io: std.Io, conninfo: []const u8, observer: Observer) !void {
    var h = Harness.init(a, io);
    var live = true;
    defer if (live) h.deinit();
    try h.prepare(conninfo, "SELECT pg_sleep(30) /* mz_watch_inflight */", 200, 60_000, false);
    try observer.waitFor(&h, "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'fast' AND state = 'active' AND query LIKE '%mz_watch_inflight%')");
    try h.runner.pause(canary, true);
    const config = try std.fmt.allocPrint(a, "{s} application_name=slow", .{conninfo});
    defer a.free(config);
    try h.runner.addEndpoint(slow, config);
    _ = try h.waitStatus(slow, .ready);
    try h.runner.removeEndpoint(fast);
    _ = try h.waitStatus(fast, .unavailable);
    _ = try h.waitSample(null);
    h.events.clearRetainingCapacity();
    try h.runner.pause(canary, false);
    // The observer must see the added endpoint, not the removed endpoint's
    // server-side sleep. Socket close does not promise server cancellation.
    try observer.waitFor(&h, "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'slow' AND state = 'active' AND query LIKE '%mz_watch_inflight%')");
    try h.runner.pause(canary, true);
    try h.runner.removeCanary(canary);
    // FIFO command processing is observed through a replacement canary's ready
    // event. After that barrier the removed configuration must stay silent.
    try h.runner.addCanary(11, "SELECT pg_sleep(30) /* mz_watch_shutdown */", 200, 60_000);
    const ready_until = h.deadline();
    var ready = false;
    while (!ready) {
        try expect(nowNs(io) < ready_until, "replacement canary becomes ready");
        try h.tick();
        for (h.events.items) |event| switch (event) {
            .endpoint => |e| if (e.canary == 11 and e.status == .ready) {
                ready = true;
            },
            else => {},
        };
    }
    h.events.clearRetainingCapacity();
    try h.quiet(1_000);
    try observer.waitFor(&h, "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'slow' AND state = 'active' AND query LIKE '%mz_watch_shutdown%')");
    for (h.events.items) |event| {
        const id = switch (event) {
            .sample => |s| s.canary,
            .endpoint => |e| e.canary,
        };
        try expect(id != canary, "removed in-flight canary emits no further observations");
        switch (event) {
            .endpoint => |e| try expect(e.endpoint != fast, "removed endpoint stays absent"),
            else => {},
        }
    }
    const started = nowNs(io);
    h.deinit();
    live = false;
    try expect(nowNs(io) - started < 5 * std.time.ns_per_s, "shutdown does not wait for the 30-second query");
    std.debug.print("PASS: live endpoint add/remove, canary removal, bounded in-flight shutdown\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const conninfo = init.environ_map.get("MZ_WATCH_TEST_CONNINFO") orelse {
        std.debug.print("Set MZ_WATCH_TEST_CONNINFO to a disposable PostgreSQL database (scripts/integration.sh does this).\n", .{});
        return error.MissingTestConnection;
    };
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const a = allocator.allocator();
    const observer = try Observer.init(a, conninfo);
    defer pq.PQfinish(observer.conn);
    try firstSuccess(a, init.io, conninfo);
    try errors(a, init.io, conninfo, observer);
    try timeouts(a, init.io, conninfo);
    try skippedSchedules(a, init.io, conninfo);
    try lifecycle(a, init.io, conninfo, observer);
    std.debug.print("PASS: PostgreSQL integration contracts\n", .{});
}
