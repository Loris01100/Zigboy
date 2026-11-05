//! Harnais dmg-acid2 (https://github.com/mattcurrie/dmg-acid2).
//!
//! La ROM dessine un visage qui teste le fond, la fenêtre et les sprites,
//! puis exécute `LD B,B` (opcode 0x40), le « point d'arrêt » des
//! émulateurs de debug, pour signaler qu'elle a fini. On s'arrête là (ou
//! après `max_frames`) et on compare le framebuffer, pixel par pixel, à
//! l'image de référence. En cas d'échec, l'image obtenue est écrite dans
//! acid2-actual.ppm et le nombre de pixels différents est affiché.
//!
//! Fichiers attendus dans test-roms/dmg-acid2 (ignoré par git) :
//! - dmg-acid2.gb : la ROM, depuis les releases GitHub (le dépôt ne
//!   contient que le source assembleur) ;
//! - reference-dmg.gray : img/reference-dmg.png converti une fois pour
//!   toutes en 160 × 144 octets de gris bruts ($00, $55, $AA, $FF, les
//!   teintes indiquées par le README), ce qui évite un décodeur PNG :
//!     ffmpeg -i reference-dmg.png -f rawvideo -pix_fmt gray reference-dmg.gray
//!
//! Usage : zig build acid2

const std = @import("std");
const gb = @import("gb");

const rom_path = "test-roms/dmg-acid2/dmg-acid2.gb";
const reference_path = "test-roms/dmg-acid2/reference-dmg.gray";
const actual_path = "acid2-actual.ppm";

/// La ROM finit en quelques frames ; au-delà, elle est bloquée.
const max_frames = 60;
const m_cycles_per_frame = gb.ppu.dots_per_frame / 4;

const width = gb.ppu.screen_width;
const height = gb.ppu.screen_height;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    const rom = cwd.readFileAlloc(io, rom_path, arena, .limited(64 * 1024)) catch |err| {
        std.debug.print("impossible de lire {s} : {s}\n", .{ rom_path, @errorName(err) });
        std.process.exit(1);
    };
    const reference = cwd.readFileAlloc(io, reference_path, arena, .limited(64 * 1024)) catch |err| {
        std.debug.print("impossible de lire {s} : {s}\n", .{ reference_path, @errorName(err) });
        std.process.exit(1);
    };
    if (reference.len != width * height) {
        std.debug.print("{s} : {d} octets, {d} attendus\n", .{ reference_path, reference.len, width * height });
        std.process.exit(1);
    }

    _ = try gb.cartridge.Header.parse(rom);
    const gameboy = try arena.create(gb.GameBoy);
    gameboy.* = gb.GameBoy.init(.{ .rom_only = .{ .rom = rom } });
    const cpu = &gameboy.cpu;
    const bus = &gameboy.bus;

    var cycles: u64 = 0;
    const finished = while (cycles < max_frames * m_cycles_per_frame) {
        // Le prochain `step` exécutera-t-il l'opcode en PC ? Pas s'il est
        // en HALT ou s'il prend une interruption.
        const dispatch = cpu.ime and bus.ie & bus.if_ & 0x1F != 0;
        if (!cpu.halted and !dispatch and bus.read(cpu.pc) == 0x40) break true;
        cycles += gameboy.step() catch |err| {
            std.debug.print("PC={X:0>4} opcode {X:0>2} : {s}\n", .{ cpu.pc, bus.read(cpu.pc), @errorName(err) });
            std.process.exit(1);
        };
    } else false;

    const frames = cycles / m_cycles_per_frame;
    if (finished) {
        std.debug.print("LD B,B atteint après {d} frames\n", .{frames});
    } else {
        std.debug.print("LD B,B jamais atteint en {d} frames\n", .{max_frames});
    }

    const framebuffer = &bus.ppu.framebuffer;
    var diff: usize = 0;
    var first: ?[2]usize = null;
    for (framebuffer, 0..) |row, y| {
        for (row, 0..) |shade, x| {
            if (gb.ppm.gray_levels[shade] != reference[y * width + x]) {
                if (first == null) first = .{ x, y };
                diff += 1;
            }
        }
    }

    if (diff == 0 and finished) {
        std.debug.print("dmg-acid2 : image identique à la référence\n", .{});
        return;
    }

    const file = try cwd.createFile(io, actual_path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    try gb.writePpm(framebuffer, &file_writer.interface);
    try file_writer.interface.flush();

    std.debug.print("dmg-acid2 : {d} pixels sur {d} diffèrent", .{ diff, width * height });
    if (first) |p| std.debug.print(" (premier en x={d}, y={d})", .{ p[0], p[1] });
    std.debug.print(", image écrite dans {s}\n", .{actual_path});
    std.process.exit(1);
}
