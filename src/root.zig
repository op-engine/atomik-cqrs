//! atomik-cqrs: a serverless, globally distributed, polyglot event sourcing runtime.

pub const cqrs = @import("cqrs.zig");
pub const event_store = @import("event_store.zig");
pub const projection = @import("projection.zig");
pub const postgres_pool = @import("postgres_pool.zig");
pub const repositories = @import("repositories.zig");
pub const router = @import("router.zig");
pub const http = @import("http.zig");
pub const json = @import("json.zig");

pub const adapters = struct {
    /// Production-ready PostgreSQL adapter and snapshot/checkpoint stores.
    pub const postgres = @import("adapters/postgres.zig");

    // Community adapter templates live in src/adapters/mysql_template.zig and
    // src/adapters/sqlite_template.zig. They implement the EventStoreAdapter
    // vtable shape with TODO stubs — copy and fill in the blanks for your
    // database. They are not exported here because they are not yet functional.
};

test {
    @import("std").testing.refAllDecls(@This());
}
