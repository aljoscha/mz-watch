const std = @import("std");
const pq = @import("pq.zig");

/// Return allocator-owned conninfo with the advertised host and port replacing
/// base's host, hostaddr and port. Accepts hostname:port or [IPv6]:port.
/// Other explicit options are retained, without resolving services or DNS.
/// The result can contain credentials and must not be logged.
pub fn destination(allocator: std.mem.Allocator, base: []const u8, address: []const u8) ![]const u8 {
    const endpoint = try Endpoint.parse(address);
    return normalize(allocator, base, endpoint);
}

/// Return allocator-owned explicit options in libpq order, with canonical
/// keyword quoting. URI and keyword inputs share the same representation.
/// Values remain literal, without defaults, service expansion or DNS lookup.
/// The result can contain credentials and must not be logged.
pub fn canonical(allocator: std.mem.Allocator, conninfo: []const u8) ![]const u8 {
    return normalize(allocator, conninfo, null);
}

const Endpoint = struct {
    host: []const u8,
    port: []const u8,

    fn parse(address: []const u8) !Endpoint {
        for (address) |byte| {
            if (byte <= 0x20 or byte == 0x7f) return error.InvalidAddress;
        }
        if (address.len == 0) return error.InvalidAddress;
        var host: []const u8 = undefined;
        var port: []const u8 = undefined;
        if (address[0] == '[') {
            const close = std.mem.indexOfScalar(u8, address, ']') orelse return error.InvalidAddress;
            if (close + 1 >= address.len or address[close + 1] != ':') return error.InvalidAddress;
            host = address[1..close];
            // Validate syntax without resolving the interface scope.
            switch (std.Io.net.Ip6Address.Unresolved.parse(host)) {
                .success => {},
                else => return error.InvalidAddress,
            }
            port = address[close + 2 ..];
        } else {
            const colon = std.mem.indexOfScalar(u8, address, ':') orelse return error.InvalidAddress;
            host = address[0..colon];
            port = address[colon + 1 ..];
            if (host.len == 0) return error.InvalidAddress;
            // A single advertised endpoint is neither a libpq host list nor a
            // Unix socket directory. IPv6 requires brackets to avoid ambiguity.
            for (host) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return error.InvalidAddress;
            }
        }
        if (port.len == 0) return error.InvalidAddress;
        for (port) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidAddress;
        }
        const number = std.fmt.parseInt(u16, port, 10) catch return error.InvalidAddress;
        if (number == 0) return error.InvalidAddress;
        return .{ .host = host, .port = port };
    }
};

fn normalize(allocator: std.mem.Allocator, source: []const u8, endpoint: ?Endpoint) ![]const u8 {
    // libpq takes a C string. Never let an embedded NUL hide trailing options.
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidConninfo;
    const terminated = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(terminated);
    var message: ?[*:0]u8 = null;
    const parsed = pq.PQconninfoParse(terminated, &message);
    // Parser diagnostics may contain credentials. Return only a fixed error.
    defer if (message) |ptr| pq.PQfreemem(ptr);
    const options = parsed orelse return error.InvalidConninfo;
    defer pq.PQconninfoFree(options);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    writeOptions(&writer.writer, options, endpoint) catch return error.OutOfMemory;
    return writer.toOwnedSlice();
}

fn writeOptions(writer: *std.Io.Writer, options: [*]pq.ConninfoOption, endpoint: ?Endpoint) std.Io.Writer.Error!void {
    var index: usize = 0;
    var first = true;
    while (options[index].keyword) |keyword| : (index += 1) {
        const key = std.mem.span(keyword);
        var value: ?[]const u8 = if (options[index].val) |v| std.mem.span(v) else null;
        if (endpoint) |ep| {
            if (std.mem.eql(u8, key, "hostaddr")) continue;
            if (std.mem.eql(u8, key, "host")) value = ep.host;
            if (std.mem.eql(u8, key, "port")) value = ep.port;
        }
        var explicit = value orelse continue;
        // Normalize numeric spelling without DNS or service-file expansion.
        var host_buffer: [256]u8 = undefined;
        var port_buffer: [5]u8 = undefined;
        if (std.mem.eql(u8, key, "host") or std.mem.eql(u8, key, "hostaddr")) {
            switch (std.Io.net.Ip6Address.Unresolved.parse(explicit)) {
                .success => |host| explicit = std.fmt.bufPrint(&host_buffer, "{f}", .{host}) catch return error.WriteFailed,
                else => {},
            }
        }
        if (std.mem.eql(u8, key, "port")) {
            if (std.fmt.parseInt(u16, explicit, 10)) |port| {
                explicit = std.fmt.bufPrint(&port_buffer, "{d}", .{port}) catch return error.WriteFailed;
            } else |_| {}
        }
        if (!first) try writer.writeByte(' ');
        first = false;
        try writer.print("{s}='", .{key});
        for (explicit) |byte| {
            if (byte == '\'' or byte == '\\') try writer.writeByte('\\');
            try writer.writeByte(byte);
        }
        try writer.writeByte('\'');
    }
}

test "destination retains and escapes explicit options while overriding all routing fields" {
    const a = std.testing.allocator;
    const actual = try destination(a, "host=old,other hostaddr=192.0.2.1,192.0.2.2 port=1,2 user=first user=demo dbname='a b' password='a\\'b\\\\c' service=not-resolved sslmode=verify-full application_name=''", "replica.example:6875");
    defer a.free(actual);
    const expected = try canonical(a, "host=replica.example port=6875 user=demo dbname='a b' password='a\\'b\\\\c' service=not-resolved sslmode=verify-full application_name=''");
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "password='a\\'b\\\\c'") != null);
    const again = try canonical(a, actual);
    defer a.free(again);
    try std.testing.expectEqualStrings(actual, again);
}

test "URI and keyword inputs canonicalize identically for manual and discovered destinations" {
    const a = std.testing.allocator;
    const uri = try canonical(a, "postgresql://demo:p%27%5C@replica.example:6875/a%20b?sslmode=require");
    defer a.free(uri);
    const keyword = try canonical(a, "sslmode=require dbname='a b' port=6875 password='p\\'\\\\' host=replica.example user=demo");
    defer a.free(keyword);
    try std.testing.expectEqualStrings(uri, keyword);
    for ([_][]const u8{
        "postgresql://demo:p%27%5C@old:1/a%20b?sslmode=require&hostaddr=192.0.2.1",
        "password='p\\'\\\\' user=demo port=9 host=other dbname='a b' sslmode=require",
    }) |base| {
        const discovered = try destination(a, base, "replica.example:6875");
        defer a.free(discovered);
        try std.testing.expectEqualStrings(uri, discovered);
    }
}

test "bracketed IPv6 becomes a literal libpq host" {
    const a = std.testing.allocator;
    const actual = try destination(a, "user=demo", "[::1]:6875");
    defer a.free(actual);
    const expected = try canonical(a, "postgresql://demo@[::1]:6875");
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}

test "reject malformed advertised addresses and unsafe C strings" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "",              "host",       ":6875",    "host:",     "host:0",      "host:65536",  "host:-1", "host:+1",     "host:abc",
        "::1:6875",      "host:1:2",   "[::1]",    "[::1:6875", "[::1]x:6875", "[nope]:6875", "[]:6875", "host:6875\n", "ho\x00st:6875",
        "host\x7f:6875", "host: 6875", "a,b:6875", "/tmp:6875",
    }) |address| {
        try std.testing.expectError(error.InvalidAddress, destination(a, "", address));
    }
    for ([_][]const u8{ "host=ok\x00 password=hidden", "password='unterminated", "unknown=secret", "postgresql://host/db?unknown=secret" }) |source| {
        try std.testing.expectError(error.InvalidConninfo, canonical(a, source));
        try std.testing.expectError(error.InvalidConninfo, destination(a, source, "host:6875"));
    }
}

fn allocationBoundary(allocator: std.mem.Allocator) !void {
    // A long value exercises writer growth as well as input duplication.
    const base = "user=demo password='" ++ @as([2000]u8, @splat('s')) ++ "' sslmode=require";
    const discovered = try destination(allocator, base, "[::1]:6875");
    defer allocator.free(discovered);
    const manual = try canonical(allocator, discovered);
    defer allocator.free(manual);
    try std.testing.expectEqualStrings(discovered, manual);
}

test "allocation failures at public API boundaries do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationBoundary, .{});
}

test "numeric destination spelling does not duplicate IPv6 targets" {
    const a = std.testing.allocator;
    const compact = try destination(a, "user=demo", "[::1]:6875");
    defer a.free(compact);
    const expanded = try destination(a, "user=demo", "[0:0:0:0:0:0:0:1]:06875");
    defer a.free(expanded);
    try std.testing.expectEqualStrings(compact, expanded);
    const manual = try canonical(a, "user=demo host=0:0:0:0:0:0:0:1 port=06875");
    defer a.free(manual);
    try std.testing.expectEqualStrings(compact, manual);
}
