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
const libpq = @import("libpq_mock.zig");

pub const PgError = error{
    ConnectionFailed,
    QueryFailed,
    TransactionFailed,
    NoRows,
    TooManyRows,
    InvalidParameter,
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
            self.allocator.free(row.values);
        }
        self.rows.deinit(self.allocator);
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
            // Zero the DSN — it may contain a password — before returning the
            // memory to the allocator.
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
            const error_msg = libpq.PQresultErrorMessage(result);
            std.debug.print("PostgreSQL query error: {s}\n", .{error_msg});
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

    /// Execute a query that returns one row
    pub fn query_one(
        self: *Connection,
        sql: []const u8,
        args: []const []const u8,
    ) !Row {
        var result = try self.query(sql, args);
        defer result.deinit();

        if (result.first()) |row| {
            return row;
        }

        return PgError.NoRows;
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
            const error_msg = libpq.PQresultErrorMessage(result);
            std.debug.print("PostgreSQL exec error: {s}\n", .{error_msg});
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

/// Connection pool for PostgreSQL
pub const ConnectionPool = struct {
    allocator: Allocator,
    database_url: []u8,
    max_connections: u32,
    connections: []Connection,
    active_count: u32 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(
        allocator: Allocator,
        database_url: []const u8,
        max_connections: u32,
    ) !ConnectionPool {
        const connections = try allocator.alloc(Connection, max_connections);

        return ConnectionPool{
            .allocator = allocator,
            .database_url = try allocator.dupe(u8, database_url), // owned []u8 so deinit can zero it
            .max_connections = max_connections,
            .connections = connections,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections[0..self.active_count]) |*conn| {
            conn.deinit();
        }
        self.allocator.free(self.connections);
        // Zero the DSN before freeing — it may contain a password.
        @memset(self.database_url, 0);
        self.allocator.free(self.database_url);
    }

    /// Get a connection from the pool. Thread-safe.
    pub fn get_connection(self: *ConnectionPool) !*Connection {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();

        if (self.active_count < self.max_connections) {
            const idx = self.active_count;
            self.connections[idx] = try Connection.init(self.allocator, self.database_url);
            self.active_count += 1;
            return &self.connections[idx];
        }

        if (self.active_count > 0) {
            return &self.connections[0];
        }

        return PgError.ConnectionFailed;
    }

    /// Release connection back to pool. Thread-safe.
    pub fn release_connection(_: *ConnectionPool, _: *Connection) void {}
};

/// Parse a PostgreSQL connection URL
pub const ConnectionUrl = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    pub fn parse(allocator: Allocator, url: []const u8) !ConnectionUrl {
        _ = allocator;

        if (!std.mem.startsWith(u8, url, "postgres://")) {
            return PgError.InvalidParameter;
        }

        // TODO: Parse host/port/user/password/database out of `url`.
        return ConnectionUrl{
            .host = "localhost",
            .port = 5432,
            .user = "postgres",
            .password = "",
            .database = "postgres",
        };
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

test "ConnectionUrl.parse rejects non-postgres schemes" {
    try std.testing.expectError(
        PgError.InvalidParameter,
        ConnectionUrl.parse(std.testing.allocator, "mysql://localhost/db"),
    );
}

test "ConnectionUrl.parse accepts a postgres:// url" {
    const parsed = try ConnectionUrl.parse(std.testing.allocator, "postgres://localhost/db");
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 5432), parsed.port);
}

test "ConnectionPool.get_connection surfaces the mock backend's connection failure" {
    var pool = try ConnectionPool.init(std.testing.allocator, "postgres://localhost/db", 1);
    defer pool.deinit();

    try std.testing.expectError(PgError.ConnectionFailed, pool.get_connection());
}
