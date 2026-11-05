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
//! L'exécution s'arrête peu après que le CPU boucle sur lui-même (Blargg
//! finit par `JR -2`), sur HALT (pas encore d'interruptions pour en
//! sortir), ou après `max_instructions`.

const std = @import("std");
const gb = @import("gb");

const max_instructions = 50_000_000;

/// Instructions exécutées après la détection de la boucle finale.
/// Certains journaux de référence (07) contiennent des centaines de
/// milliers de tours de cette boucle : s'arrêter dès le premier tour
/// ferait dire à Gameboy Doctor que notre journal est trop court.
const loop_padding = 1_000_000;

/// Le vrai bus, avec deux ajouts propres au traceur. Ils iront dans le
/// cœur plus tard : LY avec le PPU (phase 4), le port série en phase 3.
const DoctorBus = struct {
    inner: gb.Bus,
    /// SB (0xFF01) : octet à envoyer sur le port série.
    sb: u8 = 0,
    /// Texte écrit par la ROM sur le port série ("Passed", "Failed"...).
    serial: [4096]u8 = undefined,
    serial_len: usize = 0,

    pub fn read(self: *DoctorBus, addr: u16) u8 {
        return switch (addr) {
            // LY constant, comme dans les journaux de Gameboy Doctor :
            // sans PPU, c'est la seule façon que les boucles d'attente
            // de VBlank (LY == 0x90) se terminent comme chez lui.
            0xFF44 => 0x90,
            0xFF01 => self.sb,
            else => self.inner.read(addr),
        };
    }

    pub fn write(self: *DoctorBus, addr: u16, value: u8) void {
        switch (addr) {
            0xFF01 => self.sb = value,
            // SC = 0x81 : démarre un transfert avec l'horloge interne.
            // On le considère fini aussitôt et on garde l'octet.
            0xFF02 => if (value == 0x81 and self.serial_len < self.serial.len) {
                self.serial[self.serial_len] = self.sb;
                self.serial_len += 1;
            },
            else => self.inner.write(addr, value),
        }
    }
};

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

    const bus = try arena.create(DoctorBus);
    bus.* = .{ .inner = gb.Bus.init(.{ .rom_only = .{ .rom = rom } }) };
    var cpu = gb.Cpu.init();

    const log_file = try cwd.createFile(io, log_path, .{});
    defer log_file.close(io);
    var log_buf: [64 * 1024]u8 = undefined;
    var file_writer = log_file.writer(io, &log_buf);
    const log = &file_writer.interface;

    var count: u64 = 0;
    // Instructions restant à exécuter une fois la boucle finale atteinte.
    var after_loop: ?u32 = null;
    const reason: []const u8 = while (count < max_instructions) : (count += 1) {
        try logState(log, &cpu, bus);
        if (after_loop) |*n| {
            if (n.* == 0) break "boucle infinie";
            n.* -= 1;
        }
        const pc = cpu.pc;
        _ = cpu.step(bus) catch |err| {
            std.debug.print("PC={X:0>4} opcode {X:0>2} : {s}\n", .{ pc, bus.read(pc), @errorName(err) });
            break "erreur CPU";
        };
        if (cpu.halted) break "HALT";
        if (cpu.pc == pc and after_loop == null) after_loop = loop_padding;
    } else "limite d'instructions";
    try log.flush();

    std.debug.print("{d} instructions, arrêt : {s}\n", .{ count + 1, reason });
    std.debug.print("série : {s}\n", .{bus.serial[0..bus.serial_len]});
}

fn logState(w: *std.Io.Writer, cpu: *const gb.Cpu, bus: *DoctorBus) !void {
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
