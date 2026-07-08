const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // On macOS, libpq is keg-only (Homebrew does not symlink it into default
    // search paths). Pass the prefix here or let the Makefile detect it via
    // `brew --prefix libpq` and forward -Dlibpq-prefix automatically.
    const libpq_prefix_opt = b.option(
        []const u8,
        "libpq-prefix",
        "Override libpq installation prefix (e.g. /opt/homebrew/opt/libpq)",
    );

    // libpq backend modules: unit tests use the mock; integration tests use
    // the real C library. postgres_pool.zig selects via @import("libpq").
    const libpq_mock_mod = b.createModule(.{
        .root_source_file = b.path("src/libpq_mock.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libpq_real_mod owns the @cImport, so include/library paths live here.
    // Library linkage info propagates from the module to the final binary.
    const libpq_real_mod = b.createModule(.{
        .root_source_file = b.path("src/libpq.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (libpq_prefix_opt) |prefix| {
        libpq_real_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        libpq_real_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    }
    libpq_real_mod.linkSystemLibrary("pq", .{});

    // Public library module. Uses the mock by default so `zig build test`
    // is hermetic with no Postgres process required.
    const mod = b.addModule("atomik-cqrs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "libpq", .module = libpq_mock_mod },
        },
    });

    // Unit test step: `zig build test`
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run library unit tests (hermetic, no database required)");
    test_step.dependOn(&run_mod_tests.step);

    // Integration test step: `zig build test-integration`
    // Requires libpq installed and ATOMIK_DATABASE_URL set in the environment.
    // Driven by `make test-integration` (provisions Neon) or
    // `make test-integration-local` (reads .env.local).
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/postgres_integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "libpq", .module = libpq_real_mod },
        },
    });

    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run Postgres integration tests (requires ATOMIK_DATABASE_URL + libpq)");
    integration_step.dependOn(&run_integration.step);

    // Migration tool executable.
    const migrate_exe = b.addExecutable(.{
        .name = "atomik-migrate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/migrate.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "atomik-cqrs", .module = mod },
                // migrate.zig imports postgres_pool.zig directly, so libpq
                // must be available in the migrate module's own scope too.
                .{ .name = "libpq", .module = libpq_mock_mod },
            },
        }),
    });
    const migrate_install = b.addInstallArtifact(migrate_exe, .{});
    const migrate_step = b.step("migrate", "Build the migration runner");
    migrate_step.dependOn(&migrate_install.step);

    // WASM edge harness - proves the library builds/runs on Cloudflare Workers.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("edge/worker_main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "atomik-cqrs", .module = mod },
        },
    });

    const wasm_exe = b.addExecutable(.{
        .name = "atomik-cqrs-edge-harness",
        .root_module = wasm_module,
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    const wasm_step = b.step("wasm", "Build the WASM edge test harness");
    wasm_step.dependOn(&wasm_install.step);
}
