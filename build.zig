const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Cœur de l'émulateur. Aucune dépendance (pas de lib graphique) :
    // ne jamais ajouter d'`imports` ici, le frontend importe `gb`, pas l'inverse.
    const gb = b.addModule("gb", .{
        .root_source_file = b.path("src/gb/gameboy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "Zigboy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gb", .module = gb },
            },
        }),
    });
    b.installArtifact(exe);

    // zig build run -- <rom>
    const run_step = b.step("run", "Lance l'émulateur");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // zig build test : tests du cœur et de l'exécutable.
    const test_step = b.step("test", "Lance les tests");
    const gb_tests = b.addTest(.{ .root_module = gb });
    test_step.dependOn(&b.addRunArtifact(gb_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
