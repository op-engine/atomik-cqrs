// Mock libpq for development when libpq-dev not installed
// IMPORTANT: Replace with real libpq.zig once libpq-dev is installed
// This is a temporary stub for Phase 2 development

pub const PGconn = opaque {};
pub const PGresult = opaque {};

pub const ConnStatusType = u32;
pub const ExecStatusType = u32;

pub const CONNECTION_OK = 0;
pub const CONNECTION_BAD = 1;

pub const PGRES_EMPTY_QUERY = 0;
pub const PGRES_COMMAND_OK = 1;
pub const PGRES_TUPLES_OK = 2;
pub const PGRES_COPY_OUT = 3;
pub const PGRES_COPY_IN = 4;
pub const PGRES_BAD_RESPONSE = 5;
pub const PGRES_NONFATAL_ERROR = 6;
pub const PGRES_FATAL_ERROR = 7;

// Stub functions - will be replaced with real libpq calls
pub fn PQconnectdb(_: [*:0]const u8) ?*PGconn {
    return null; // Mock: always fails
}

pub fn PQconnectdbParams(_: ?*const anyopaque, _: ?*const anyopaque, _: c_int) ?*PGconn {
    return null; // Mock: always fails
}

pub fn PQfinish(_: ?*PGconn) void {
    // Mock: no-op
}

pub fn PQstatus(_: ?*const PGconn) ConnStatusType {
    return CONNECTION_BAD; // Mock: always bad
}

pub fn PQerrorMessage(_: ?*const PGconn) [*:0]const u8 {
    return "libpq mock - not connected"; // Mock error
}

pub fn PQexecParams(
    _: ?*PGconn,
    _: [*:0]const u8,
    _: c_int,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    _: c_int,
) ?*PGresult {
    return null; // Mock: always fails
}

pub fn PQexec(_: ?*PGconn, _: [*:0]const u8) ?*PGresult {
    return null; // Mock: always fails
}

pub fn PQresultStatus(_: ?*const PGresult) ExecStatusType {
    return PGRES_FATAL_ERROR; // Mock: always error
}

pub fn PQresultErrorMessage(_: ?*const PGresult) [*:0]const u8 {
    return "libpq mock - query failed";
}

pub fn PQclear(_: ?*PGresult) void {
    // Mock: no-op
}

pub fn PQntuples(_: ?*const PGresult) c_int {
    return 0; // Mock: no rows
}

pub fn PQnfields(_: ?*const PGresult) c_int {
    return 0; // Mock: no fields
}

pub fn PQfname(_: ?*const PGresult, _: c_int) [*:0]const u8 {
    return "";
}

pub fn PQgetvalue(_: ?*const PGresult, _: c_int, _: c_int) [*:0]const u8 {
    return "";
}

pub fn PQgetisnull(_: ?*const PGresult, _: c_int, _: c_int) c_int {
    return 1; // Mock: all NULL
}

pub fn PQcmdTuples(_: ?*const PGresult) [*:0]const u8 {
    return "0";
}

pub fn PQescapeString(_: [*]u8, _: [*:0]const u8, _: usize) usize {
    return 0;
}

pub fn PQescapeBytea(_: [*:0]const u8, _: usize, _: [*]usize) ?[*:0]u8 {
    return null;
}

pub fn PQfreemem(_: ?*anyopaque) void {
    // Mock: no-op
}
