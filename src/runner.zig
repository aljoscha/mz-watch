const std = @import("std");
const pq = @import("pq.zig");

pub const Id = u64;
pub const Status = enum { connecting, ready, running, success, query_error, connection_error, timeout, busy, unavailable };

pub const Event = union(enum) {
    sample: struct { canary: Id, at_ms: i64, latency_ms: ?f64, winner: ?Id },
    endpoint: struct { canary: Id, endpoint: Id, status: Status, latency_ms: ?f64 = null, sqlstate: [5]u8 = @splat(' ') },
};

const Endpoint = struct { id: Id, conninfo: [:0]const u8 };
const CanaryConfig = struct { id: Id, sql: [:0]const u8, interval_ms: u32, timeout_ms: u32 };
const Command = union(enum) {
    endpoint: Endpoint,
    canary: CanaryConfig,
    remove_endpoint: Id,
    remove_canary: Id,
    pause: struct { id: Id, paused: bool },
};

/// One database thread multiplexes independent connections for every
/// (canary, endpoint) pair. The UI exchanges owned commands and value events,
/// never connections or pointers into the runner's mutable state.
pub const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    commands: std.ArrayList(Command) = .empty,
    events: std.ArrayList(Event) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Runner {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn start(self: *Runner) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Runner) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        for (self.commands.items) |cmd| self.freeCommand(cmd);
        self.commands.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn addEndpoint(self: *Runner, id: Id, conninfo: []const u8) !void {
        if (std.mem.indexOfScalar(u8, conninfo, 0) != null) return error.InvalidEndpoint;
        const owned = try self.allocator.dupeSentinel(u8, conninfo, 0);
        errdefer self.allocator.free(owned);
        try self.submit(.{ .endpoint = .{ .id = id, .conninfo = owned } });
    }

    pub fn addCanary(self: *Runner, id: Id, sql: []const u8, interval_ms: u32, timeout_ms: u32) !void {
        if (interval_ms == 0 or timeout_ms == 0 or std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidCanary;
        const owned = try self.allocator.dupeSentinel(u8, sql, 0);
        errdefer self.allocator.free(owned);
        try self.submit(.{ .canary = .{ .id = id, .sql = owned, .interval_ms = interval_ms, .timeout_ms = timeout_ms } });
    }

    pub fn removeEndpoint(self: *Runner, id: Id) !void {
        try self.submit(.{ .remove_endpoint = id });
    }

    pub fn removeCanary(self: *Runner, id: Id) !void {
        try self.submit(.{ .remove_canary = id });
    }

    pub fn pause(self: *Runner, id: Id, paused: bool) !void {
        try self.submit(.{ .pause = .{ .id = id, .paused = paused } });
    }

    pub fn takeEvents(self: *Runner) std.ArrayList(Event) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const events = self.events;
        self.events = .empty;
        return events;
    }

    fn submit(self: *Runner, cmd: Command) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failed.load(.acquire)) return error.RunnerFailed;
        try self.commands.append(self.allocator, cmd);
    }

    fn emit(self: *Runner, event: Event) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.events.append(self.allocator, event);
    }

    fn freeCommand(self: *Runner, cmd: Command) void {
        switch (cmd) {
            .endpoint => |endpoint| self.allocator.free(endpoint.conninfo),
            .canary => |canary| self.allocator.free(canary.sql),
            else => {},
        }
    }

    fn run(self: *Runner) void {
        var state: State = .{ .runner = self };
        defer state.deinit();
        state.loop() catch {
            self.failed.store(true, .release);
        };
    }
};

pub fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

const Race = struct {
    started_ns: i64,
    remaining: usize = 0,
    won: bool = false,
};

const Phase = enum { disconnected, connecting, ready, begin, query, rollback };
const Slot = struct {
    endpoint: Id,
    conn: ?*pq.Conn = null,
    phase: Phase = .disconnected,
    poll_events: i16 = std.c.POLL.OUT,
    deadline_ns: i64 = 0,
    reconnect_ns: i64 = 0,
    race: ?*Race = null,
    result_ok: bool = false,
    result_error: bool = false,
    sqlstate: [5]u8 = @splat(' '),

    fn close(self: *Slot) void {
        if (self.conn) |conn| pq.PQfinish(conn);
        self.conn = null;
        self.phase = .disconnected;
    }
};

const Canary = struct {
    config: CanaryConfig,
    slots: std.ArrayList(Slot) = .empty,
    paused: bool = false,
    next_ns: i64 = 0,
    dispatch_start: usize = 0,
    poll_start: usize = 0,
};

const State = struct {
    runner: *Runner,
    endpoints: std.ArrayList(Endpoint) = .empty,
    canaries: std.ArrayList(Canary) = .empty,
    polls: std.ArrayList(std.c.pollfd) = .empty,

    fn deinit(self: *State) void {
        for (self.canaries.items) |*canary| self.destroyCanary(canary);
        for (self.endpoints.items) |endpoint| self.runner.allocator.free(endpoint.conninfo);
        self.endpoints.deinit(self.runner.allocator);
        self.canaries.deinit(self.runner.allocator);
        self.polls.deinit(self.runner.allocator);
    }

    fn destroyCanary(self: *State, canary: *Canary) void {
        for (canary.slots.items) |*slot| {
            slot.close();
            // Removed configurations produce no additional observations.
            if (slot.race) |race| {
                race.remaining -= 1;
                if (race.remaining == 0) self.runner.allocator.destroy(race);
            }
        }
        canary.slots.deinit(self.runner.allocator);
        self.runner.allocator.free(canary.config.sql);
    }

    fn commands(self: *State) !void {
        const runner = self.runner;
        runner.mutex.lockUncancelable(runner.io);
        var pending = runner.commands;
        runner.commands = .empty;
        runner.mutex.unlock(runner.io);
        defer pending.deinit(runner.allocator);
        // Queue payloads are transferred only after the destination owns them.
        var done: usize = 0;
        defer for (pending.items[done..]) |cmd| runner.freeCommand(cmd);
        for (pending.items) |cmd| {
            switch (cmd) {
                .endpoint => |endpoint| {
                    try self.endpoints.append(runner.allocator, endpoint);
                    done += 1;
                    for (self.canaries.items) |*canary| try canary.slots.append(runner.allocator, .{ .endpoint = endpoint.id });
                    continue;
                },
                .canary => |config| {
                    try self.canaries.append(runner.allocator, .{ .config = config });
                    done += 1;
                    const canary = &self.canaries.items[self.canaries.items.len - 1];
                    for (self.endpoints.items) |endpoint| try canary.slots.append(runner.allocator, .{ .endpoint = endpoint.id });
                    continue;
                },
                .remove_canary => |id| {
                    for (self.canaries.items, 0..) |*canary, i| {
                        if (canary.config.id != id) continue;
                        self.destroyCanary(canary);
                        _ = self.canaries.orderedRemove(i);
                        break;
                    }
                },
                .remove_endpoint => |id| {
                    for (self.canaries.items) |*canary| {
                        for (canary.slots.items, 0..) |*slot, i| {
                            if (slot.endpoint != id) continue;
                            try self.complete(canary, slot, .unavailable, nowNs(runner.io));
                            slot.close();
                            _ = canary.slots.orderedRemove(i);
                            break;
                        }
                    }
                    for (self.endpoints.items, 0..) |endpoint, i| {
                        if (endpoint.id != id) continue;
                        runner.allocator.free(endpoint.conninfo);
                        _ = self.endpoints.orderedRemove(i);
                        break;
                    }
                },
                .pause => |pause| for (self.canaries.items) |*canary| {
                    if (canary.config.id == pause.id) canary.paused = pause.paused;
                },
            }
            done += 1;
        }
    }

    fn report(self: *State, canary: *Canary, slot: *Slot, status: Status, latency: ?f64) !void {
        try self.runner.emit(.{ .endpoint = .{ .canary = canary.config.id, .endpoint = slot.endpoint, .status = status, .latency_ms = latency, .sqlstate = slot.sqlstate } });
    }

    fn complete(self: *State, canary: *Canary, slot: *Slot, status: Status, now: i64) !void {
        const race = slot.race orelse return;
        const latency: f64 = @as(f64, @floatFromInt(now - race.started_ns)) / std.time.ns_per_ms;
        // A winner is published immediately, independently of losing requests.
        if (status == .success and !race.won) {
            try self.runner.emit(.{ .sample = .{ .canary = canary.config.id, .at_ms = @divFloor(now, std.time.ns_per_ms), .latency_ms = latency, .winner = slot.endpoint } });
            race.won = true;
        }
        try self.report(canary, slot, status, if (status == .success) latency else null);
        slot.race = null;
        race.remaining -= 1;
        if (race.remaining == 0) {
            defer self.runner.allocator.destroy(race);
            if (!race.won) try self.runner.emit(.{ .sample = .{ .canary = canary.config.id, .at_ms = @divFloor(now, std.time.ns_per_ms), .latency_ms = null, .winner = null } });
        }
    }

    fn disconnect(self: *State, canary: *Canary, slot: *Slot, status: Status, now: i64) !void {
        if (slot.race != null) {
            try self.complete(canary, slot, status, now);
        } else {
            try self.report(canary, slot, status, null);
        }
        slot.close();
        slot.reconnect_ns = now + std.time.ns_per_s;
    }

    fn send(self: *State, canary: *Canary, slot: *Slot, phase: Phase, sql: [:0]const u8, now: i64) !void {
        slot.result_ok = false;
        slot.result_error = false;
        slot.sqlstate = @splat(' ');
        slot.phase = phase;
        const conn = slot.conn.?;
        if (!pq.send(conn, sql) or (phase == .query and pq.PQsetSingleRowMode(conn) != 1)) {
            try self.disconnect(canary, slot, .connection_error, now);
        }
    }

    fn schedule(self: *State, canary: *Canary, now: i64) !void {
        if (canary.paused or canary.slots.items.len == 0 or now < canary.next_ns) return;
        // Missed schedule ticks are not replayed as a catch-up burst.
        canary.next_ns = now + @as(i64, canary.config.interval_ms) * std.time.ns_per_ms;
        var available: usize = 0;
        for (canary.slots.items) |*slot| {
            if (slot.phase == .ready) {
                available += 1;
            } else {
                try self.report(canary, slot, if (slot.race != null or slot.phase == .rollback) .busy else .unavailable, null);
            }
        }
        if (available == 0) {
            try self.runner.emit(.{ .sample = .{ .canary = canary.config.id, .at_ms = @divFloor(now, std.time.ns_per_ms), .latency_ms = null, .winner = null } });
            return;
        }
        const race = try self.runner.allocator.create(Race);
        race.* = .{ .started_ns = now, .remaining = available };
        // Attach every owner before a send failure can complete a race, and
        // before another fallible operation can interrupt scheduling.
        for (canary.slots.items) |*slot| if (slot.phase == .ready) {
            slot.race = race;
        };
        // Sequential socket operations cannot be simultaneous. Rotate priority
        // so near-ties do not permanently favor endpoint insertion order.
        const start = canary.dispatch_start % canary.slots.items.len;
        canary.dispatch_start = (start + 1) % canary.slots.items.len;
        for (0..canary.slots.items.len) |offset| {
            const slot = &canary.slots.items[(start + offset) % canary.slots.items.len];
            if (slot.race != race) continue;
            slot.deadline_ns = now + @as(i64, canary.config.timeout_ms) * std.time.ns_per_ms;
            try self.report(canary, slot, .running, null);
            try self.send(canary, slot, .begin, "BEGIN READ ONLY", now);
        }
    }

    fn step(self: *State, canary: *Canary, slot: *Slot, revents: i16, now: i64) !void {
        if (slot.phase == .disconnected) {
            if (now < slot.reconnect_ns) return;
            const endpoint = for (self.endpoints.items) |endpoint| {
                if (endpoint.id == slot.endpoint) break endpoint;
            } else unreachable;
            // libpq may resolve DNS here. This thread never holds a UI mutex
            // during connection establishment, queries or socket operations.
            slot.conn = pq.PQconnectStart(endpoint.conninfo.ptr);
            if (slot.conn == null) return error.OutOfMemory;
            _ = pq.PQsetNoticeProcessor(slot.conn.?, pq.discardNotice, null);
            slot.phase = .connecting;
            slot.poll_events = std.c.POLL.OUT;
            slot.deadline_ns = now + @as(i64, canary.config.timeout_ms) * std.time.ns_per_ms;
            try self.report(canary, slot, .connecting, null);
        }
        if (slot.phase != .ready and now >= slot.deadline_ns) {
            // Closing the socket bounds local work and prevents protocol reuse
            // after a timeout. It is not proof of server-side cancellation.
            return self.disconnect(canary, slot, .timeout, now);
        }
        const conn = slot.conn orelse return;
        if (slot.phase == .connecting) {
            if (revents == 0 and pq.PQsocket(conn) >= 0) return;
            switch (pq.PQconnectPoll(conn)) {
                pq.poll_reading => slot.poll_events = std.c.POLL.IN,
                pq.poll_writing => slot.poll_events = std.c.POLL.OUT,
                pq.poll_ok => {
                    if (pq.PQsetnonblocking(conn, 1) != 0) return self.disconnect(canary, slot, .connection_error, now);
                    slot.phase = .ready;
                    try self.report(canary, slot, .ready, null);
                },
                else => return self.disconnect(canary, slot, .connection_error, now),
            }
            return;
        }
        if (slot.phase == .ready) {
            if (revents != 0 and (pq.PQconsumeInput(conn) == 0 or pq.PQstatus(conn) != pq.connection_ok)) try self.disconnect(canary, slot, .connection_error, now);
            return;
        }
        if (pq.PQflush(conn) < 0 or (revents != 0 and pq.PQconsumeInput(conn) == 0)) return self.disconnect(canary, slot, .connection_error, now);
        // Bound result processing so a large result cannot starve other sockets.
        for (0..256) |_| {
            if (pq.PQisBusy(conn) != 0) return;
            if (pq.PQgetResult(conn)) |result| {
                defer pq.PQclear(result);
                switch (pq.PQresultStatus(result)) {
                    pq.command_ok, pq.tuples_ok => slot.result_ok = true,
                    pq.single_tuple => {},
                    // COPY would require its own protocol and is not a canary.
                    3, 4, 8 => return self.disconnect(canary, slot, .query_error, now),
                    else => {
                        slot.result_error = true;
                        if (pq.PQresultErrorField(result, 'C')) |code| {
                            const value = std.mem.span(code);
                            if (value.len == 5) @memcpy(&slot.sqlstate, value);
                        }
                    },
                }
            } else {
                const completed_ns = nowNs(self.runner.io);
                const ok = slot.result_ok and !slot.result_error;
                switch (slot.phase) {
                    .begin => {
                        if (!ok) return self.disconnect(canary, slot, .query_error, completed_ns);
                        try self.send(canary, slot, .query, canary.config.sql, completed_ns);
                    },
                    .query => {
                        try self.complete(canary, slot, if (ok) .success else .query_error, completed_ns);
                        try self.send(canary, slot, .rollback, "ROLLBACK", completed_ns);
                    },
                    .rollback => {
                        if (!ok) return self.disconnect(canary, slot, .query_error, completed_ns);
                        slot.phase = .ready;
                    },
                    else => unreachable,
                }
                return;
            }
        }
    }

    fn loop(self: *State) !void {
        const runner = self.runner;
        while (!runner.stopping.load(.acquire)) {
            try self.commands();
            self.polls.clearRetainingCapacity();
            for (self.canaries.items) |*canary| {
                for (canary.slots.items) |slot| {
                    const events = if (slot.phase == .connecting) slot.poll_events else std.c.POLL.IN | if (slot.phase != .ready and slot.conn != null and pq.PQflush(slot.conn.?) == 1) @as(i16, std.c.POLL.OUT) else @as(i16, 0);
                    try self.polls.append(runner.allocator, .{ .fd = if (slot.conn) |conn| pq.PQsocket(conn) else -1, .events = events, .revents = 0 });
                }
            }
            // Poll also bounds command and shutdown latency when sockets are idle.
            _ = std.c.poll(self.polls.items.ptr, @intCast(self.polls.items.len), 2);
            var index: usize = 0;
            for (self.canaries.items) |*canary| {
                const count = canary.slots.items.len;
                if (count > 0) {
                    const start = canary.poll_start % count;
                    canary.poll_start = (start + 1) % count;
                    // poll reports readiness, not arrival order across sockets.
                    // Rotate servicing without delaying publication of a winner.
                    for (0..count) |offset| {
                        const slot_index = (start + offset) % count;
                        try self.step(canary, &canary.slots.items[slot_index], self.polls.items[index + slot_index].revents, nowNs(runner.io));
                    }
                }
                index += count;
                try self.schedule(canary, nowNs(runner.io));
            }
        }
    }
};

test "runner rejects invalid schedules and embedded NUL SQL" {
    var io: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io.deinit();
    var runner = Runner.init(std.testing.allocator, io.io());
    defer runner.deinit();
    try std.testing.expectError(error.InvalidCanary, runner.addCanary(1, "SELECT 1", 0, 100));
    try std.testing.expectError(error.InvalidCanary, runner.addCanary(1, "SELECT 1", 100, 0));
    try std.testing.expectError(error.InvalidCanary, runner.addCanary(1, "SELECT 1\x00; DELETE FROM t", 100, 100));
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    var runner = Runner.init(allocator, std.testing.io);
    defer runner.deinit();
    var state: State = .{ .runner = &runner };
    defer state.deinit();
    try runner.addEndpoint(1, "hostaddr=127.0.0.1");
    try runner.addCanary(2, "SELECT 1", 100, 100);
    try state.commands();
    // No socket I/O is needed to exercise failure while emitting an
    // unavailable attempt, or transferring ownership of queued configs.
    try state.schedule(&state.canaries.items[0], 0);
}

test "allocation failures release queued configurations and unavailable attempts" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}
