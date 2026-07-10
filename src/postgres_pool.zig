//! PostgreSQL connection pool. Talks to libpq via a swappable backend:
//! `libpq_mock.zig` for tests/CI where libpq-dev isn't installed, or
//! `libpq.zig` for a real linked build. Supports parameterized queries.
//!
//! To enable a real connection:
//!   1. Install libpq-dev (e.g. `apt-get install libpq-dev`)
//!   2. Change the import below to `@import("libpq.zig")`
//!   3. Link libpq in build.zig for the consuming executable

const std = @import("std");
const Allocator = std.mem.Allocator;
const libpq = @import("libpq");

const cqrs = @import("cqrs.zig");

/// Encode a UUID as a 32-character lowercase hex string for VARCHAR(32) columns.
/// Both the PostgresAdapter and EventRepository use this encoding; keeping it
/// here prevents the two copies from diverging.
pub fn uuid_to_hex(allocator: Allocator, uuid: cqrs.UUID) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, 32);
    for (uuid, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

/// Decode a 32-character lowercase hex string back into a UUID.
pub fn hex_to_uuid(hex: []const u8) !cqrs.UUID {
    if (hex.len != 32) return error.InvalidHex;
    var uuid: cqrs.UUID = undefined;
    for (0..16) |i| {
        const hi = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 1], 16);
        const lo = try std.fmt.parseInt(u8, hex[i * 2 + 1 .. i * 2 + 2], 16);
        uuid[i] = (hi << 4) | lo;
    }
    return uuid;
}

pub const PgError = error{
    ConnectionFailed,
    QueryFailed,
    UniqueViolation,
    TransactionFailed,
    NoRows,
    TooManyRows,
    InvalidParameter,
    NotImplemented,
    ServerError,
    OutOfMemory,
};

/// Simple row result
pub const Row = struct {
    columns: []const []const u8,
    values: []const ?[]const u8,
};

/// Query result set
pub const ResultSet = struct {
    allocator: Allocator,
    rows: std.ArrayList(Row),
    columns: []const []const u8,

    pub fn deinit(self: *ResultSet) void {
        for (self.rows.items) |row| {
            for (row.values) |maybe_val| {
                if (maybe_val) |val| self.allocator.free(val);
            }
            self.allocator.free(row.values);
        }
        self.rows.deinit(self.allocator);
        for (self.columns) |col| self.allocator.free(col);
        self.allocator.free(self.columns);
    }

    pub fn count(self: ResultSet) usize {
        return self.rows.items.len;
    }

    pub fn first(self: ResultSet) ?Row {
        if (self.rows.items.len > 0) {
            return self.rows.items[0];
        }
        return null;
    }

    pub fn iter(self: ResultSet) ResultSetIter {
        return ResultSetIter{
            .result = self,
            .index = 0,
        };
    }
};

pub const ResultSetIter = struct {
    result: ResultSet,
    index: usize,

    pub fn next(self: *ResultSetIter) ?Row {
        if (self.index < self.result.rows.items.len) {
            defer self.index += 1;
            return self.result.rows.items[self.index];
        }
        return null;
    }
};

/// PostgreSQL connection
pub const Connection = struct {
    allocator: Allocator,
    conn: ?*libpq.PGconn = null,

    pub fn init(allocator: Allocator, database_url: []const u8) !Connection {
        const conn_cstr = try allocator.dupeZ(u8, database_url);
        defer {
            // Zero the DSN before returning the memory to the allocator;
            // it may contain a password.
            @memset(conn_cstr, 0);
            allocator.free(conn_cstr);
        }

        const pg_conn = libpq.PQconnectdb(conn_cstr) orelse {
            return PgError.ConnectionFailed;
        };

        if (libpq.PQstatus(pg_conn) != libpq.CONNECTION_OK) {
            libpq.PQfinish(pg_conn);
            return PgError.ConnectionFailed;
        }

        return Connection{
            .allocator = allocator,
            .conn = pg_conn,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.conn) |conn| {
            libpq.PQfinish(conn);
        }
    }

    /// Execute a query (SELECT)
    pub fn query(
        self: *Connection,
        sql: []const u8,
        args: []const []const u8,
    ) !ResultSet {
        const conn = self.conn orelse return PgError.ConnectionFailed;
        const sql_cstr = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_cstr);

        // Convert args to C format
        const param_values = try self.allocator.alloc([*:0]const u8, args.len);
        defer self.allocator.free(param_values);

        var param_cstrs = try self.allocator.alloc([*:0]u8, args.len);
        defer {
            for (param_cstrs) |cstr| {
                self.allocator.free(std.mem.span(cstr));
            }
            self.allocator.free(param_cstrs);
        }

        for (args, 0..) |arg, i| {
            const arg_cstr = try self.allocator.dupeZ(u8, arg);
            param_cstrs[i] = arg_cstr;
            param_values[i] = arg_cstr;
        }

        const result = libpq.PQexecParams(
            conn,
            sql_cstr,
            @intCast(args.len),
            null,
            @ptrCast(@alignCast(param_values.ptr)),
            null,
            null,
            0,
        ) orelse return PgError.QueryFailed;

        defer libpq.PQclear(result);

        if (libpq.PQresultStatus(result) != libpq.PGRES_TUPLES_OK) {
            std.log.err("PostgreSQL query error: {s}", .{std.mem.span(libpq.PQresultErrorMessage(result))});
            return PgError.QueryFailed;
        }

        const n_rows = libpq.PQntuples(result);
        const n_cols = libpq.PQnfields(result);

        // Pre-allocate rows array
        const rows_array = try self.allocator.alloc(Row, @intCast(n_rows));
        errdefer self.allocator.free(rows_array);

        // Read column names
        const columns = try self.allocator.alloc([]const u8, @intCast(n_cols));
        errdefer self.allocator.free(columns);

        for (0..@intCast(n_cols)) |i| {
            const col_name = libpq.PQfname(result, @intCast(i));
            columns[i] = try self.allocator.dupe(u8, std.mem.span(col_name));
        }
        errdefer {
            for (columns) |col| {
                self.allocator.free(col);
            }
        }

        // Read rows
        for (0..@intCast(n_rows)) |row_idx| {
            const values = try self.allocator.alloc(?[]const u8, @intCast(n_cols));
            errdefer self.allocator.free(values);

            for (0..@intCast(n_cols)) |col_idx| {
                if (libpq.PQgetisnull(result, @intCast(row_idx), @intCast(col_idx)) != 0) {
                    values[col_idx] = null;
                } else {
                    const val = libpq.PQgetvalue(result, @intCast(row_idx), @intCast(col_idx));
                    values[col_idx] = try self.allocator.dupe(u8, std.mem.span(val));
                }
            }

            rows_array[row_idx] = .{
                .columns = columns,
                .values = values,
            };
        }

        return ResultSet{
            .allocator = self.allocator,
            .rows = std.ArrayList(Row){
                .items = rows_array,
                .capacity = rows_array.len,
            },
            .columns = columns,
        };
    }

    /// Execute a command (INSERT, UPDATE, DELETE)
    pub fn exec(
        self: *Connection,
        sql: []const u8,
        args: []const []const u8,
    ) !u64 {
        const conn = self.conn orelse return PgError.ConnectionFailed;
        const sql_cstr = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_cstr);

        // Convert args to C format
        const param_values = try self.allocator.alloc([*:0]const u8, args.len);
        defer self.allocator.free(param_values);

        var param_cstrs = try self.allocator.alloc([*:0]u8, args.len);
        defer {
            for (param_cstrs) |cstr| {
                self.allocator.free(std.mem.span(cstr));
            }
            self.allocator.free(param_cstrs);
        }

        for (args, 0..) |arg, i| {
            const arg_cstr = try self.allocator.dupeZ(u8, arg);
            param_cstrs[i] = arg_cstr;
            param_values[i] = arg_cstr;
        }

        const result = libpq.PQexecParams(
            conn,
            sql_cstr,
            @intCast(args.len),
            null,
            @ptrCast(@alignCast(param_values.ptr)),
            null,
            null,
            0,
        ) orelse return PgError.QueryFailed;

        defer libpq.PQclear(result);

        if (libpq.PQresultStatus(result) != libpq.PGRES_COMMAND_OK) {
            if (libpq.PQresultErrorField(result, libpq.PG_DIAG_SQLSTATE)) |ss| {
                if (std.mem.eql(u8, std.mem.span(ss), "23505")) return PgError.UniqueViolation;
            }
            std.log.err("PostgreSQL exec error: {s}", .{std.mem.span(libpq.PQresultErrorMessage(result))});
            return PgError.QueryFailed;
        }

        // Parse affected rows count
        const tuples_str = libpq.PQcmdTuples(result);
        const tuples_slice = std.mem.span(tuples_str);

        if (std.fmt.parseInt(u64, tuples_slice, 10)) |count| {
            return count;
        } else |_| {
            return 0;
        }
    }

    /// Begin transaction
    pub fn begin_transaction(self: *Connection) !void {
        _ = try self.exec("BEGIN", &[_][]const u8{});
    }

    /// Commit transaction
    pub fn commit(self: *Connection) !void {
        _ = try self.exec("COMMIT", &[_][]const u8{});
    }

    /// Rollback transaction
    pub fn rollback(self: *Connection) !void {
        _ = try self.exec("ROLLBACK", &[_][]const u8{});
    }
};

/// Connection pool for PostgreSQL.
///
/// Formerly a spinlock guarding only lazy-initialization, with every caller
/// beyond `max_connections` silently sharing `connections[0]` unsynchronized
/// (see ADR-06 in docs/adr/decisions.md) — safe only for a single caller at a
/// time. libpq forbids concurrent use of one `PGconn` from multiple threads;
/// two callers racing on the shared slot corrupts the wire protocol and can
/// hang indefinitely, which is exactly what surfaced once real concurrent
/// integration tests started exercising this path.
///
/// Now a real bounded pool: `get_connection` blocks (does not spin) until a
/// connection is genuinely idle, via a semaphore with one permit per slot;
/// `release_connection` marks the slot idle and signals the semaphore. No two
/// callers are ever handed the same live `Connection`.
pub const ConnectionPool = struct {
    allocator: Allocator,
    database_url: []u8,
    max_connections: u32,
    connections: []Connection,
    /// Parallel to `connections`; true for the first `initialized_count` slots
    /// currently checked out.
    in_use: []bool,
    /// How many of `connections` have been lazily created so far (0..max_connections).
    initialized_count: u32 = 0,
    /// Protects `connections`/`in_use`/`initialized_count`. Held only for the
    /// brief scan-and-checkout, never across an actual query.
    bookkeeping: std.Io.Mutex = .init,
    /// One permit per slot (idle-and-initialized or not-yet-initialized).
    /// get_connection blocks here instead of spinning when the pool is full.
    available: std.Io.Semaphore,
    /// Owned Io instance so the public API stays synchronous for callers
    /// (get_connection/release_connection take no Io parameter), matching
    /// migrate.zig's approach to the same std.Io threading requirement.
    io_threaded: std.Io.Threaded,

    pub fn init(
        allocator: Allocator,
        database_url: []const u8,
        max_connections: u32,
    ) !ConnectionPool {
        const connections = try allocator.alloc(Connection, max_connections);
        errdefer allocator.free(connections);

        const in_use = try allocator.alloc(bool, max_connections);
        errdefer allocator.free(in_use);
        @memset(in_use, false);

        return ConnectionPool{
            .allocator = allocator,
            .database_url = try allocator.dupe(u8, database_url), // owned []u8 so deinit can zero it
            .max_connections = max_connections,
            .connections = connections,
            .in_use = in_use,
            .available = .{ .permits = max_connections },
            .io_threaded = .init(allocator, .{}),
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections[0..self.initialized_count]) |*conn| {
            conn.deinit();
        }
        self.allocator.free(self.connections);
        self.allocator.free(self.in_use);
        // Zero the DSN before freeing; it may contain a password.
        @memset(self.database_url, 0);
        self.allocator.free(self.database_url);
        self.io_threaded.deinit();
    }

    /// Get a connection from the pool, blocking until one is genuinely idle.
    /// Thread-safe: no two callers are ever handed the same live Connection.
    pub fn get_connection(self: *ConnectionPool) !*Connection {
        const io = self.io_threaded.io();

        try self.available.wait(io);
        errdefer self.available.post(io); // give the permit back if checkout fails below

        self.bookkeeping.lockUncancelable(io);
        defer self.bookkeeping.unlock(io);

        for (0..self.initialized_count) |i| {
            if (!self.in_use[i]) {
                self.in_use[i] = true;
                return &self.connections[i];
            }
        }

        const idx = self.initialized_count;
        self.connections[idx] = try Connection.init(self.allocator, self.database_url);
        self.in_use[idx] = true;
        self.initialized_count += 1;
        return &self.connections[idx];
    }

    /// Release connection back to pool. Thread-safe.
    pub fn release_connection(self: *ConnectionPool, conn: *Connection) void {
        const io = self.io_threaded.io();
        const idx = (@intFromPtr(conn) - @intFromPtr(self.connections.ptr)) / @sizeOf(Connection);

        self.bookkeeping.lockUncancelable(io);
        self.in_use[idx] = false;
        self.bookkeeping.unlock(io);

        self.available.post(io);
    }
};

/// Parse a PostgreSQL connection URL
pub const ConnectionUrl = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    /// NOT IMPLEMENTED. Returns error.NotImplemented on every call.
    ///
    /// ConnectionPool.init takes the raw DSN string and passes it directly
    /// to PQconnectdb; no parsing is required for the connection flow.
    /// This function exists as a placeholder for callers that need the
    /// individual fields (host, port, etc.) extracted. Implement it or
    /// remove it before exposing it to consumers; calling it currently
    /// returns an error rather than silently connecting to the wrong database.
    pub fn parse(allocator: Allocator, url: []const u8) !ConnectionUrl {
        _ = allocator;
        _ = url;
        return PgError.NotImplemented;
    }
};

/// Transaction helper
pub const Transaction = struct {
    conn: *Connection,
    committed: bool = false,

    pub fn init(conn: *Connection) !Transaction {
        try conn.begin_transaction();
        return Transaction{
            .conn = conn,
        };
    }

    pub fn commit(self: *Transaction) !void {
        try self.conn.commit();
        self.committed = true;
    }

    pub fn rollback(self: *Transaction) !void {
        try self.conn.rollback();
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.committed) {
            self.rollback() catch {};
        }
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "ConnectionUrl.parse returns NotImplemented (stub, not yet wired)" {
    try std.testing.expectError(
        PgError.NotImplemented,
        ConnectionUrl.parse(std.testing.allocator, "postgres://localhost/db"),
    );
    try std.testing.expectError(
        PgError.NotImplemented,
        ConnectionUrl.parse(std.testing.allocator, "mysql://localhost/db"),
    );
}

test "ConnectionPool.get_connection surfaces the mock backend's connection failure" {
    var pool = try ConnectionPool.init(std.testing.allocator, "postgres://localhost/db", 1);
    defer pool.deinit();

    try std.testing.expectError(PgError.ConnectionFailed, pool.get_connection());
}
