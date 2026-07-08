const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module - the surface consumers import as "atomik-cqrs".
    const mod = b.addModule("atomik-cqrs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test step: `zig build test` collects `test` blocks from every file
    // reachable via @import from src/root.zig.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);

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
            },
        }),
    });
    const migrate_install = b.addInstallArtifact(migrate_exe, .{});
    const migrate_step = b.step("migrate", "Build the migration runner");
    migrate_step.dependOn(&migrate_install.step);

    // WASM edge harness - proves the library builds/runs on Cloudflare
    // Workers. Not part of the published library surface.
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
