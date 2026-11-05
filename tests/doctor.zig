//! Traceur pour Gameboy Doctor (https://github.com/robert/gameboy-doctor).
//!
//! Exécute une ROM `cpu_instrs` de Blargg et écrit une ligne d'état
//! du CPU avant chaque instruction :
//!   A:01 F:B0 B:00 C:13 D:00 E:D8 H:01 L:4D SP:FFFE PC:0100 PCMEM:00,C3,13,02
//! Gameboy Doctor compare ce journal au sien et indique la première
//! ligne qui diffère.
//!
//! Usage : zig build doctor -- <rom.gb> <journal.log>
//! puis    python test-roms/gameboy-doctor/gameboy-doctor <journal.log> cpu_instrs <n>
//!
//! La machine tourne par `GameBoy.step()`, timer compris. Gameboy Doctor
//! n'attend une ligne que par opcode exécuté : rien pendant HALT, ni pour
//! la prise en charge d'une interruption (important pour 02-interrupts).
//!
//! L'exécution s'arrête peu après que le CPU boucle sur lui-même (Blargg
//! finit par `JR -2`), ou après `max_instructions`.

const std = @import("std");
const gb = @import("gb");

const max_instructions = 50_000_000;

/// Instructions exécutées après la détection de la boucle finale.
/// Certains journaux de référence (07) contiennent des centaines de
/// milliers de tours de cette boucle : s'arrêter dès le premier tour
/// ferait dire à Gameboy Doctor que notre journal est trop court.
const loop_padding = 1_000_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage : zig build doctor -- <rom.gb> <journal.log>\n", .{});
        std.process.exit(1);
    }
    const rom_path = args[1];
    const log_path = args[2];

    const cwd = std.Io.Dir.cwd();
    const rom = cwd.readFileAlloc(io, rom_path, arena, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("impossible de lire {s} : {s}\n", .{ rom_path, @errorName(err) });
        std.process.exit(1);
    };

    // Les ROMs individuelles de cpu_instrs se déclarent MBC1, mais font
    // 32 Kio : sans changement de banque, elles se lisent comme une ROM
    // ONLY. Le vrai MBC1 arrive en phase 6.
    const header = try gb.cartridge.Header.parse(rom);
    if (rom.len > 32 * 1024) {
        std.debug.print("{s} : ROM de plus de 32 Kio, MBC pas encore géré\n", .{rom_path});
        std.process.exit(1);
    }
    std.debug.print("{s} ({s})\n", .{ header.title, header.typeName() });

    const gameboy = try arena.create(gb.GameBoy);
    gameboy.* = gb.GameBoy.init(.{ .rom_only = .{ .rom = rom } });
    // LY constant à 0x90, comme dans les journaux de Gameboy Doctor : les
    // boucles d'attente de VBlank (LY == 0x90) se terminent comme chez
    // lui. Et IF lu sans ses bits inutilisés, sinon 02-interrupts diverge.
    gameboy.bus.doctor_mode = true;
    const cpu = &gameboy.cpu;

    const log_file = try cwd.createFile(io, log_path, .{});
    defer log_file.close(io);
    var log_buf: [64 * 1024]u8 = undefined;
    var file_writer = log_file.writer(io, &log_buf);
    const log = &file_writer.interface;

    var count: u64 = 0;
    // Instructions restant à exécuter une fois la boucle finale atteinte.
    var after_loop: ?u32 = null;
    // Faut-il écrire une ligne avant le prochain `step` ?
    var log_next = true;
    const reason: []const u8 = while (count < max_instructions) {
        if (log_next) {
            try logState(log, gameboy);
            count += 1;
            if (after_loop) |*n| {
                if (n.* == 0) break "boucle infinie";
                n.* -= 1;
            }
        }
        const pc = cpu.pc;
        const was_halted = cpu.halted;
        // Ce `step` prendra une interruption au lieu d'exécuter un opcode.
        const dispatch = cpu.ime and gameboy.bus.ie & gameboy.bus.if_ & 0x1F != 0;
        _ = gameboy.step() catch |err| {
            std.debug.print("PC={X:0>4} opcode {X:0>2} : {s}\n", .{ pc, gameboy.bus.read(pc), @errorName(err) });
            break "erreur CPU";
        };
        // Comme le journal de référence : pas de ligne au vecteur d'une
        // interruption (la prise en charge et la première instruction de
        // la routine tiennent en une ligne), et une seule ligne pour
        // toute la durée d'un HALT.
        log_next = !dispatch and !(was_halted and cpu.halted);
        if (log_next and cpu.pc == pc and after_loop == null) after_loop = loop_padding;
    } else "limite d'instructions";
    try log.flush();

    std.debug.print("{d} instructions, arrêt : {s}\n", .{ count, reason });
    std.debug.print("série : {s}\n", .{gameboy.bus.serial.slice()});
}

fn logState(w: *std.Io.Writer, gameboy: *gb.GameBoy) !void {
    const cpu = &gameboy.cpu;
    const bus = &gameboy.bus;
    try w.print(
        "A:{X:0>2} F:{X:0>2} B:{X:0>2} C:{X:0>2} D:{X:0>2} E:{X:0>2} H:{X:0>2} L:{X:0>2} SP:{X:0>4} PC:{X:0>4} PCMEM:{X:0>2},{X:0>2},{X:0>2},{X:0>2}\n",
        .{
            cpu.a,                 @as(u8, @bitCast(cpu.f)), cpu.b,            cpu.c,
            cpu.d,                 cpu.e,                    cpu.h,            cpu.l,
            cpu.sp,                cpu.pc,                   bus.read(cpu.pc), bus.read(cpu.pc +% 1),
            bus.read(cpu.pc +% 2), bus.read(cpu.pc +% 3),
        },
    );
}
