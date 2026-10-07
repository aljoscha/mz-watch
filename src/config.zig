const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Endpoint = struct {
    name: []const u8,
    conninfo: []const u8,
};

pub const Canary = struct {
    name: []const u8,
    sql: []const u8,
    interval_ms: u32 = 1000,
    timeout_ms: u32 = 5000,
    paused: bool = false,
};

pub const Config = struct {
    endpoints: []const Endpoint = &.{},
    canaries: []const Canary = &.{},
};

fn validateString(value: []const u8, name: bool) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0 or std.mem.indexOfScalar(u8, value, 0) != null)
        return error.InvalidConfig;
    const view = std.unicode.Utf8View.init(value) catch return error.InvalidConfig;
    if (name) {
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidConfig;
        }
    }
}

pub fn validate(config: Config) !void {
    for (config.endpoints) |endpoint| {
        try validateString(endpoint.name, true);
        try validateString(endpoint.conninfo, false);
    }
    for (config.canaries) |canary| {
        try validateString(canary.name, true);
        try validateString(canary.sql, false);
        if (canary.interval_ms == 0 or canary.timeout_ms == 0) return error.InvalidConfig;
    }
}

/// Results belong to arena and do not borrow source. Errors contain no source text.
pub fn parse(gpa: Allocator, arena: Allocator, source: [:0]const u8) !Config {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidConfig;
    // Diagnostics can contain connection credentials. Never expose or log them.
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const config = try std.zon.parse.fromSlice(Config, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = false,
    });
    try validate(config);
    return config;
}

/// A missing file is an empty configuration. All returned data belongs to arena.
pub fn load(gpa: Allocator, arena: Allocator, io: std.Io, path: []const u8) !Config {
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(source);
    return parse(gpa, arena, source);
}

/// Replaces the file atomically with private permissions, after syncing its contents.
/// Existing directories retain their permissions. This does not promise power-loss durability.
pub fn save(allocator: Allocator, io: std.Io, path: []const u8, config: Config) !void {
    try validate(config);
    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    try std.zon.stringify.serialize(config, .{}, &serialized.writer);

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        _ = try cwd.createDirPathStatus(io, parent, .fromMode(0o700));
    }
    var atomic = try cwd.createFileAtomic(io, path, .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, serialized.written());
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Caller owns the path. Relative or empty environment values are not usable.
pub fn defaultPath(allocator: Allocator, xdg: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg) |base| {
        if (base.len != 0 and std.fs.path.isAbsolute(base))
            return std.fs.path.join(allocator, &.{ base, "mz-watch", "config.zon" });
    }
    if (home) |base| {
        if (base.len != 0 and std.fs.path.isAbsolute(base))
            return std.fs.path.join(allocator, &.{ base, ".config", "mz-watch", "config.zon" });
    }
    return error.NoConfigDirectory;
}

test "native ZON roundtrip escaped UTF-8 strings, multiline SQL and paused state" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Exercise every non-NUL ASCII byte in a string, including ZON escapes.
    var bytes: [127]u8 = undefined;
    for (&bytes, 1..) |*byte, i| byte.* = @intCast(i);
    const original: Config = .{
        .endpoints = &.{.{ .name = "db \"東京\" \\", .conninfo = &bytes }},
        .canaries = &.{.{
            .name = "check café",
            .sql = "SELECT 'quote: \" and slash: \\'\n-- multiline SQL\nSELECT '東京';\t",
            .interval_ms = 17,
            .timeout_ms = 91,
            .paused = true,
        }},
    };
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.zon.stringify.serialize(original, .{}, &writer.writer);
    const source = try writer.toOwnedSliceSentinel(0);
    const parsed = try parse(gpa, arena.allocator(), source);
    gpa.free(source);
    try std.testing.expectEqualDeep(original, parsed);
}

test "defaults and invalid content" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualDeep(Config{}, try parse(gpa, arena.allocator(), ".{}"));
    const config = try parse(gpa, arena.allocator(),
        \\.{ .canaries = .{ .{ .name = "check", .sql = "SELECT 1" } } }
    );
    try std.testing.expectEqual(@as(u32, 1000), config.canaries[0].interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), config.canaries[0].timeout_ms);
    try std.testing.expect(!config.canaries[0].paused);

    const invalid = [_][:0]const u8{
        "not ZON",
        ".{ .version = 1 }",
        ".{ .endpoints = .{ .{ .name = \"db\", .conninfo = \"ok\", .id = 1 } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"ok\", .metrics = .{} } } }",
        ".{ .endpoints = .{ .{ .name = \"\", .conninfo = \"ok\" } } }",
        ".{ .endpoints = .{ .{ .name = \" \t\", .conninfo = \"ok\" } } }",
        ".{ .endpoints = .{ .{ .name = \"a\\n\", .conninfo = \"ok\" } } }",
        ".{ .endpoints = .{ .{ .name = \"\\x7f\", .conninfo = \"ok\" } } }",
        ".{ .endpoints = .{ .{ .name = \"\\u{85}\", .conninfo = \"ok\" } } }",
        ".{ .endpoints = .{ .{ .name = \"\\xff\", .conninfo = \"ok\" } } }",
        ".{ .endpoints = .{ .{ .name = \"db\", .conninfo = \"\" } } }",
        ".{ .endpoints = .{ .{ .name = \"db\", .conninfo = \"\\x00\" } } }",
        ".{ .endpoints = .{ .{ .name = \"db\", .conninfo = \"\\xff\" } } }",
        ".{ .canaries = .{ .{ .name = \"\", .sql = \"ok\" } } }",
        ".{ .canaries = .{ .{ .name = \"\\x00\", .sql = \"ok\" } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"\" } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"\\x00\" } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"\\xff\" } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"ok\", .interval_ms = 0 } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"ok\", .timeout_ms = 0 } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"ok\", .timeout_ms = -1 } } }",
        ".{ .canaries = .{ .{ .name = \"c\", .sql = \"ok\", .interval_ms = 4294967296 } } }",
        ".{}\x00ignored",
    };
    for (invalid) |source| {
        if (parse(gpa, arena.allocator(), source)) |_| {
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.InvalidConfig, error.ParseZon => {},
            else => return err,
        }
    }
}

test "missing load, private atomic replacement and failed save preservation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "nested", "private", "config.zon" });
    defer gpa.free(path);
    try std.testing.expectEqualDeep(Config{}, try load(gpa, arena.allocator(), io, path));
    const first: Config = .{ .endpoints = &.{.{ .name = "db", .conninfo = "password='private'" }} };
    try save(gpa, io, path, first);
    try std.testing.expectEqualDeep(first, try load(gpa, arena.allocator(), io, path));
    for ([_][]const u8{ "nested", "nested/private" }) |dir_path| {
        const stat = try tmp.dir.statFile(io, dir_path, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }
    // Replacement must not inherit a permissive mode from the old file.
    try tmp.dir.setFilePermissions(io, "nested/private/config.zon", .fromMode(0o644), .{});
    const second: Config = .{ .canaries = &.{.{ .name = "check", .sql = "SELECT 1\n", .paused = true }} };
    try save(gpa, io, path, second);
    try std.testing.expectEqualDeep(second, try load(gpa, arena.allocator(), io, path));
    const stat = try tmp.dir.statFile(io, "nested/private/config.zon", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    const before = try tmp.dir.readFileAlloc(io, "nested/private/config.zon", gpa, .unlimited);
    defer gpa.free(before);
    try std.testing.expectError(error.InvalidConfig, save(gpa, io, path, .{
        .endpoints = &.{.{ .name = "db", .conninfo = "bad\x00secret" }},
    }));
    const after = try tmp.dir.readFileAlloc(io, "nested/private/config.zon", gpa, .unlimited);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    // A directory destination forces failure after the temporary file is written.
    const blocked = try std.fs.path.join(gpa, &.{ root, "nested", "private" });
    defer gpa.free(blocked);
    if (save(gpa, io, blocked, first)) |_| return error.TestUnexpectedResult else |_| {}
    var parent = try tmp.dir.openDir(io, "nested", .{ .iterate = true });
    defer parent.close(io);
    var iter = parent.iterate();
    const entry = (try iter.next(io)).?;
    try std.testing.expectEqualStrings("private", entry.name);
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try iter.next(io));
    try std.testing.expectEqualDeep(second, try load(gpa, arena.allocator(), io, path));

    try tmp.dir.writeFile(io, .{ .sub_path = "nested/private/config.zon", .data = ".{ .unknown = 1 }" });
    try std.testing.expectError(error.ParseZon, load(gpa, arena.allocator(), io, path));
}

test "XDG path resolution" {
    const gpa = std.testing.allocator;
    const Case = struct { xdg: ?[]const u8, home: ?[]const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .xdg = "/xdg", .home = "/home/user", .expected = "/xdg/mz-watch/config.zon" },
        .{ .xdg = "/xdg/", .home = null, .expected = "/xdg/mz-watch/config.zon" },
        .{ .xdg = "relative", .home = "/home/user", .expected = "/home/user/.config/mz-watch/config.zon" },
        .{ .xdg = "", .home = "/home/user", .expected = "/home/user/.config/mz-watch/config.zon" },
        .{ .xdg = null, .home = "/", .expected = "/.config/mz-watch/config.zon" },
    };
    for (cases) |case| {
        const path = try defaultPath(gpa, case.xdg, case.home);
        defer gpa.free(path);
        try std.testing.expectEqualStrings(case.expected, path);
    }
    try std.testing.expectError(error.NoConfigDirectory, defaultPath(gpa, null, null));
    try std.testing.expectError(error.NoConfigDirectory, defaultPath(gpa, "relative", ""));
    try std.testing.expectError(error.NoConfigDirectory, defaultPath(gpa, "", "relative"));
}
