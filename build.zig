const std = @import("std");

pub fn build(b: *std.Build) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const exe = b.addExecutable(.{ .name = "lapentor360", .root_module = root_module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Scrape a tour").dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = root_module }));
    b.step("test", "Run unit tests").dependOn(&tests.step);
}
