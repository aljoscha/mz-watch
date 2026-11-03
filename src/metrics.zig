const std = @import("std");

/// Inclusive upper bounds in milliseconds. Bin 11 contains larger latencies.
/// Bin 12 contains failures without a measured latency.
pub const histogram_bounds_ms: [11]f64 = .{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 5000 };

pub const Series = enum { success, failure };
/// Failures without a latency count against availability, not latency means.
pub const Outcome = union(enum) { success: f64, failure: ?f64 };

/// Allocation-free statistics for the current second and preceding 59 seconds.
/// Measured durations must be finite and nonnegative. Lifetime counters include
/// every record, even one too old to retain in the rolling window.
pub const Stats = struct {
    successes: u64 = 0,
    failures: u64 = 0,
    buckets: [60]Bucket = @splat(.{}),

    const Bucket = struct {
        second: ?i64 = null,
        counts: [2]u64 = @splat(0),
        sums: [2]f64 = @splat(0),
        histograms: [2][13]u64 = @splat(@splat(0)),
    };

    pub fn record(self: *Stats, at_ms: i64, outcome: Outcome) void {
        const latency = switch (outcome) {
            .success => |duration| blk: {
                self.successes += 1;
                break :blk duration;
            },
            .failure => |duration| blk: {
                self.failures += 1;
                break :blk duration;
            },
        };
        const kind: Series = if (outcome == .success) .success else .failure;
        const channel = @backingInt(kind);
        const second = @divFloor(at_ms, 1000);
        const bucket = &self.buckets[index(second)];
        if (bucket.second) |stored_second| {
            // A delayed observation must not evict a newer second in this slot.
            if (stored_second > second) return;
        }
        if (bucket.second != second) bucket.* = .{ .second = second };
        const duration = latency orelse {
            bucket.histograms[channel][12] += 1;
            return;
        };
        bucket.counts[channel] += 1;
        bucket.sums[channel] += duration;
        var bin: usize = 0;
        while (bin < histogram_bounds_ms.len and duration > histogram_bounds_ms[bin]) : (bin += 1) {}
        bucket.histograms[channel][bin] += 1;
    }

    pub fn histogram(self: *const Stats, now_ms: i64, kind: Series) [13]u64 {
        var result: [13]u64 = @splat(0);
        const now_second = @divFloor(now_ms, 1000);
        for (self.buckets) |bucket| {
            if (!inWindow(bucket.second, now_second)) continue;
            for (&result, bucket.histograms[@backingInt(kind)]) |*count, value| count.* += value;
        }
        return result;
    }

    pub fn mean(self: *const Stats, now_ms: i64, kind: Series) ?f64 {
        var sum: f64 = 0;
        var count: u64 = 0;
        const now_second = @divFloor(now_ms, 1000);
        for (self.buckets) |bucket| {
            if (!inWindow(bucket.second, now_second)) continue;
            sum += bucket.sums[@backingInt(kind)];
            count += bucket.counts[@backingInt(kind)];
        }
        return if (count == 0) null else sum / @as(f64, @floatFromInt(count));
    }

    /// Oldest second first, current second last. Each outcome has independent gaps.
    pub fn series(self: *const Stats, now_ms: i64, kind: Series) [60]?f64 {
        var result: [60]?f64 = @splat(null);
        const now_second = @divFloor(now_ms, 1000);
        for (&result, 0..) |*value, offset| {
            const second = now_second - 59 + @as(i64, @intCast(offset));
            const bucket = self.buckets[index(second)];
            const count = bucket.counts[@backingInt(kind)];
            if (bucket.second == second and count != 0) value.* = bucket.sums[@backingInt(kind)] / @as(f64, @floatFromInt(count));
        }
        return result;
    }

    /// Counts of failures without a duration, oldest second first.
    pub fn untimedFailures(self: *const Stats, now_ms: i64) [60]u64 {
        var result: [60]u64 = @splat(0);
        const now_second = @divFloor(now_ms, 1000);
        for (&result, 0..) |*value, offset| {
            const second = now_second - 59 + @as(i64, @intCast(offset));
            const bucket = self.buckets[index(second)];
            if (bucket.second == second) value.* = bucket.histograms[@backingInt(Series.failure)][12];
        }
        return result;
    }

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
    fn index(second: i64) usize {
        return @intCast(@mod(second, 60));
    }
    fn inWindow(second: ?i64, now_second: i64) bool {
        const value = second orelse return false;
        return value <= now_second and value >= now_second - 59;
    }
};

test "window expiry and chronological gaps without new observations" {
    var stats: Stats = .{};
    stats.record(999, .{ .success = 10 });
    stats.record(1000, .{ .failure = 50 });
    stats.record(2500, .{ .success = 20 });
    stats.record(2999, .{ .success = 40 });

    const series = stats.series(59999, .success);
    try std.testing.expectEqual(@as(?f64, 10), series[0]);
    try std.testing.expectEqual(@as(?f64, null), series[1]);
    try std.testing.expectEqual(@as(?f64, 30), series[2]);
    for (series[3..]) |value| try std.testing.expectEqual(@as(?f64, null), value);
    try std.testing.expectEqual(@as(?f64, 30), stats.mean(60000, .success));
    try std.testing.expectEqual(@as(?f64, null), stats.series(60000, .success)[0]);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(62000, .success));
    try std.testing.expectEqual(@as([13]u64, @splat(0)), stats.histogram(62000, .success));
    for (stats.series(62000, .success)) |value| try std.testing.expectEqual(@as(?f64, null), value);
}

test "mean weights observations rather than seconds without sample truncation" {
    var stats: Stats = .{};
    for (0..10000) |_| stats.record(0, .{ .success = 2 });
    stats.record(1000, .{ .success = 10002 });
    try std.testing.expectEqual(@as(?f64, 30002.0 / 10001.0), stats.mean(1000, .success));
    try std.testing.expectEqual(@as(?f64, 2), stats.series(1000, .success)[58]);
    try std.testing.expectEqual(@as(?f64, 10002), stats.series(1000, .success)[59]);
    try std.testing.expectEqual(@as(u64, 10000), stats.histogram(1000, .success)[1]);
}

test "both histogram series retain inclusive boundaries and overflow" {
    for (std.enums.values(Series)) |kind| {
        var stats: Stats = .{};
        stats.record(0, if (kind == .success) .{ .success = 0 } else .{ .failure = 0 });
        for (histogram_bounds_ms) |bound| {
            stats.record(0, if (kind == .success) .{ .success = bound } else .{ .failure = bound });
            stats.record(0, if (kind == .success) .{ .success = bound + 0.5 } else .{ .failure = bound + 0.5 });
        }
        const expected: [13]u64 = .{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0 };
        try std.testing.expectEqual(expected, stats.histogram(0, kind));
    }
}

test "success summaries exclude failure durations while lifetime counts survive expiry" {
    var stats: Stats = .{};
    stats.record(0, .{ .failure = 50 });
    try std.testing.expectEqual(@as(?f64, null), stats.mean(0, .success));
    try std.testing.expectEqual(@as([13]u64, @splat(0)), stats.histogram(0, .success));
    stats.record(0, .{ .success = 0 });
    stats.record(0, .{ .success = 10 });
    stats.record(0, .{ .failure = 50 });
    try std.testing.expectEqual(@as(?f64, 5), stats.mean(0, .success));
    try std.testing.expectEqual(@as(?f64, 5), stats.series(0, .success)[59]);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(60000, .success));
    try std.testing.expectEqual(@as(u64, 2), stats.successes);
    try std.testing.expectEqual(@as(u64, 2), stats.failures);
    stats.reset();
    try std.testing.expectEqual(@as(u64, 0), stats.successes);
    try std.testing.expectEqual(@as(u64, 0), stats.failures);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(0, .success));
}

test "slot reuse preserves newer observations and handles negative timestamps" {
    var stats: Stats = .{};
    stats.record(-1, .{ .success = 2 });
    try std.testing.expectEqual(@as(?f64, 2), stats.series(0, .success)[58]);
    stats.record(59000, .{ .success = 4 });
    stats.record(-1, .{ .success = 8 });
    stats.record(60000, .{ .success = 6 });
    try std.testing.expectEqual(@as(?f64, 5), stats.mean(60000, .success));
    try std.testing.expectEqual(@as(?f64, 4), stats.series(60000, .success)[58]);
    try std.testing.expectEqual(@as(?f64, 6), stats.series(60000, .success)[59]);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(0, .success));
    try std.testing.expectEqual(@as(u64, 4), stats.successes);
}

test "timed outcomes have independent histograms, weighted means, gaps and expiry" {
    var stats: Stats = .{};
    stats.record(0, .{ .success = 10 });
    stats.record(0, .{ .failure = 500 });
    stats.record(500, .{ .failure = 100 });
    stats.record(1000, .{ .failure = 20 });
    stats.record(2000, .{ .failure = null });
    try std.testing.expectEqual(@as(?f64, 10), stats.mean(2000, .success));
    try std.testing.expectEqual(@as(?f64, 620.0 / 3.0), stats.mean(2000, .failure));
    const successes = stats.histogram(2000, .success);
    const failures = stats.histogram(2000, .failure);
    try std.testing.expectEqual(@as(u64, 1), successes[3]);
    try std.testing.expectEqual(@as(u64, 1), failures[4]);
    try std.testing.expectEqual(@as(u64, 1), failures[6]);
    try std.testing.expectEqual(@as(u64, 1), failures[8]);
    try std.testing.expectEqual(@as(?f64, 300), stats.series(2000, .failure)[57]);
    try std.testing.expectEqual(@as(?f64, 20), stats.series(2000, .failure)[58]);
    try std.testing.expectEqual(@as(?f64, null), stats.series(2000, .success)[58]);
    try std.testing.expectEqual(@as(?f64, null), stats.series(2000, .failure)[59]);
    try std.testing.expectEqual(@as(u64, 1), failures[12]);
    try std.testing.expectEqual(@as(u64, 1), stats.histogram(61000, .failure)[12]);
    for (std.enums.values(Series)) |kind| {
        try std.testing.expectEqual(@as(?f64, null), stats.mean(62000, kind));
        try std.testing.expectEqual(@as([13]u64, @splat(0)), stats.histogram(62000, kind));
        for (stats.series(62000, kind)) |value| try std.testing.expectEqual(@as(?f64, null), value);
    }
    try std.testing.expectEqual(@as(u64, 1), stats.successes);
    try std.testing.expectEqual(@as(u64, 4), stats.failures);
    stats.reset();
    try std.testing.expectEqual(@as(u64, 0), stats.failures);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(2000, .failure));
}

test "untimed failures have independent counts, gaps and expiry" {
    var stats: Stats = .{};
    stats.record(-1, .{ .failure = null });
    stats.record(0, .{ .success = 10 });
    stats.record(0, .{ .failure = 20 });
    stats.record(1000, .{ .failure = null });
    stats.record(1999, .{ .failure = null });
    const counts = stats.untimedFailures(2000);
    try std.testing.expectEqual(@as(u64, 1), counts[56]);
    try std.testing.expectEqual(@as(u64, 0), counts[57]);
    try std.testing.expectEqual(@as(u64, 2), counts[58]);
    try std.testing.expectEqual(@as(u64, 0), counts[59]);
    try std.testing.expectEqual(@as(u64, 2), stats.untimedFailures(60000)[0]);
    try std.testing.expectEqual(@as([60]u64, @splat(0)), stats.untimedFailures(61000));
    stats.record(61000, .{ .failure = null });
    stats.record(1000, .{ .failure = null });
    try std.testing.expectEqual(@as(u64, 1), stats.untimedFailures(61000)[59]);
    try std.testing.expectEqual(@as(u64, 0), stats.untimedFailures(1000)[59]);
    stats.reset();
    try std.testing.expectEqual(@as([60]u64, @splat(0)), stats.untimedFailures(61000));
}
