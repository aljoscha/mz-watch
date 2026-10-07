const std = @import("std");

/// Inclusive upper bounds in milliseconds. Bin 11 contains larger latencies.
pub const histogram_bounds_ms: [11]f64 = .{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 5000 };

/// Allocation-free statistics for the current second and preceding 59 seconds.
/// Timestamps use floor-rounded seconds, including timestamps before epoch zero.
/// Success latencies must be finite and nonnegative. Lifetime counters include
/// every record, even one too old to retain in the rolling window.
pub const Stats = struct {
    successes: u64 = 0,
    failures: u64 = 0,
    buckets: [60]Bucket = @splat(.{}),

    const Bucket = struct {
        second: ?i64 = null,
        count: u64 = 0,
        sum: f64 = 0,
        histogram: [12]u64 = @splat(0),
    };

    pub fn record(self: *Stats, at_ms: i64, latency_ms: ?f64) void {
        const latency = latency_ms orelse {
            self.failures += 1;
            return;
        };
        self.successes += 1;
        const second = @divFloor(at_ms, 1000);
        const bucket = &self.buckets[index(second)];
        if (bucket.second) |stored_second| {
            // A delayed observation must not evict a newer second in this slot.
            if (stored_second > second) return;
        }
        if (bucket.second != second) bucket.* = .{ .second = second };
        bucket.count += 1;
        bucket.sum += latency;
        var bin: usize = 0;
        while (bin < histogram_bounds_ms.len and latency > histogram_bounds_ms[bin]) : (bin += 1) {}
        bucket.histogram[bin] += 1;
    }

    pub fn histogram(self: *const Stats, now_ms: i64) [12]u64 {
        var result: [12]u64 = @splat(0);
        const now_second = @divFloor(now_ms, 1000);
        for (self.buckets) |bucket| {
            if (!inWindow(bucket.second, now_second)) continue;
            for (&result, bucket.histogram) |*count, value| count.* += value;
        }
        return result;
    }

    pub fn mean(self: *const Stats, now_ms: i64) ?f64 {
        var sum: f64 = 0;
        var count: u64 = 0;
        const now_second = @divFloor(now_ms, 1000);
        for (self.buckets) |bucket| {
            if (!inWindow(bucket.second, now_second)) continue;
            sum += bucket.sum;
            count += bucket.count;
        }
        return if (count == 0) null else sum / @as(f64, @floatFromInt(count));
    }

    /// Oldest second first, current second last. Failures do not contribute.
    pub fn series(self: *const Stats, now_ms: i64) [60]?f64 {
        var result: [60]?f64 = @splat(null);
        const now_second = @divFloor(now_ms, 1000);
        for (&result, 0..) |*value, offset| {
            const second = now_second - 59 + @as(i64, @intCast(offset));
            const bucket = self.buckets[index(second)];
            if (bucket.second == second and bucket.count != 0) {
                value.* = bucket.sum / @as(f64, @floatFromInt(bucket.count));
            }
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
    stats.record(999, 10);
    stats.record(1000, null);
    stats.record(2500, 20);
    stats.record(2999, 40);

    const series = stats.series(59999);
    try std.testing.expectEqual(@as(?f64, 10), series[0]);
    try std.testing.expectEqual(@as(?f64, null), series[1]);
    try std.testing.expectEqual(@as(?f64, 30), series[2]);
    for (series[3..]) |value| try std.testing.expectEqual(@as(?f64, null), value);
    try std.testing.expectEqual(@as(?f64, 30), stats.mean(60000));
    try std.testing.expectEqual(@as(?f64, null), stats.series(60000)[0]);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(62000));
    try std.testing.expectEqual(@as([12]u64, @splat(0)), stats.histogram(62000));
    for (stats.series(62000)) |value| try std.testing.expectEqual(@as(?f64, null), value);
}

test "mean weights observations rather than seconds without sample truncation" {
    var stats: Stats = .{};
    for (0..10000) |_| stats.record(0, 2);
    stats.record(1000, 10002);
    try std.testing.expectEqual(@as(?f64, 30002.0 / 10001.0), stats.mean(1000));
    try std.testing.expectEqual(@as(?f64, 2), stats.series(1000)[58]);
    try std.testing.expectEqual(@as(?f64, 10002), stats.series(1000)[59]);
    try std.testing.expectEqual(@as(u64, 10000), stats.histogram(1000)[1]);
}

test "histogram inclusive boundaries and overflow" {
    var stats: Stats = .{};
    stats.record(0, 0);
    for (histogram_bounds_ms) |bound| {
        stats.record(0, bound);
        stats.record(0, bound + 0.5);
    }
    const expected: [12]u64 = .{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1 };
    try std.testing.expectEqual(expected, stats.histogram(0));
}

test "failures are excluded while lifetime counts survive expiry" {
    var stats: Stats = .{};
    stats.record(0, null);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(0));
    try std.testing.expectEqual(@as([12]u64, @splat(0)), stats.histogram(0));
    stats.record(0, 0);
    stats.record(0, 10);
    stats.record(0, null);
    try std.testing.expectEqual(@as(?f64, 5), stats.mean(0));
    try std.testing.expectEqual(@as(?f64, 5), stats.series(0)[59]);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(60000));
    try std.testing.expectEqual(@as(u64, 2), stats.successes);
    try std.testing.expectEqual(@as(u64, 2), stats.failures);
    stats.reset();
    try std.testing.expectEqual(@as(u64, 0), stats.successes);
    try std.testing.expectEqual(@as(u64, 0), stats.failures);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(0));
}

test "slot reuse preserves newer observations and handles negative timestamps" {
    var stats: Stats = .{};
    stats.record(-1, 2);
    try std.testing.expectEqual(@as(?f64, 2), stats.series(0)[58]);
    stats.record(59000, 4);
    stats.record(-1, 8);
    stats.record(60000, 6);
    try std.testing.expectEqual(@as(?f64, 5), stats.mean(60000));
    try std.testing.expectEqual(@as(?f64, 4), stats.series(60000)[58]);
    try std.testing.expectEqual(@as(?f64, 6), stats.series(60000)[59]);
    try std.testing.expectEqual(@as(?f64, null), stats.mean(0));
    try std.testing.expectEqual(@as(u64, 4), stats.successes);
}
