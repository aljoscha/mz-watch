const std = @import("std");
const pq = @import("pq.zig");

/// Normalize explicit libpq options, hiding fields libpq marks as passwords.
/// Invalid input is never displayed because parsing errors can contain secrets.
pub fn format(allocator: std.mem.Allocator, conninfo: []const u8) ![]u8 {
    const source = try allocator.dupeSentinel(u8, conninfo, 0);
    defer allocator.free(source);
    var message: ?[*:0]u8 = null;
    const options = pq.PQconninfoParse(source, &message);
    defer if (message) |ptr| pq.PQfreemem(ptr);
    const values = options orelse return allocator.dupe(u8, "(invalid connection string)");
    defer pq.PQconninfoFree(values);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    // An allocating writer has no I/O failure. Its WriteFailed means allocation
    // failed, so preserve the allocator error contract for callers.
    writeOptions(&writer.writer, values) catch return error.OutOfMemory;
    return writer.toOwnedSlice();
}

fn writeOptions(writer: *std.Io.Writer, values: [*]pq.ConninfoOption) std.Io.Writer.Error!void {
    var i: usize = 0;
    var first = true;
    while (values[i].keyword) |keyword| : (i += 1) {
        const value = values[i].val orelse continue;
        if (!first) try writer.writeByte(' ');
        first = false;
        try writer.print("{s}='", .{std.mem.span(keyword)});
        const hidden = if (values[i].dispchar) |display| std.mem.indexOfScalar(u8, std.mem.span(display), '*') != null else false;
        for (if (hidden) "***" else std.mem.span(value)) |byte| {
            if (byte == '\'' or byte == '\\') try writer.writeByte('\\');
            try writer.writeByte(byte);
        }
        try writer.writeByte('\'');
    }
}

test "connection label preserves explicit options and redacts secrets in URI and conninfo" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "host=localhost port=6875 user=demo password='do not leak' sslpassword='another-secret'",
        "postgresql://demo:do%20not%20leak@localhost:6875/demo?sslpassword=another-secret",
    }) |source| {
        const label = try format(a, source);
        defer a.free(label);
        try std.testing.expect(std.mem.indexOf(u8, label, "host='localhost'") != null);
        try std.testing.expect(std.mem.indexOf(u8, label, "password='***'") != null);
        try std.testing.expect(std.mem.indexOf(u8, label, "sslpassword='***'") != null);
        try std.testing.expect(std.mem.indexOf(u8, label, "leak") == null);
        try std.testing.expect(std.mem.indexOf(u8, label, "another-secret") == null);
    }
    const service = try format(a, "service=demo application_name='a\\'b'");
    defer a.free(service);
    try std.testing.expect(std.mem.indexOf(u8, service, "service='demo'") != null);
    try std.testing.expect(std.mem.indexOf(u8, service, "application_name='a\\'b'") != null);
    const invalid = try format(a, "password=secret bad-option=secret");
    defer a.free(invalid);
    try std.testing.expectEqualStrings("(invalid connection string)", invalid);
}
