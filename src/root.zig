//! atomik-cqrs: a serverless, globally distributed, polyglot event sourcing runtime.

pub const cqrs = @import("cqrs.zig");
pub const event_store = @import("event_store.zig");
pub const postgres_pool = @import("postgres_pool.zig");
pub const repositories = @import("repositories.zig");
pub const router = @import("router.zig");
pub const http = @import("http.zig");
pub const json = @import("json.zig");

pub const adapters = struct {
    pub const postgres = @import("adapters/postgres.zig");
    pub const mysql_template = @import("adapters/mysql_template.zig");
    pub const sqlite_template = @import("adapters/sqlite_template.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
