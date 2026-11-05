//! Harnais pour les ROMs de test de Blargg (cpu_instrs, instr_timing).
//!
//! Chaque ROM écrit son résultat en texte sur le port série. `runBlargg`
//! exécute la ROM jusqu'à lire `Passed` ou `Failed` dans ce texte, ou
//! jusqu'à `max_cycles`. En cas d'échec, le test affiche toute la sortie
//! série. Un bloc `test` par ROM : on voit tout de suite laquelle casse.
//!
//! Les ROMs vivent dans test-roms/gb-test-roms (ignoré par git, cloner
//! https://github.com/retrio/gb-test-roms). Si une ROM manque, son test
//! est sauté plutôt que de faire échouer `zig build test`.

const std = @import("std");
const gb = @import("gb");

const rom_dir = "test-roms/gb-test-roms/";

/// Délai maximal en M-cycles (~1,05 million par seconde émulée).
/// Les ROMs les plus longues de cpu_instrs finissent bien avant.
const max_cycles: u64 = 200_000_000;

const Outcome = enum { passed, failed, timeout, cpu_error };

fn runBlargg(path: []const u8) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const rom = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(rom);

    // Les ROMs individuelles de cpu_instrs se déclarent MBC1 mais font
    // 32 Kio : sans changement de banque, elles se lisent comme une ROM
    // ONLY. Le vrai MBC1 arrive en phase 6.
    _ = try gb.cartridge.Header.parse(rom);
    if (rom.len > 32 * 1024) return error.MbcNotSupported;

    const bus = try allocator.create(gb.Bus);
    defer allocator.destroy(bus);
    bus.* = gb.Bus.init(.{ .rom_only = .{ .rom = rom } });
    var cpu = gb.Cpu.init();

    var cycles: u64 = 0;
    // Longueur du tampon série au dernier examen : on ne cherche
    // Passed/Failed que lorsqu'un octet est arrivé.
    var seen_len: usize = 0;
    const outcome: Outcome = while (cycles < max_cycles) {
        const m = cpu.step(bus) catch |err| {
            std.debug.print("PC={X:0>4} : {s}\n", .{ cpu.pc, @errorName(err) });
            break .cpu_error;
        };
        // Le timer avance d'autant que l'instruction a duré.
        bus.tick(m);
        cycles += m;
        const len = bus.serial.len;
        if (len != seen_len) {
            seen_len = len;
            const out = bus.serial.slice();
            if (std.mem.indexOf(u8, out, "Passed") != null) break .passed;
            if (std.mem.indexOf(u8, out, "Failed") != null) break .failed;
        }
    } else .timeout;

    if (outcome == .passed) return;
    std.debug.print(
        "\n{s} : {s} après {d} M-cycles, sortie série :\n{s}\n",
        .{ path, @tagName(outcome), cycles, bus.serial.slice() },
    );
    return error.BlarggFailed;
}

test "cpu_instrs 01-special" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/01-special.gb");
}
test "cpu_instrs 02-interrupts" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/02-interrupts.gb");
}
test "cpu_instrs 03-op sp,hl" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/03-op sp,hl.gb");
}
test "cpu_instrs 04-op r,imm" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/04-op r,imm.gb");
}
test "cpu_instrs 05-op rp" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/05-op rp.gb");
}
test "cpu_instrs 06-ld r,r" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/06-ld r,r.gb");
}
test "cpu_instrs 07-jr,jp,call,ret,rst" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/07-jr,jp,call,ret,rst.gb");
}
test "cpu_instrs 08-misc instrs" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/08-misc instrs.gb");
}
test "cpu_instrs 09-op r,r" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/09-op r,r.gb");
}
test "cpu_instrs 10-bit ops" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/10-bit ops.gb");
}
test "cpu_instrs 11-op a,(hl)" {
    try runBlargg(rom_dir ++ "cpu_instrs/individual/11-op a,(hl).gb");
}
test "instr_timing" {
    try runBlargg(rom_dir ++ "instr_timing/instr_timing.gb");
}
