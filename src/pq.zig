//! The stable libpq C ABI used by the runner. Connection and result ownership
//! stay on the database thread. Only connection-string parsing belongs on the UI
//! thread. It performs no network I/O.
pub const Conn = opaque {};
pub const Result = opaque {};
pub const NoticeProcessor = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void;
pub const ConninfoOption = extern struct {
    keyword: ?[*:0]u8,
    envvar: ?[*:0]u8,
    compiled: ?[*:0]u8,
    val: ?[*:0]u8,
    label: ?[*:0]u8,
    dispchar: ?[*:0]u8,
    dispsize: c_int,
};
pub extern "pq" fn PQconninfoParse([*:0]const u8, *?[*:0]u8) ?[*]ConninfoOption;
pub extern "pq" fn PQconninfoFree([*]ConninfoOption) void;
pub extern "pq" fn PQfreemem(*anyopaque) void;

pub extern "pq" fn PQconnectStart(conninfo: [*:0]const u8) ?*Conn;
pub extern "pq" fn PQconnectPoll(conn: *Conn) c_int;
pub extern "pq" fn PQsetNoticeProcessor(conn: *Conn, proc: NoticeProcessor, arg: ?*anyopaque) ?NoticeProcessor;
pub extern "pq" fn PQstatus(conn: *const Conn) c_int;
pub extern "pq" fn PQsocket(conn: *const Conn) c_int;
pub extern "pq" fn PQsetnonblocking(conn: *Conn, arg: c_int) c_int;
pub extern "pq" fn PQfinish(conn: *Conn) void;
pub extern "pq" fn PQsendQueryParams(conn: *Conn, command: [*:0]const u8, n_params: c_int, types: ?[*]const c_uint, values: ?[*]const ?[*:0]const u8, lengths: ?[*]const c_int, formats: ?[*]const c_int, result_format: c_int) c_int;
pub extern "pq" fn PQsetSingleRowMode(conn: *Conn) c_int;
pub extern "pq" fn PQflush(conn: *Conn) c_int;
pub extern "pq" fn PQconsumeInput(conn: *Conn) c_int;
pub extern "pq" fn PQisBusy(conn: *Conn) c_int;
pub extern "pq" fn PQgetResult(conn: *Conn) ?*Result;
pub extern "pq" fn PQresultStatus(result: *const Result) c_int;
pub extern "pq" fn PQresultErrorField(result: *const Result, field: c_int) ?[*:0]const u8;
pub extern "pq" fn PQclear(result: *Result) void;

pub const connection_ok = 0;
pub const poll_failed = 0;
pub const poll_reading = 1;
pub const poll_writing = 2;
pub const poll_ok = 3;
pub const command_ok = 1;
pub const tuples_ok = 2;
pub const single_tuple = 9;

pub fn send(conn: *Conn, sql: [:0]const u8) bool {
    return PQsendQueryParams(conn, sql, 0, null, null, null, null, 0) == 1;
}

/// Server notices are not measurements and must never write into the TUI.
pub fn discardNotice(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
